import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 持久化存储服务
class StorageService {
  static const String _keyMainTextList = 'main_text_list';
  static const String _keyMainTextStartIndex = 'main_text_start_index';
  static const String _keyIsInitialized = 'is_initialized';
  static const String _keyPlayerName = 'player_name';
  static const String _keyPlayerGender = 'player_gender';
  static const String _keyPartnerName = 'partner_name';
  static const String _keyPartnerGender = 'partner_gender';
  static const String _keyPartnerTraits = 'partner_traits';
  static const String _keyLanguage = 'language';
  static const String _keyLocation = 'location';
  static const String _keyEra = 'era';
  //用来限制用户调取ai api频率的标识码
  static const String _keyUserUniqueId = 'user_unique_id';
  // 夜间模式
  static const String _keyIsDarkMode = 'is_dark_mode';

  static late SharedPreferences _prefs;

  /// 初始化存储服务（在 app 启动时调用）
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // 首次运行时生成默认唯一设备标识
    await _ensureUserUniqueId();
  }

  /// 确保用户存在唯一标识，如没有则生成并保存
  static Future<void> _ensureUserUniqueId() async {
    if (!_prefs.containsKey(_keyUserUniqueId)) {
      final uniqueId = _generateRandomId();
      await _prefs.setString(_keyUserUniqueId, uniqueId);
    }
  }

  /// 生成一个不可猜测的随机唯一ID（36位，类似UUID格式）
  static String _generateRandomId() {
    const chars = '0123456789abcdef';
    final random = Random.secure();
    final segments = [8, 4, 4, 4, 12];
    final parts = segments.map((len) {
      return List.generate(
        len,
        (_) => chars[random.nextInt(chars.length)],
      ).join();
    });
    return parts.join('-');
  }

  /// 获取用户唯一标识
  static String getUserUniqueId() {
    return _prefs.getString(_keyUserUniqueId) ?? '';
  }

  // ---- 夜间模式 ----

  /// 保存夜间模式偏好
  static Future<void> saveIsDarkMode(bool isDarkMode) async {
    await _prefs.setBool(_keyIsDarkMode, isDarkMode);
  }

  /// 读取夜间模式偏好
  static bool getIsDarkMode() {
    return _prefs.getBool(_keyIsDarkMode) ?? false;
  }

  // ---- 语言 ----

  /// 保存用户选择的语言
  static Future<void> saveLanguage(String language) async {
    await _prefs.setString(_keyLanguage, language);
  }

  /// 读取用户选择的语言
  static String getLanguage() {
    return _prefs.getString(_keyLanguage) ?? '';
  }

  // ---- 地点 ----

  /// 保存用户选择的地点
  static Future<void> saveLocation(String location) async {
    await _prefs.setString(_keyLocation, location);
  }

  /// 读取用户选择的地点
  static String getLocation() {
    return _prefs.getString(_keyLocation) ?? '';
  }

  // ---- 年代 ----

  /// 保存用户选择的年代
  static Future<void> saveEra(String era) async {
    await _prefs.setString(_keyEra, era);
  }

  /// 读取用户选择的年代
  static String getEra() {
    return _prefs.getString(_keyEra) ?? '';
  }

  // ---- 小说正文数组（每次生成的内容单独一个元素） ----

  /// 保存小说正文数组（本地只保留已加载的尾部，服务器为权威数据源）
  static Future<void> saveMainTextList(List<String> texts) async {
    await _prefs.setString(_keyMainTextList, jsonEncode(texts));
  }

  /// 读取小说正文数组（未保存或数据损坏时返回空列表）
  static List<String> getMainTextList() {
    final raw = _prefs.getString(_keyMainTextList);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 数据损坏时忽略，返回空列表
    }
    return [];
  }

  /// 保存本地小说数组第一个元素对应的服务器绝对下标（保证与服务器 seq 对齐）
  static Future<void> saveMainTextStartIndex(int index) async {
    await _prefs.setInt(_keyMainTextStartIndex, index);
  }

  /// 读取本地小说数组第一个元素的绝对下标（默认 0）
  static int getMainTextStartIndex() {
    return _prefs.getInt(_keyMainTextStartIndex) ?? 0;
  }

  // ---- 初始化数据（角色设定） ----

  /// 检查是否已完成初始化设定
  static bool isInitialized() {
    return _prefs.getBool(_keyIsInitialized) ?? false;
  }

  /// 标记为已初始化
  static Future<void> setInitialized() async {
    await _prefs.setBool(_keyIsInitialized, true);
  }

  /// 保存玩家姓名
  static Future<void> savePlayerName(String name) async {
    await _prefs.setString(_keyPlayerName, name);
  }

  /// 读取玩家姓名
  static String getPlayerName() {
    return _prefs.getString(_keyPlayerName) ?? '';
  }

  /// 保存玩家性别
  static Future<void> savePlayerGender(String gender) async {
    await _prefs.setString(_keyPlayerGender, gender);
  }

  /// 读取玩家性别
  static String getPlayerGender() {
    return _prefs.getString(_keyPlayerGender) ?? '';
  }

  /// 保存搭档姓名
  static Future<void> savePartnerName(String name) async {
    await _prefs.setString(_keyPartnerName, name);
  }

  /// 读取搭档姓名
  static String getPartnerName() {
    return _prefs.getString(_keyPartnerName) ?? '';
  }

  /// 保存搭档性别
  static Future<void> savePartnerGender(String gender) async {
    await _prefs.setString(_keyPartnerGender, gender);
  }

  /// 读取搭档性别
  static String getPartnerGender() {
    return _prefs.getString(_keyPartnerGender) ?? '';
  }

  /// 保存搭档特质
  static Future<void> savePartnerTraits(String traits) async {
    await _prefs.setString(_keyPartnerTraits, traits);
  }

  /// 读取搭档特质
  static String getPartnerTraits() {
    return _prefs.getString(_keyPartnerTraits) ?? '';
  }

  /// 仅重置初始化状态（不清除其他数据），用于返回地区选择页面
  static Future<void> resetInitialization() async {
    await _prefs.setBool(_keyIsInitialized, false);
  }

  /// 清除所有持久化数据（将所有内容设为空字符串）
  /// 注意：不删除用户唯一标识
  static Future<void> clearAll() async {
    await _prefs.setString(_keyMainTextList, '');
    await _prefs.setString(_keyPlayerName, '');
    await _prefs.setString(_keyPlayerGender, '');
    await _prefs.setString(_keyPartnerName, '');
    await _prefs.setString(_keyPartnerGender, '');
    await _prefs.setString(_keyPartnerTraits, '');
    await _prefs.setString(_keyLocation, '');
    await _prefs.setString(_keyEra, '');
    await _prefs.setString(_keyLanguage, '');
    await _prefs.setBool(_keyIsInitialized, false);
  }

  // ---- 安全存储（iOS Keychain / Android Keystore）----

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    // Android 默认使用 Keystore 加密存储，无需 encryptedSharedPreferences
    // （Jetpack Security 已废弃，该参数在新版本会被忽略）
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// 保存敏感信息到系统安全存储（登录会话、令牌等）。
  static Future<void> saveSecure(String key, String value) async {
    await _secureStorage.write(key: key, value: value);
  }

  /// 从系统安全存储读取敏感信息；不存在返回 null。
  static Future<String?> getSecure(String key) async {
    return _secureStorage.read(key: key);
  }

  /// 从系统安全存储删除敏感信息。
  static Future<void> deleteSecure(String key) async {
    await _secureStorage.delete(key: key);
  }
}
