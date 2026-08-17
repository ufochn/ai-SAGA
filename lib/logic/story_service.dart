import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/storage_service.dart';

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
    String playerGender = '',
    String playerTraits = '',
    String partnerName = '',
    String partnerGender = '',
    String partnerTraits = '',
    String language = '',
    required void Function(String text) onChunk,
    required void Function(String text, Map<String, dynamic> outputs) onReveal,
    required void Function(String reason) onAbort,
    required void Function(String message, {String? code}) onError,
    void Function()? onDeviceConflict,
    void Function()? onStalled,
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
    // 流式"卡死"标记：40 秒内没有任何数据到达（且未收到 done）时置 true，由 onStalled 处理
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
        'choice_1': choice1,
        'choice_2': choice2,
        'choice_3': choice3,
        'location': location,
        'era': era,
        'player_name': playerName,
        'player_gender': playerGender,
        'player_traits': playerTraits,
        'partner_name': partnerName,
        'partner_gender': partnerGender,
        'partner_traits': partnerTraits,
        'language': language,
        if (rewriteFrom != null) 'rewrite_from': rewriteFrom,
      });

      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 180));
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
        onError(detail);
        return;
      }

      var doneCalled = false;
      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(
            const Duration(seconds: 40),
            onTimeout: (sink) {
              // 40 秒内没有任何数据到达（且未收到 done）：判定为网络异常/卡死，
              // 通知上层弹出"请重启"警告，并结束本次流式读取，避免半截文本被误用。
              if (!stalled) {
                stalled = true;
                onStalled?.call();
              }
              sink.close();
            },
          );
      await for (final line in lines) {
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
          case 'chunk':
            onChunk(evt['text'] as String? ?? '');
            break;
          case 'reveal':
            onReveal(
              evt['text'] as String? ?? '',
              (evt['outputs'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            break;
          case 'abort':
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
                ));
            break;
          case 'error':
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
            doneCalled = true;
            onDone(
              (evt['outputs'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            break;
          default:
            break;
        }
      }
      // 流式结束但未收到 done 事件：
      // - 若已判定卡死（stalled），已由 onStalled 处理，不再重复处理；
      // - 否则视为"未完整接收"，按错误处理（禁止基于残缺文本续写）
      if (!doneCalled && !stalled) {
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
    } catch (e) {
      if (stalled) return; // 卡死已由 onStalled 处理，不再重复报错
      if (e.toString().contains('TimeoutException')) {
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
}
