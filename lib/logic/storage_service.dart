import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 持久化存储服务
class StorageService {
  static const String _keyMainText = 'main_text';
  static const String _keyButton1Content = 'button1_content';
  static const String _keyButton2Content = 'button2_content';
  static const String _keyInputContent = 'input_content';
  static const String _keyIsInitialized = 'is_initialized';
  static const String _keyPlayerName = 'player_name';
  static const String _keyPlayerGender = 'player_gender';
  static const String _keyPartnerName = 'partner_name';
  static const String _keyPartnerGender = 'partner_gender';
  static const String _keyPartnerTraits = 'partner_traits';
  static const String _keyRegion = 'region';
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

  // ---- 地区 ----

  /// 保存用户选择的地区
  static Future<void> saveRegion(String region) async {
    await _prefs.setString(_keyRegion, region);
  }

  /// 读取用户选择的地区
  static String getRegion() {
    return _prefs.getString(_keyRegion) ?? '';
  }

  // ---- 主文本内容（初始"正"字） ----

  /// 保存主文本内容
  static Future<void> saveMainText(String text) async {
    await _prefs.setString(_keyMainText, text);
  }

  /// 读取主文本内容
  static String getMainText() {
    return _prefs.getString(_keyMainText) ?? '';
  }

  /// 检查是否已保存过初始文本
  static bool hasMainText() {
    return _prefs.containsKey(_keyMainText);
  }

  // ---- 按钮1追加内容 ----

  /// 保存按钮1追加的内容
  static Future<void> saveButton1Content(String text) async {
    await _prefs.setString(_keyButton1Content, text);
  }

  /// 读取按钮1追加的内容
  static String getButton1Content() {
    return _prefs.getString(_keyButton1Content) ?? '';
  }

  // ---- 按钮2追加内容 ----

  /// 保存按钮2追加的内容
  static Future<void> saveButton2Content(String text) async {
    await _prefs.setString(_keyButton2Content, text);
  }

  /// 读取按钮2追加的内容
  static String getButton2Content() {
    return _prefs.getString(_keyButton2Content) ?? '';
  }

  // ---- 输入框追加内容 ----

  /// 保存输入框追加的内容
  static Future<void> saveInputContent(String text) async {
    await _prefs.setString(_keyInputContent, text);
  }

  /// 读取输入框追加的内容
  static String getInputContent() {
    return _prefs.getString(_keyInputContent) ?? '';
  }

  // ---- 全量获取（用于展示） ----

  /// 获取完整展示文本（主文本 + 按钮1 + 按钮2 + 输入框）
  static String getFullDisplayText() {
    return getMainText() +
        getButton1Content() +
        getButton2Content() +
        getInputContent();
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
    await _prefs.setString(_keyMainText, '');
    await _prefs.setString(_keyButton1Content, '');
    await _prefs.setString(_keyButton2Content, '');
    await _prefs.setString(_keyInputContent, '');
    await _prefs.setString(_keyPlayerName, '');
    await _prefs.setString(_keyPlayerGender, '');
    await _prefs.setString(_keyPartnerName, '');
    await _prefs.setString(_keyPartnerGender, '');
    await _prefs.setString(_keyPartnerTraits, '');
    await _prefs.setString(_keyRegion, '');
    await _prefs.setBool(_keyIsInitialized, false);
  }
}
