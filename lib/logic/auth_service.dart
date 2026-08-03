import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/storage_service.dart';

/// 审核令牌服务：负责向服务器注册设备并获取签名令牌，
/// 令牌存储在系统安全存储（iOS Keychain / Android Keystore）中。
class AuthService {
  AuthService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static const String _tokenKey = 'audit_token';
  static const String _tokenExpiryKey = 'audit_token_expiry';

  /// 注册接口地址（来自 .env）
  static String get _registerApiUrl =>
      dotenv.env['REGISTER_API_URL'] ?? '';

  /// 获取有效的审核令牌；不存在或已过期时自动向服务器注册。
  /// 返回的令牌可直接用于 `Authorization: Bearer <token>`。
  static Future<String> ensureToken() async {
    final existing = await _storage.read(key: _tokenKey);
    final expiryStr = await _storage.read(key: _tokenExpiryKey);
    final expiry = int.tryParse(expiryStr ?? '') ?? 0;
    // 提前 60 秒视为过期，避免临界失效
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (existing != null &&
        existing.isNotEmpty &&
        expiry > 0 &&
        nowSec < expiry - 60) {
      return existing;
    }
    return _register();
  }

  /// 向服务器注册当前设备，获取并存储签名令牌。
  static Future<String> _register() async {
    final url = _registerApiUrl;
    if (url.isEmpty) {
      throw Exception('服务器注册地址未配置：请检查 .env 中的 REGISTER_API_URL');
    }
    final deviceId = StorageService.getUserUniqueId();
    if (deviceId.isEmpty) {
      throw Exception('设备唯一 ID 缺失，无法注册');
    }

    final response = await http
        .post(
          Uri.parse(url),
          headers: {'accept': 'application/json', 'Content-Type': 'application/json'},
          body: jsonEncode({'device_id': deviceId}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('设备注册失败：HTTP ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    final expiresAt = (data['expires_at'] as num?)?.toInt();
    if (token == null || token.isEmpty || expiresAt == null) {
      throw Exception('服务器返回的令牌无效');
    }

    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _tokenExpiryKey, value: '$expiresAt');
    return token;
  }

  /// 清除已存储的令牌（如用户重置时调用）。
  static Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _tokenExpiryKey);
  }
}
