import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 发送请求的最长等待（用户 App → FastAPI 这一段，统一 30 秒）。
/// 服务器现在首段也会立刻返回 SSE 响应头（案件核心在流内生成并配心跳），
/// 因此 30 秒足够覆盖建立连接 + 拿到响应头。
const Duration kStorySendTimeout = Duration(seconds: 30);

/// 流式"卡死"判定（两次数据到达之间的最长静默，统一 30 秒）。
/// 四段传输（App→FastAPI、FastAPI→Dify、Dify→FastAPI、FastAPI→App）一律 30 秒
/// 空闲超时，且收到任何数据或心跳即重置。服务器在阻塞式 Dify 调用（案件核心 /
/// 内容审核）期间每 15s 推心跳，因此正常慢 Dify 不会误判；只有真正超过 30 秒
/// 无任何数据/心跳才判定超时，触发"网络疑似超时，请重启重试"提示。
const Duration kStoryIdleTimeout = Duration(seconds: 30);

/// 小说生成服务（流式）：把用户设定发送到 FastAPI 网关，网关每满 400 字增量审核
/// （窗口 [0,400)、[350,800)、[750,1200)... 重叠防漏网）、通过后以 SSE 流式返回
/// 正文（chunk → reveal），用于打字机效果显示（打字机速度由客户端控制，维持原设定）。
class StoryService {
  StoryService._();

  /// 小说生成接口地址（来自 .env 的 STORY_API_URL；
  /// 未配置时由 AUDIT_API_URL 推导，保证服务器地址一致）。
  static String get _storyApiUrl {
    final direct = dotenv.env['STORY_API_URL'] ?? '';
    if (direct.isNotEmpty) return direct;
    final audit = dotenv.env['AUDIT_API_URL'] ?? '';
    if (audit.contains('/api/audit-and-chat')) {
      return audit.replaceFirst('/api/audit-and-chat', '/api/generate-story');
    }
    return '';
  }

  /// 流式生成小说正文。
  ///
  /// [onChunk]：审核通过的首段正文（打字机开始打）
  /// [onReveal]：后续各段审核通过的正文 + 结束节点 outputs（逐段追加显示）
  /// [onTruncate]：服务器修正违规内容后，让当前段回滚到指定字符数（keep）再续打
  /// [onAbort]：内容违规被中止
  /// [onError]：出错
  /// [onDone]：流程结束（可在此保存/收尾）
  static Future<void> generateStoryStream({
    String userInput = '',
    String choice1 = '',
    String choice2 = '',
    String choice3 = '',
    // 时间树"从这里重写"：>=0 时服务器从该 seq 截断后续段，并作为新段续写
    int? rewriteFrom,
    // 用户设定（第一轮生成时随请求上传，服务器与小说正文一起落库）
    String location = '',
    String era = '',
    String playerName = '',
    String playerTraits = '',
    String language = '',
    required void Function(String text) onChunk,
    required void Function(String text, Map<String, dynamic> outputs) onReveal,
    void Function(int keep)? onTruncate,
    required void Function(String reason, String snippet) onAbort,
    required void Function(String message, {String? code}) onError,
    void Function()? onDeviceConflict,
    void Function()? onConflict,
    void Function()? onStalled,
    // 【调试】生成前确认：服务器在调 Dify 前把 payload 发回 App（SSE 事件 debug_payload）。
    // 回调负责弹窗展示 payload；用户点击"确认发送"后由回调调用 [confirmPayload] 通知服务器。
    void Function(Map<String, dynamic> payload, String requestId)? onDebugPayload,
    // 违规修正前确认：服务器在修正前把待修正文本 + 违规判定 JSON 发回 App（SSE 事件 revise_confirm）。
    // 回调负责弹窗展示；用户点击"送 Dify 修正"后由回调调用 [confirmRevise] 通知服务器继续。
    void Function(String text, Map<String, dynamic> verdict, String requestId)?
        onReviseConfirm,
    // 大纲合规未通过（SSE 事件 outline_rejected）：服务器已删除该版大纲/正文，
    // 上层弹多语言提示（统一话术"大纲尺度过大审核不过"）并提供"重新开始故事"。
    void Function()? onOutlineRejected,
    // 同一请求内开启新的一段（SSE 事件 segment_begin，如老小说末章自动续 →
    // 新小说第一章）：上层应让接下来的正文另起一个新的文本框显示。
    void Function()? onSegmentBegin,
    required void Function(Map<String, dynamic> outputs) onDone,
  }) async {
    final url = _storyApiUrl;
    if (url.isEmpty) {
      onError(StorageService.localizedText(
        zhCN: '小说生成地址未配置：请检查 .env 中的 STORY_API_URL 或 AUDIT_API_URL',
        zhTW: '小說生成位址未配置：請檢查 .env 中的 STORY_API_URL 或 AUDIT_API_URL',
        en: 'Story generation URL is not configured. Please check STORY_API_URL or AUDIT_API_URL in your .env file.',
        yue: '小說生成位址未配置：請檢查 .env 入面嘅 STORY_API_URL 或 AUDIT_API_URL',
        es: 'La URL de generación de historias no está configurada. Compruebe STORY_API_URL o AUDIT_API_URL en su archivo .env.',
        fr: "L'URL de génération d'histoire n'est pas configurée. Vérifiez STORY_API_URL ou AUDIT_API_URL dans votre fichier .env.",
        de: 'Die URL zur Story-Generierung ist nicht konfiguriert. Bitte prüfen Sie STORY_API_URL oder AUDIT_API_URL in Ihrer .env-Datei.',
        pt: 'A URL de geração de histórias não está configurada. Verifique STORY_API_URL ou AUDIT_API_URL no seu arquivo .env.',
        ja: 'ストーリー生成URLが設定されていません。.envファイルのSTORY_API_URLまたはAUDIT_API_URLを確認してください。',
        ko: '스토리 생성 URL이 구성되지 않았습니다. .env 파일에서 STORY_API_URL 또는 AUDIT_API_URL을 확인하세요.',
      ));
      return;
    }
    final token = await AuthService.ensureToken();

    final client = http.Client();
    // 流式"卡死"标记：kStoryIdleTimeout 内没有任何数据到达（且未收到 done）时置 true，
    // 由 onStalled 处理。取值见 kStoryIdleTimeout 注释（须大于服务器阻塞式 Dify 调用窗口）。
    var stalled = false;
    try {
      final request = http.Request('POST', Uri.parse(url));
      request.headers.addAll({
        'accept': 'text/event-stream',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      });
      request.body = jsonEncode({
        'user_input': userInput,
        // 用户本轮"实际选择"文本：与所点/所确认输入框的内容一致，显式以
        // user_choice 字段上传（服务器据此写入 user_choice 并作为 Dify 变量）
        'user_choice': userInput,
        'choice_1': choice1,
        'choice_2': choice2,
        'choice_3': choice3,
        'location': location,
        'era': era,
        'player_name': playerName,
        'player_traits': playerTraits,
        'language': language,
        if (rewriteFrom != null) 'rewrite_from': rewriteFrom,
      });

      final response = await client
          .send(request)
          .timeout(kStorySendTimeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        String detail = 'HTTP ${response.statusCode}';
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['detail'] != null) {
            detail = decoded['detail'].toString();
          }
        } catch (_) {
          // 忽略解析失败
        }
        if (detail == 'device_conflict') {
          // 多设备同时登入：由上层弹出警告并重启本 App
          onDeviceConflict?.call();
          return;
        }
        if (detail == 'multi_client') {
          // 本设备已不是最新登入（被其它设备顶掉）：写请求被拒。
          // 由上层弹统一"多客户端"仅退出对话框。
          onConflict?.call();
          return;
        }
        onError(detail);
        return;
      }

      var doneCalled = false;
      var terminatedByEvent = false; // 已通过 error/abort 事件终止（避免重复弹窗）
      // 打字机流超时规则（2026-09）：只有收到【实质内容】才把 30s 等待重置为
      // kStoryIdleTimeout；服务器只在对应用户弹窗（审核确认/payload 确认）等待期间
      // 发 heartbeat 维持，其余无实质内容的事件不重置（避免在无内容时错误地无限等待）。
      // 一旦超过 30s 没有任何实质内容到达即判定卡死（调用 onStalled 提示重启）。
      Timer? idleTimer;
      void armIdleTimer() {
        idleTimer?.cancel();
        idleTimer = Timer(kStoryIdleTimeout, () {
          if (!stalled) {
            stalled = true;
            onStalled?.call();
          }
        });
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      armIdleTimer(); // 请求发出后等待首段实质内容
      await for (final line in lines) {
        if (stalled) break; // 已判定超时：停止读取后续数据
        final s = line.trim();
        if (!s.startsWith('data:')) continue;
        final raw = s.substring(5).trim();
        if (raw.isEmpty) continue;
        Map<String, dynamic> evt;
        try {
          evt = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final event = evt['event'] as String?;
        switch (event) {
          case 'debug_payload':
            // 【调试】生成前确认：服务器调 Dify 前把 payload 发回 App。
            // 实质活动 → 重置 30s（弹窗等待用户确认期间不误判卡死）。
            debugPrint('[story] RECV debug_payload id=${evt['request_id']}');
            armIdleTimer();
            onDebugPayload?.call(
              (evt['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
              evt['request_id'] as String? ?? '',
            );
            break;
          case 'outline_debug_payload':
            // 【调试】申请小说大纲前：把将要发给大纲工作流的全部变量（含 used_name）
            // 发回 App 弹窗确认；等待期间服务器会发 heartbeat 续命（不依赖本事件重置）。
            debugPrint('[story] RECV outline_debug_payload id=${evt['request_id']}');
            onDebugPayload?.call(
              (evt['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
              evt['request_id'] as String? ?? '',
            );
            break;
          case 'revise_confirm':
            // 违规修正前确认：实质活动 → 重置 30s（等待用户确认修正期间不误判卡死）。
            armIdleTimer();
            onReviseConfirm?.call(
              evt['text'] as String? ?? '',
              (evt['verdict'] as Map?)?.cast<String, dynamic>() ?? const {},
              evt['request_id'] as String? ?? '',
            );
            break;
          case 'outline_rejected':
            // 大纲合规未通过：终止本次生成（不做网络超时兜底弹窗），交上层弹窗。
            terminatedByEvent = true;
            idleTimer?.cancel(); // 已正常终止：停止 30s 等待计时
            onOutlineRejected?.call();
            break;
          case 'conflict':
            // 多客户端冲突：本设备已被更新的设备顶掉（落库被拒）。终止本次生成，
            // 交上层弹统一"多客户端"仅退出对话框。
            terminatedByEvent = true;
            idleTimer?.cancel();
            onConflict?.call();
            break;
          case 'segment_begin':
            // 同一请求内开启新的一段（跨小说自动续等）：非实质内容，不重置 30s；
            // 交上层让接下来的 chunk/reveal 另起一个新的文本框。
            onSegmentBegin?.call();
            break;
          case 'heartbeat':
            // "大纲活动心跳"：服务器仅在收到 Dify 大纲实质内容时才发（节流），
            // 证明"还在等完整大纲、没有实质内容给你"→ 收到即重置 30s 防误断；
            // 服务器在 Dify 真卡住时会停止发心跳，App 到 30s 自会断（不会无限等）。
            armIdleTimer();
            break;
          case 'chunk':
            armIdleTimer(); // 正文实质内容 → 重置 30s
            onChunk(evt['text'] as String? ?? '');
            break;
          case 'reveal':
            armIdleTimer(); // 正文实质内容 → 重置 30s
            onReveal(
              evt['text'] as String? ?? '',
              (evt['outputs'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            break;
          case 'truncate':
            armIdleTimer(); // 服务器实质改动（回滚点） → 重置 30s
            // 服务器修正违规内容后：把当前段回滚到 keep 字符，随后续 reveal 继续打字
            onTruncate?.call(evt['keep'] as int? ?? 0);
            break;
          case 'abort':
            terminatedByEvent = true;
            idleTimer?.cancel(); // 已正常终止：停止 30s 等待计时，避免误弹超时
            onAbort(evt['reason'] as String? ??
                StorageService.localizedText(
                  zhCN: '生成内容包含违规信息',
                  zhTW: '生成內容包含違規資訊',
                  en: 'The generated content contains violating information',
                  yue: '生成內容包含違規資訊',
                  es: 'El contenido generado contiene información que infringe las normas',
                  fr: 'Le contenu généré contient des informations non conformes',
                  de: 'Der generierte Inhalt enthält regelwidrige Informationen',
                  pt: 'O conteúdo gerado contém informações que violam as diretrizes',
                  ja: '生成された内容に違反情報が含まれています',
                  ko: '생성된 콘텐츠에 위반 정보가 포함되어 있습니다',
                ), evt['snippet'] as String? ?? '');
            break;
          case 'error':
            terminatedByEvent = true;
            idleTimer?.cancel(); // 已正常终止：停止 30s 等待计时，避免误弹超时
            onError(
              evt['message'] as String? ??
                  StorageService.localizedText(
                    zhCN: '生成失败',
                    zhTW: '生成失敗',
                    en: 'Generation failed',
                    yue: '生成失敗',
                    es: 'Error de generación',
                    fr: 'Échec de la génération',
                    de: 'Generierung fehlgeschlagen',
                    pt: 'Falha na geração',
                    ja: '生成に失敗しました',
                    ko: '생성에 실패했습니다',
                  ),
              code: evt['code'] as String?,
            );
            break;
          case 'done':
            // 【诊断】收到服务器 done 事件
            debugPrint('[story] received done event');
            doneCalled = true;
            idleTimer?.cancel(); // 正常生成完成：立即停止等待计时
            onDone(
              (evt['outputs'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            break;
          default:
            // 【诊断】未识别事件：若第二个弹窗其实以别的名字发来，会在此暴露
            debugPrint('[story] UNKNOWN event=$event raw=$raw');
            break;
        }
      }
      idleTimer?.cancel();
      // 【诊断】流结束时的状态（用于判断"没收到 done"是否发生）
      debugPrint('[story] stream ended: doneCalled=$doneCalled '
          'stalled=$stalled terminatedByEvent=$terminatedByEvent');
      // 流式结束但未收到 done 事件：
      // - 已判定卡死（stalled）：已由 onStalled 处理，不再重复处理；
      // - 已收到 error/abort 事件（terminatedByEvent）：已由对应回调处理；
      // - 否则：服务器无结束信号直接关闭（通常即服务器侧超时关闭了流），
      //   复用现有"网络疑似超时，请重启重试"弹窗（onStalled），禁止基于残缺文本续写。
      if (!doneCalled && !stalled && !terminatedByEvent) {
        debugPrint('[story] post-loop -> onStalled (no done received)');
        stalled = true;
        final stall = onStalled;
        if (stall != null) {
          stall();
        } else {
          onError(StorageService.localizedText(
            zhCN: '生成未完整接收（未收到服务器结束信号），请检查网络后重试',
            zhTW: '生成未完整接收（未收到伺服器結束訊號），請檢查網路後重試',
            en: 'Generation was incomplete (no server completion signal). Please check your network and try again.',
            yue: '生成未完整接收（未收到伺服器結束訊號），請檢查網路後再試',
            es: 'La generación fue incompleta (no se recibió la señal de finalización del servidor). Compruebe su red e inténtelo de nuevo.',
            fr: 'La génération est incomplète (aucun signal de fin du serveur). Vérifiez votre réseau et réessayez.',
            de: 'Die Generierung war unvollständig (kein Abschlusssignal vom Server). Bitte prüfen Sie Ihr Netzwerk und versuchen Sie es erneut.',
            pt: 'A geração ficou incompleta (nenhum sinal de conclusão do servidor). Verifique sua rede e tente novamente.',
            ja: '生成が不完全でした（サーバーからの終了信号がありません）。ネットワークを確認して、もう一度お試しください。',
            ko: '생성이 불완전했습니다(서버 종료 신호 없음). 네트워크를 확인하고 다시 시도해 주세요.',
          ));
        }
      }
    } catch (e) {
      if (stalled) return; // 卡死已由 onStalled 处理，不再重复报错
      if (e.toString().contains('TimeoutException')) {
        // 用户等待 FastAPI 超时（30 秒无数据）：复用现有"网络疑似超时，请重启重试"
        // 弹窗（onStalled）；未注册 onStalled 时退回通用错误文案。
        stalled = true;
        final stall = onStalled;
        if (stall != null) {
          stall();
          return;
        }
        onError(StorageService.localizedText(
          zhCN: '生成超时，请稍后重试',
          zhTW: '生成逾時，請稍後重試',
          en: 'Generation timed out. Please try again later.',
          yue: '生成逾時，請稍後再試',
          es: 'La generación agotó el tiempo. Inténtelo de nuevo más tarde.',
          fr: 'La génération a expiré. Veuillez réessayer plus tard.',
          de: 'Die Generierung ist abgelaufen. Bitte versuchen Sie es später erneut.',
          pt: 'A geração expirou. Tente novamente mais tarde.',
          ja: '生成がタイムアウトしました。後でもう一度お試しください。',
          ko: '생성 시간이 초과되었습니다. 나중에 다시 시도해 주세요.',
        ));
      } else if (e is http.ClientException) {
        onError(StorageService.localizedText(
          zhCN: '无法连接服务器，请检查网络后重试',
          zhTW: '無法連接伺服器，請檢查網路後重試',
          en: 'Unable to connect to the server. Please check your network and try again.',
          yue: '無法連接伺服器，請檢查網路後再試',
          es: 'No se pudo conectar con el servidor. Compruebe su red e inténtelo de nuevo.',
          fr: 'Impossible de se connecter au serveur. Vérifiez votre réseau et réessayez.',
          de: 'Keine Verbindung zum Server möglich. Bitte prüfen Sie Ihr Netzwerk und versuchen Sie es erneut.',
          pt: 'Não foi possível conectar ao servidor. Verifique sua rede e tente novamente.',
          ja: 'サーバーに接続できません。ネットワークを確認して、もう一度お試しください。',
          ko: '서버에 연결할 수 없습니다. 네트워크를 확인하고 다시 시도해 주세요.',
        ));
      } else {
        onError(e.toString());
      }
    } finally {
      client.close();
    }
  }

  /// 【调试专用】获取服务器数据库（story_segments）最新一条生成条目的全部字段。
  ///
  /// 调用服务器调试端点 `GET /api/story/latest`，返回完整一行
  /// （含 content / music_style / 设定快照 / 案件信息等所有列）。
  /// 失败或未登录时返回 null，由调用方决定如何提示。
  static Future<Map<String, dynamic>?> fetchLatestStoryRow() async {
    final story = _storyApiUrl; // 形如 http://host/api/generate-story
    if (story.isEmpty) return null;
    // 调试端点固定为 /api/story/latest，需把故事生成地址的 /api/generate-story
    // 替换为 /api/story/latest（不能直接拼接 /latest，否则会得到不存在的
    // /api/generate-story/latest）。
    final String url = story.contains('/api/generate-story')
        ? story.replaceFirst('/api/generate-story', '/api/story/latest')
        : '$story/latest';
    final token = await AuthService.ensureToken();
    final client = http.Client();
    try {
      final resp = await client
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map && decoded['latest'] is Map) {
        return (decoded['latest'] as Map).cast<String, dynamic>();
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 违规修正确认：通知服务器继续调用"违规修正"工作流。请求体只需 request_id。
  static Future<bool> confirmRevise(String requestId) async {
    final story = _storyApiUrl; // 形如 http://host/api/generate-story
    if (story.isEmpty || requestId.isEmpty) return false;
    final String url = '$story/revise-confirm';
    final token = await AuthService.ensureToken();
    final client = http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'request_id': requestId}),
          )
          .timeout(const Duration(seconds: 30));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// 【调试】通知服务器"确认发送"：放行正在等待的 /api/generate-story 流式请求，
  /// 使服务器真正调用 Dify。请求体只需 request_id（服务器用其匹配 asyncio.Event）。
  static Future<bool> confirmPayload(String requestId) async {
    final story = _storyApiUrl; // 形如 http://host/api/generate-story
    if (story.isEmpty || requestId.isEmpty) return false;
    final String url = '$story/confirm';
    final token = await AuthService.ensureToken();
    final client = http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'request_id': requestId}),
          )
          .timeout(const Duration(seconds: 30));
      final ok = resp.statusCode == 200;
      debugPrint('[story] confirmPayload id=$requestId http=${resp.statusCode} ok=$ok');
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }
}
