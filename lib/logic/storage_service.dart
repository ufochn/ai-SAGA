import 'dart:math';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 持久化存储服务
class StorageService {
  static const String _keyLanguage = 'language';
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

  /// 读取用户选择的语言；本地未存储时按系统语言返回
  /// （保证新装用户开机标题等按系统语言正确显示）。
  static String getLanguage() {
    final stored = _prefs.getString(_keyLanguage);
    if (stored != null && stored.isNotEmpty) return stored;
    return getSystemLanguage();
  }

  /// 获取系统语言并映射到 App 支持的语言代码（无存储语言时的回退）。
  static String getSystemLanguage() {
    try {
      final locale = PlatformDispatcher.instance.locale;
      final code = locale.languageCode.toLowerCase();
      final script = (locale.scriptCode ?? '').toLowerCase();
      final country = (locale.countryCode ?? '').toUpperCase();
      if (code == 'zh') {
        if (script == 'hant' ||
            country == 'TW' ||
            country == 'HK' ||
            country == 'MO') {
          return 'zh-TW';
        }
        return 'zh';
      }
      const supported = {'en', 'es', 'fr', 'de', 'pt', 'ja', 'ko'};
      if (supported.contains(code)) return code;
    } catch (_) {
      // 忽略异常，退回默认
    }
    return 'zh';
  }

  /// 清除所有持久化数据（将所有内容设为空字符串）
  /// 注意：不删除用户唯一标识
  static Future<void> clearAll() async {
    await _prefs.setString(_keyLanguage, '');
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
