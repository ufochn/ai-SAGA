import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:ai_saga/logic/storage_service.dart';

/// 开发模式开关（来自 .env 的 DEV_MODE=true）。
bool get _devMode => dotenv.env['DEV_MODE'] == 'true';

/// 轻授权账号信息。
class AccountInfo {
  final String provider; // 'google' | 'apple'
  final String userId; // 平台稳定的 sub（由服务器最终以 ID Token 校验为准）
  final String idToken; // 用于服务器 JWKS 校验的签名令牌

  const AccountInfo({
    required this.provider,
    required this.userId,
    required this.idToken,
  });

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'user_id': userId,
    'id_token': idToken,
  };
}

/// 轻授权服务。
///
/// 首次使用要求用户"轻授权"（点一个按钮）：
///  - Android：Google 登录，拿 id_token
///  - iOS：Sign in with Apple，拿 identityToken
///
/// 之后会话信息存入安全存储，无需重复授权；用户无感。
/// 注意：真正的身份以服务器 JWKS 校验 id_token 为准，客户端 userId 仅作展示。
class AccountService {
  AccountService._();

  static const String _providerKey = 'account_provider';
  static const String _userIdKey = 'account_user_id';
  static const String _idTokenKey = 'account_id_token';

  /// 是否当前平台是移动端（Android/iOS）。
  static bool get isMobilePlatform {
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false; // Web 等平台无此概念
    }
  }

  /// 是否为开发模式（.env 的 DEV_MODE=true）。
  ///
  /// 开发模式下：账号由设备 ID 确定性派生、不弹真实 OAuth；
  /// 服务器注册被 401 拒绝时也不再回弹授权页，而是直接展示错误，避免死循环。
  static bool get isDevMode => _devMode;

  /// Google 登录 client id（来自 .env，Android 用 web client id）。
  static String get _googleWebClientId => dotenv.env['GOOGLE_CLIENT_ID'] ?? '';

  /// 开发模式下的确定性测试账号（由设备唯一 ID 派生，不依赖安全存储）。
  ///
  /// 本地 DEV_MODE 联调时，账号不需要写入 Keychain：macOS 无开发者签名时
  /// flutter_secure_storage 的写入会"看似成功实则未写入"，导致账号读回为
  /// null、反复弹出轻授权页。这里直接按设备 ID 派生，保证始终可用。
  static AccountInfo _devAccount() {
    final devUserId = StorageService.getUserUniqueId();
    return AccountInfo(
      provider: 'dev',
      userId: devUserId,
      idToken: devUserId, // 服务器 DEV_MODE 下以此字段作为 user_id
    );
  }

  /// 读取已保存的账号（不发起网络请求）。
  static Future<AccountInfo?> getCachedAccount() async {
    // 开发模式：直接返回确定性测试账号，不再依赖 Keychain 持久化。
    if (_devMode) {
      return _devAccount();
    }
    final provider = await StorageService.getSecure(_providerKey);
    final userId = await StorageService.getSecure(_userIdKey);
    final idToken = await StorageService.getSecure(_idTokenKey);
    if (provider == null || userId == null || idToken == null) {
      return null;
    }
    return AccountInfo(provider: provider, userId: userId, idToken: idToken);
  }

  /// 是否已授权（有缓存的账号）。
  static Future<bool> isAuthorized() async => await getCachedAccount() != null;

  /// 执行轻授权（弹出系统登录面板）。
  ///
  /// 成功后缓存会话并返回 [AccountInfo]。失败抛异常由调用方处理。
  static Future<AccountInfo> authorize() async {
    // 开发模式：不接真实 Apple/Google OAuth，用设备唯一 ID 作为测试账号，
    // 便于本地联调整条链路（注册→硬件签名→令牌→试用→同步）。
    if (_devMode) {
      final info = _devAccount();
      await _cacheAccount(info); // 尽力缓存；Keychain 写失败也不影响后续读取
      return info;
    }

    if (Platform.isIOS) {
      return _authorizeWithApple();
    }
    if (Platform.isAndroid) {
      return _authorizeWithGoogle();
    }
    // 其他平台（如 Web）：按 Android 逻辑尝试，失败时明确报错。
    try {
      return await _authorizeWithGoogle();
    } catch (_) {
      throw Exception('当前平台不支持轻授权，请使用 Android 或 iOS 设备');
    }
  }

  /// Google 登录（Android）。
  static Future<AccountInfo> _authorizeWithGoogle() async {
    final GoogleSignIn googleSignIn = GoogleSignIn(
      clientId: _googleWebClientId.isEmpty ? null : _googleWebClientId,
    );
    final GoogleSignInAccount? account = await googleSignIn.signIn();
    if (account == null) {
      throw Exception('用户取消了 Google 授权');
    }
    final GoogleSignInAuthentication auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw Exception('Google 授权未返回 ID Token');
    }
    final info = AccountInfo(
      provider: 'google',
      userId: account.id,
      idToken: idToken,
    );
    await _cacheAccount(info);
    return info;
  }

  /// Sign in with Apple（iOS）。
  static Future<AccountInfo> _authorizeWithApple() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      webAuthenticationOptions: WebAuthenticationOptions(
        clientId: dotenv.env['APPLE_SERVICE_ID'] ?? '',
        redirectUri: Uri.parse(dotenv.env['APPLE_REDIRECT_URI'] ?? ''),
      ),
    );
    if (credential.identityToken == null) {
      throw Exception('Apple 授权未返回 Identity Token');
    }
    // Apple 的 sub 需要从 identityToken（JWT）中解码 payload 获取，
    // 服务端最终以 JWKS 校验为准。
    final userId = _decodeAppleSub(credential.identityToken!) ?? 'apple-user';
    final info = AccountInfo(
      provider: 'apple',
      userId: userId,
      idToken: credential.identityToken!,
    );
    await _cacheAccount(info);
    return info;
  }

  /// 从 Apple identityToken（JWT）payload 中解出 sub。
  static String? _decodeAppleSub(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final map = jsonDecode(payload) as Map<String, dynamic>;
      return map['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 清除本地会话（如切换账号时）。
  static Future<void> clear() async {
    await StorageService.deleteSecure(_providerKey);
    await StorageService.deleteSecure(_userIdKey);
    await StorageService.deleteSecure(_idTokenKey);
  }

  static Future<void> _cacheAccount(AccountInfo info) async {
    await StorageService.saveSecure(_providerKey, info.provider);
    await StorageService.saveSecure(_userIdKey, info.userId);
    await StorageService.saveSecure(_idTokenKey, info.idToken);
  }
}
