import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/auth_service.dart';

/// 小说生成服务（流式）：把用户设定发送到 FastAPI 网关，网关先审首段、
/// 通过后以 SSE 流式返回正文（chunk → reveal），用于打字机效果显示。
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
  /// [onReveal]：剩余正文 + 结束节点 outputs（审核通过后一次性显示）
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
      onError('小说生成地址未配置：请检查 .env 中的 STORY_API_URL 或 AUDIT_API_URL');
      return;
    }
    final token = await AuthService.ensureToken();

    final client = http.Client();
    // 流式"卡死"标记：30 秒内没有任何数据到达（且未收到 done）时置 true，由 onStalled 处理
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
            const Duration(seconds: 30),
            onTimeout: (sink) {
              // 30 秒内没有任何数据到达（且未收到 done）：判定为网络异常/卡死，
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
            onAbort(evt['reason'] as String? ?? '生成内容包含违规信息');
            break;
          case 'error':
            onError(
              evt['message'] as String? ?? '生成失败',
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
        onError('生成未完整接收（未收到服务器结束信号），请检查网络后重试');
      }
    } catch (e) {
      if (stalled) return; // 卡死已由 onStalled 处理，不再重复报错
      if (e.toString().contains('TimeoutException')) {
        onError('生成超时，请稍后重试');
      } else {
        onError(e.toString());
      }
    } finally {
      client.close();
    }
  }
}
