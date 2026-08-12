import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/hardware_key_service.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 一次小说数据快照：本地数组 + 与 segments 一一对应的三个选项（choice_1/2/3，
/// LLM② 推荐的下一轮行动）+ 与 segments 一一对应的用户本轮实际选择文本（user_choices）
/// + 首元素绝对下标（与服务器 seq 对齐）+ 总段数 + 服务器金标准语言。
typedef StorySnapshot = ({
  List<String> segments,
  List<List<String>> choices,
  List<String> userChoices,
  int startSeq,
  int total,
  String language,
});

/// 启动同步服务：每次 App 启动时
/// 1) 上传本机硬件公钥 + 用户 id，服务器校验后更新硬件公钥并登记为活跃设备；
/// 2) 从服务器拉取小说正文的尾部（默认最后 3 段），单方面刷新 App 本地数据；
/// 只有同步成功后才允许运行后续功能（由 HomeContent 作为启动门禁调用）。
class SyncService {
  SyncService._();

  /// 冷启动只拉尾部多少段（不读整本）
  static const int tailLimit = 3;

  /// 向上懒加载时一次拉取的段数（比启动尾部更多，减少上滑时的请求次数）
  static const int previousBatchLimit = 10;

  /// 小说正文云存储地址（来自 .env 或由 AUDIT_API_URL 推导）
  static String get _storyApiUrl {
    final direct = dotenv.env['STORY_API_URL'] ?? '';
    if (direct.isNotEmpty) return direct;
    final audit = dotenv.env['AUDIT_API_URL'] ?? '';
    if (audit.contains('/api/audit-and-chat')) {
      return audit.replaceFirst('/api/audit-and-chat', '/api/story');
    }
    return '';
  }

  /// 设备激活地址（来自 .env 或由注册地址推导）
  static String get _activateApiUrl {
    final direct = dotenv.env['ACTIVATE_API_URL'] ?? '';
    if (direct.isNotEmpty) return direct;
    final reg = dotenv.env['REGISTER_API_URL'] ?? '';
    if (reg.contains('/api/register')) {
      return reg.replaceFirst('/api/register', '/api/device/activate');
    }
    return '';
  }

  /// 启动同步（硬性前置）：任一环节失败都会抛出异常，由调用方门禁处理。
  ///
  /// 流程：上传硬件公钥 + 用户 id（服务器校验并更新硬件公钥）
  ///      → 拉取服务器小说尾部（最后 [tailLimit] 段）→ 覆盖写入 App 本地存储。
  static Future<StorySnapshot> syncAll() async {
    final token = await AuthService.ensureToken();
    final publicKey = await HardwareKeyService.getPublicKey();
    await _activate(token, publicKey);
    return _pullStory(token, limit: tailLimit);
  }

  /// 重新开始：清空服务器上该用户的全部小说正文（POST /api/story/reset）。
  /// 成功后 App 重启，重启后同步拉取为空 → 判定为新用户 → 从设置重新开始。
  static Future<void> resetStory() async {
    final token = await AuthService.ensureToken();
    final url = _storyApiUrl;
    if (url.isEmpty) {
      throw Exception('小说存储地址未配置，无法清空服务器数据');
    }
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final resp = await http
        .post(
          Uri.parse('$base/reset'),
          headers: {
            'accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('清空服务器数据失败：HTTP ${resp.statusCode} ${resp.body}');
    }
  }

  /// 向上懒加载更早的段落：取 seq < [beforeSeq] 的最近 [limit] 段，前插到本地数组。
  static Future<StorySnapshot> fetchPreviousSegments(
    int beforeSeq, {
    int limit = previousBatchLimit,
  }) async {
    final token = await AuthService.ensureToken();
    final url = _storyApiUrl;
    if (url.isEmpty) {
      return (
        segments: const <String>[],
        choices: const <List<String>>[],
        userChoices: const <String>[],
        startSeq: 0,
        total: 0,
        language: '',
      );
    }
    final resp = await http
        .get(
          Uri.parse(url).replace(
            queryParameters: {
              'before_seq': '$beforeSeq',
              'limit': '$limit',
            },
          ),
          headers: {
            'accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('加载更早章节失败：HTTP ${resp.statusCode} ${resp.body}');
    }
    return _parseStory(resp.body);
  }

  /// 握手：上传硬件公钥 + 用户 id，服务器校验后更新硬件公钥（失败抛异常）。
  static Future<void> _activate(String token, String publicKey) async {
    final url = _activateApiUrl;
    if (url.isEmpty) return;
    final resp = await http
        .post(
          Uri.parse(url),
          headers: {
            'accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'user_id': StorageService.getUserUniqueId(),
            'public_key': publicKey,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('设备激活失败：HTTP ${resp.statusCode} ${resp.body}');
    }
  }

  /// 从服务器拉取该用户的小说正文（limit>0 只拉最后 limit 段）。
  static Future<StorySnapshot> _pullStory(
    String token, {
    int limit = 0,
  }) async {
    final url = _storyApiUrl;
    if (url.isEmpty) {
      return (
        segments: const <String>[],
        choices: const <List<String>>[],
        userChoices: const <String>[],
        startSeq: 0,
        total: 0,
        language: '',
      );
    }
    final uri = limit > 0
        ? Uri.parse(url).replace(queryParameters: {'limit': '$limit'})
        : Uri.parse(url);
    final resp = await http
        .get(
          uri,
          headers: {
            'accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('数据同步失败：HTTP ${resp.statusCode} ${resp.body}');
    }
    return _parseStory(resp.body);
  }

  static StorySnapshot _parseStory(String body) {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final segments = (data['segments'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    // choices 与 segments 一一对应；缺失/不足 3 个时用空串补齐
    final rawChoices = (data['choices'] as List?) ?? const [];
    final choices = rawChoices.map((c) {
      final list = (c as List?) ?? const <dynamic>[];
      return <String>[
        for (int i = 0; i < 3; i++)
          (i < list.length ? list[i]?.toString() : null) ?? '',
      ];
    }).toList();
    // 用户本轮实际选择文本（user_choices）与 segments 一一对应；缺失用空串
    final rawUserChoices = (data['user_choices'] as List?) ?? const [];
    final userChoices = rawUserChoices
        .map((e) => (e as String?) ?? '')
        .toList();
    final startSeq = (data['start_seq'] as num?)?.toInt() ?? 0;
    final total = (data['total'] as num?)?.toInt() ?? segments.length;
    // 服务器金标准语言（老用户换新设备时据此覆盖本地语言）
    final language = (data['language'] as String?) ?? '';
    return (
      segments: segments,
      choices: choices,
      userChoices: userChoices,
      startSeq: startSeq,
      total: total,
      language: language,
    );
  }
}
