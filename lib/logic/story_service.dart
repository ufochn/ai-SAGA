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
    required String location,
    required String era,
    required String playerName,
    required String playerGender,
    required String partnerName,
    required String partnerGender,
    required String partnerTraits,
    required String language,
    String userInput = '',
    int userInputCounter = 0,
    required void Function(String text) onChunk,
    required void Function(String text, Map<String, dynamic> outputs) onReveal,
    required void Function(String reason) onAbort,
    required void Function(String message) onError,
    required void Function(Map<String, dynamic> outputs) onDone,
  }) async {
    final url = _storyApiUrl;
    if (url.isEmpty) {
      onError('小说生成地址未配置：请检查 .env 中的 STORY_API_URL 或 AUDIT_API_URL');
      return;
    }
    final token = await AuthService.ensureToken();

    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse(url));
      request.headers.addAll({
        'accept': 'text/event-stream',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      });
      request.body = jsonEncode({
        'location': location,
        'era': era,
        'player_name': playerName,
        'player_gender': playerGender,
        'partner_name': partnerName,
        'partner_gender': partnerGender,
        'partner_traits': partnerTraits,
        'language': language,
        'user_input': userInput,
        'user_input_counter': userInputCounter,
      });

      final response = await client.send(request).timeout(const Duration(seconds: 180));
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
        onError(detail);
        return;
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
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
            onError(evt['message'] as String? ?? '生成失败');
            break;
          case 'done':
            onDone(
              (evt['outputs'] as Map?)?.cast<String, dynamic>() ?? const {},
            );
            break;
          default:
            break;
        }
      }
    } catch (e) {
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
