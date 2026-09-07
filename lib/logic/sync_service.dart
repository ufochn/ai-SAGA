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
  /// 与 segments 一一对应的脚本序号（"脚本id-章节"，如 "2-5"；无则为空串），
  /// 用于判断某段是否为一个脚本的最后一章。
  List<String> scriptIds,
  int startSeq,
  int total,
  String language,
  /// 服务器权威判定：老小说是否已写满且没有更新的小说 → App 打开应自动开始生成下一本。
  bool nextNeeded,
});

/// 表示服务器判定本设备已不是最新登入（被其它设备顶掉），写请求被拒（multi_client）。
/// 上层应弹出统一"多客户端"仅退出对话框。
class MultiClientConflictException implements Exception {
  const MultiClientConflictException();
}

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

  /// 云同步正文 GET 接口地址。
  /// 注意：/api/generate-story 仅接受 POST（生成），同步拉取正文必须用 GET /api/story。
  /// 显式配置了 STORY_API_URL（=/api/generate-story）时，把它替换成 /api/story。
  static String get _storyGetUrl {
    final url = _storyApiUrl;
    if (url.isEmpty) return '';
    return url.contains('/api/generate-story')
        ? url.replaceFirst('/api/generate-story', '/api/story')
        : url;
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
  /// 顺序（2026-09 口令规格，合并进"正在同步"一步，无需延后缓冲）：
  ///   ① ensureToken：新用户走 register（服务器已写口令）；老用户取缓存令牌；
  ///   ② device/activate：**取得"最新登入口令"**（超时 10s），保存返回的新令牌。
  ///      口令提交即权威屏障：旧设备之后的任何写入都会被 SQLite 事务串行 +
  ///      口令校验拒掉；本步只读不写，WAL 读取永远一致快照 → 口令成功后可直接拉取；
  ///   ③ 立即拉取小说尾部（最后 [tailLimit] 段）→ 覆盖本地。
  static Future<StorySnapshot> syncAll() async {
    final publicKey = await HardwareKeyService.getPublicKey();
    var token = await AuthService.ensureToken();
    token = await _activate(token, publicKey);
    return _pullStory(token, limit: tailLimit);
  }

  /// 重新开始：清空服务器上该用户的全部小说正文（POST /api/story/reset）。
  /// 成功后 App 重启，重启后同步拉取为空 → 判定为新用户 → 从设置重新开始。
  ///
  /// 注意：必须用 [_storyGetUrl]（它会把配置中的 `/api/generate-story`
  /// 归一化成 `/api/story`），再拼 `/reset`；若直接用 [_storyApiUrl]
  /// 会请求到不存在的 `/api/generate-story/reset` → 服务器 404。
  static Future<void> resetStory() async {
    final token = await AuthService.ensureToken();
    final url = _storyGetUrl;
    if (url.isEmpty) {
      throw Exception(StorageService.localizedText(
        zhCN: '小说存储地址未配置，无法清空服务器数据',
        zhTW: '小說儲存位址未配置，無法清空伺服器資料',
        en: 'Story storage URL is not configured. Unable to clear server data.',
        yue: '小說儲存位址未配置，無法清空伺服器資料',
        es: 'La URL de almacenamiento de historias no está configurada. No se pueden borrar los datos del servidor.',
        fr: "L'URL de stockage des histoires n'est pas configurée. Impossible d'effacer les données du serveur.",
        de: 'Die URL für die Story-Speicherung ist nicht konfiguriert. Serverdaten können nicht gelöscht werden.',
        pt: 'A URL de armazenamento de histórias não está configurada. Não foi possível limpar os dados do servidor.',
        ja: 'ストーリー保存URLが設定されていません。サーバーデータをクリアできません。',
        ko: '스토리 저장 URL이 구성되지 않았습니다. 서버 데이터를 지울 수 없습니다.',
      ));
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
      if (resp.body.contains('multi_client')) {
        // 本设备已不是最新登入（被其它设备顶掉）：清空被拒 → 交上层弹"仅退出"
        throw const MultiClientConflictException();
      }
      throw Exception(
        '${StorageService.localizedText(
          zhCN: '清空服务器数据失败',
          zhTW: '清空伺服器資料失敗',
          en: 'Failed to clear server data',
          yue: '清空伺服器資料失敗',
          es: 'Error al borrar los datos del servidor',
          fr: 'Échec de l\'effacement des données du serveur',
          de: 'Fehler beim Löschen der Serverdaten',
          pt: 'Falha ao limpar os dados do servidor',
          ja: 'サーバーデータのクリアに失敗しました',
          ko: '서버 데이터를 지우지 못했습니다',
        )}: HTTP ${resp.statusCode} ${resp.body}',
      );
    }
  }

  /// 向上懒加载更早的段落：取 seq < [beforeSeq] 的最近 [limit] 段，前插到本地数组。
  static Future<StorySnapshot> fetchPreviousSegments(
    int beforeSeq, {
    int limit = previousBatchLimit,
  }) async {
    final token = await AuthService.ensureToken();
    final url = _storyGetUrl;
    if (url.isEmpty) {
      return (
        segments: const <String>[],
        choices: const <List<String>>[],
        userChoices: const <String>[],
        scriptIds: const <String>[],
        startSeq: 0,
        total: 0,
        language: '',
        nextNeeded: false,
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
      throw Exception(
        '${StorageService.localizedText(
          zhCN: '加载更早章节失败',
          zhTW: '載入更早章節失敗',
          en: 'Failed to load earlier chapters',
          yue: '載入更早章節失敗',
          es: 'Error al cargar capítulos anteriores',
          fr: 'Échec du chargement des chapitres précédents',
          de: 'Fehler beim Laden früherer Kapitel',
          pt: 'Falha ao carregar capítulos anteriores',
          ja: '以前の章の読み込みに失敗しました',
          ko: '이전 장을 불러오지 못했습니다',
        )}: HTTP ${resp.statusCode} ${resp.body}',
      );
    }
    return _parseStory(resp.body);
  }

  /// 握手 = **写"最新登入口令"**（POST /api/device/activate）。
  /// 成功返回本次登录应使用的令牌：服务器每次返回携带新 login_ts 的令牌，
  /// 这里保存新令牌并以其继续后续请求（否则沿用旧 token）。
  static Future<String> _activate(String token, String publicKey) async {
    final url = _activateApiUrl;
    if (url.isEmpty) return token;
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
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception(
        '${StorageService.localizedText(
          zhCN: '设备激活失败',
          zhTW: '裝置啟用失敗',
          en: 'Device activation failed',
          yue: '裝置啟用失敗',
          es: 'Error al activar el dispositivo',
          fr: 'Échec de l\'activation de l\'appareil',
          de: 'Geräteaktivierung fehlgeschlagen',
          pt: 'Falha na ativação do dispositivo',
          ja: 'デバイスのアクティベーションに失敗しました',
          ko: '기기 활성화에 실패했습니다',
        )}: HTTP ${resp.statusCode} ${resp.body}',
      );
    }
    try {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final newToken = data['token'] as String?;
      final exp = (data['expires_at'] as num?)?.toInt();
      if (newToken != null && newToken.isNotEmpty && exp != null) {
        await AuthService.saveToken(newToken, exp);
        return newToken;
      }
    } catch (_) {
      // 服务器未返回新令牌（旧版/异常）：沿用旧 token
    }
    return token;
  }

  /// 从服务器拉取该用户的小说正文（limit>0 只拉最后 limit 段）。
  static Future<StorySnapshot> _pullStory(
    String token, {
    int limit = 0,
  }) async {
    final url = _storyGetUrl;
    if (url.isEmpty) {
      return (
        segments: const <String>[],
        choices: const <List<String>>[],
        userChoices: const <String>[],
        scriptIds: const <String>[],
        startSeq: 0,
        total: 0,
        language: '',
        nextNeeded: false,
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
      throw Exception(
        '${StorageService.localizedText(
          zhCN: '数据同步失败',
          zhTW: '資料同步失敗',
          en: 'Data sync failed',
          yue: '資料同步失敗',
          es: 'Error de sincronización de datos',
          fr: 'Échec de la synchronisation des données',
          de: 'Datensynchronisierung fehlgeschlagen',
          pt: 'Falha na sincronização de dados',
          ja: 'データ同期に失敗しました',
          ko: '데이터 동기화에 실패했습니다',
        )}: HTTP ${resp.statusCode} ${resp.body}',
      );
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
    // 脚本序号（current_script_ids）与 segments 一一对应；缺失用空串
    final rawScriptIds = (data['current_script_ids'] as List?) ?? const [];
    final scriptIds =
        rawScriptIds.map((e) => (e as String?) ?? '').toList();
    return (
      segments: segments,
      choices: choices,
      userChoices: userChoices,
      scriptIds: scriptIds,
      startSeq: startSeq,
      total: total,
      language: language,
      nextNeeded: (data['next_needed'] as bool?) ?? false,
    );
  }
}
