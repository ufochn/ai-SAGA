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
      throw Exception(StorageService.localizedText(
        zhCN: '服务器注册地址未配置：请检查 .env 中的 REGISTER_API_URL',
        zhTW: '伺服器註冊位址未配置：請檢查 .env 中的 REGISTER_API_URL',
        en: 'Server registration URL is not configured. Please check REGISTER_API_URL in your .env file.',
        yue: '伺服器註冊位址未配置：請檢查 .env 入面嘅 REGISTER_API_URL',
        es: 'La URL de registro del servidor no está configurada. Compruebe REGISTER_API_URL en su archivo .env.',
        fr: "L'URL d'enregistrement du serveur n'est pas configurée. Vérifiez REGISTER_API_URL dans votre fichier .env.",
        de: 'Die Server-Registrierungs-URL ist nicht konfiguriert. Bitte prüfen Sie REGISTER_API_URL in Ihrer .env-Datei.',
        pt: 'A URL de registro do servidor não está configurada. Verifique REGISTER_API_URL no seu arquivo .env.',
        ja: 'サーバー登録URLが設定されていません。.envファイルのREGISTER_API_URLを確認してください。',
        ko: '서버 등록 URL이 구성되지 않았습니다. .env 파일에서 REGISTER_API_URL을 확인하세요.',
      ));
    }

    // 1) 轻授权账号（若未授权则抛错，由上层引导到 LightAuthPage）
    final account = await AccountService.getCachedAccount();
    if (account == null) {
      throw const AuthNotAuthorizedException();
    }

    // 2) 设备标识（稳定、持久）
    final deviceId = StorageService.getUserUniqueId();
    if (deviceId.isEmpty) {
      throw Exception(StorageService.localizedText(
        zhCN: '设备唯一 ID 缺失，无法注册',
        zhTW: '裝置唯一 ID 缺失，無法註冊',
        en: 'Device unique ID is missing. Unable to register.',
        yue: '裝置唯一 ID 缺失，無法註冊',
        es: 'Falta el ID único del dispositivo. No se puede registrar.',
        fr: 'L\'identifiant unique de l\'appareil est manquant. Impossible de s\'enregistrer.',
        de: 'Eindeutige Geräte-ID fehlt. Registrierung nicht möglich.',
        pt: 'Falta o ID exclusivo do dispositivo. Não é possível registrar.',
        ja: 'デバイスの一意なIDがありません。登録できません。',
        ko: '기기 고유 ID가 없습니다. 등록할 수 없습니다.',
      ));
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
      // 服务器可能因 id_token 过期要求重新授权。
      // 开发模式（DEV_MODE=true）：不清理账号、不回弹授权页，直接展示服务端
      // 错误，避免"授权-重试-401"死循环（服务器需配合 DEV_MODE=1 才能接受注册）。
      if (response.statusCode == 401 && !AccountService.isDevMode) {
        await AccountService.clear();
        throw const AuthNotAuthorizedException();
      }
      // 同硬件 24h 内切换账号过多（服务器 409 hardware_account_limit）：
      // 抛出专用异常，由上层弹出英文警告并直接退出 App。
      if (response.statusCode == 409 &&
          response.body.contains('hardware_account_limit')) {
        throw const HardwareAccountLimitException();
      }
      throw Exception(
        '${StorageService.localizedText(
          zhCN: '设备注册失败',
          zhTW: '裝置註冊失敗',
          en: 'Device registration failed',
          yue: '裝置註冊失敗',
          es: 'Error al registrar el dispositivo',
          fr: 'Échec de l\'enregistrement de l\'appareil',
          de: 'Geräteregistrierung fehlgeschlagen',
          pt: 'Falha no registro do dispositivo',
          ja: 'デバイスの登録に失敗しました',
          ko: '기기 등록에 실패했습니다',
        )}: HTTP ${response.statusCode} ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    final expiresAt = (data['expires_at'] as num?)?.toInt();
    if (token == null || token.isEmpty || expiresAt == null) {
      throw Exception(StorageService.localizedText(
        zhCN: '服务器返回的令牌无效',
        zhTW: '伺服器回傳的令牌無效',
        en: 'The token returned by the server is invalid.',
        yue: '伺服器回傳嘅令牌無效',
        es: 'El token devuelto por el servidor no es válido.',
        fr: 'Le jeton renvoyé par le serveur est invalide.',
        de: 'Das vom Server zurückgegebene Token ist ungültig.',
        pt: 'O token retornado pelo servidor é inválido.',
        ja: 'サーバーが返したトークンが無効です。',
        ko: '서버가 반환한 토큰이 유효하지 않습니다.',
      ));
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
      throw Exception(
        '${StorageService.localizedText(
          zhCN: '获取挑战失败',
          zhTW: '取得挑戰失敗',
          en: 'Failed to obtain challenge',
          yue: '取得挑戰失敗',
          es: 'Error al obtener el desafío',
          fr: 'Échec de l\'obtention du défi',
          de: 'Fehler beim Abrufen der Challenge',
          pt: 'Falha ao obter o desafio',
          ja: 'チャレンジの取得に失敗しました',
          ko: '챌린지를 가져오지 못했습니다',
        )}: HTTP ${response.statusCode} ${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final challenge = data['challenge'] as String?;
    final challengeId = data['challenge_id'] as String?;
    if (challenge == null ||
        challenge.isEmpty ||
        challengeId == null ||
        challengeId.isEmpty) {
      throw Exception(StorageService.localizedText(
        zhCN: '服务器未返回有效的挑战',
        zhTW: '伺服器未回傳有效的挑戰',
        en: 'The server did not return a valid challenge.',
        yue: '伺服器未回傳有效嘅挑戰',
        es: 'El servidor no devolvió un desafío válido.',
        fr: 'Le serveur n\'a pas renvoyé de défi valide.',
        de: 'Der Server hat keine gültige Challenge zurückgegeben.',
        pt: 'O servidor não retornou um desafio válido.',
        ja: 'サーバーが有効なチャレンジを返しませんでした。',
        ko: '서버가 유효한 챌린지를 반환하지 않았습니다.',
      ));
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

/// 表示同硬件 24 小时内切换账号过多，服务器拒绝本次注册（409 hardware_account_limit）。
/// 触发时 App 应弹出英文警告并直接退出，防止继续换账号刷试用/配额。
class HardwareAccountLimitException implements Exception {
  const HardwareAccountLimitException();
}
