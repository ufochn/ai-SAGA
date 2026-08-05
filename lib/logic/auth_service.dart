import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/account_service.dart';
import 'package:ai_saga/logic/hardware_key_service.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 审核令牌服务：负责向服务器注册设备（账号 + 硬件公钥 + 挑战签名），
/// 获取并缓存签名令牌。令牌存储在系统安全存储（iOS Keychain / Android Keystore）中。
class AuthService {
  AuthService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static const String _tokenKey = 'audit_token';
  static const String _tokenExpiryKey = 'audit_token_expiry';

  /// 注册接口地址（来自 .env）
  static String get _registerApiUrl => dotenv.env['REGISTER_API_URL'] ?? '';

  /// 挑战获取地址（来自 .env 或由注册地址推导）
  static String get _challengeApiUrl =>
      dotenv.env['CHALLENGE_API_URL'] ?? '$_registerApiUrl/challenge';

  /// 获取有效的审核令牌；不存在或已过期时自动注册。
  /// 进行中的注册请求，供并发调用共享，避免重复注册触发服务器限流。
  static Future<String>? _pendingRegister;

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
    // 并发调用共享同一次注册，避免重复请求触发服务器限流（"请求过于频繁"）
    if (_pendingRegister != null) {
      return _pendingRegister!;
    }
    final pending = _register().whenComplete(() {
      _pendingRegister = null;
    });
    _pendingRegister = pending;
    return pending;
  }

  /// 向服务器注册当前设备（账号 + 硬件公钥 + 挑战签名），获取并存储签名令牌。
  static Future<String> _register() async {
    final url = _registerApiUrl;
    if (url.isEmpty) {
      throw Exception('服务器注册地址未配置：请检查 .env 中的 REGISTER_API_URL');
    }

    // 1) 轻授权账号（若未授权则抛错，由上层引导到 LightAuthPage）
    final account = await AccountService.getCachedAccount();
    if (account == null) {
      throw const AuthNotAuthorizedException();
    }

    // 2) 设备标识（稳定、持久）
    final deviceId = StorageService.getUserUniqueId();
    if (deviceId.isEmpty) {
      throw Exception('设备唯一 ID 缺失，无法注册');
    }

    // 3) 硬件公钥（私钥永不出安全硬件）
    final publicKey = await HardwareKeyService.getPublicKey();

    // 4) 向服务器要挑战（一次性随机数），避免重放
    final challengeInfo = await _fetchChallenge(deviceId);
    final String challenge = challengeInfo['challenge']!;
    final String challengeId = challengeInfo['challenge_id']!;

    // 5) 用安全硬件私钥对挑战签名，证明持有该硬件密钥
    final signature = await HardwareKeyService.sign(challenge);

    // 6) 上报注册
    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'device_id': deviceId,
            'public_key': publicKey,
            'provider': account.provider,
            'user_id': account.userId,
            'id_token': account.idToken,
            'challenge_id': challengeId,
            'challenge': challenge,
            'signature': signature,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      // 服务器可能因 id_token 过期要求重新授权
      if (response.statusCode == 401) {
        await AccountService.clear();
        throw const AuthNotAuthorizedException();
      }
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

  /// 向服务器请求一次性挑战随机数，返回 {challenge_id, challenge}。
  static Future<Map<String, String>> _fetchChallenge(String deviceId) async {
    final url = _challengeApiUrl;
    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'device_id': deviceId}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('获取挑战失败：HTTP ${response.statusCode} ${response.body}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final challenge = data['challenge'] as String?;
    final challengeId = data['challenge_id'] as String?;
    if (challenge == null ||
        challenge.isEmpty ||
        challengeId == null ||
        challengeId.isEmpty) {
      throw Exception('服务器未返回有效的挑战');
    }
    return {'challenge_id': challengeId, 'challenge': challenge};
  }

  /// 清除已存储的令牌（如用户重置时调用）。
  static Future<void> clear() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _tokenExpiryKey);
  }
}

/// 表示用户尚未完成轻授权，需要引导到 [LightAuthPage]。
class AuthNotAuthorizedException implements Exception {
  const AuthNotAuthorizedException();
}
