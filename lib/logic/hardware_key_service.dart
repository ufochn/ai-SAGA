import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webcrypto/webcrypto.dart';

/// 安全硬件密钥服务（Android Keystore / iOS Secure Enclave）。
///
/// 私钥始终保存在系统安全硬件中，永不导出到 Dart 层；
/// 本服务只暴露两个能力：
///  - [getPublicKey]：获取/生成设备公钥（Base64 编码的 SPKI/原始公钥）
///  - [sign]：用设备私钥对给定 UTF-8 文本做签名，返回 Base64 签名
///
/// Web 平台说明：浏览器没有可用的原生安全硬件通道（MethodChannel 无实现），
/// 因此 Web 走「演示放行 + WebCrypto 软件密钥」的降级路径，仅用于受控调试/演示。
/// 软件密钥同样是**真实 ECDSA P-256**（可被服务器校验通过），但私钥以 JWK
/// 存于浏览器 localStorage，不提供硬件级安全保证；
/// iOS / Android / macOS 不受影响，仍走原生安全硬件。
class HardwareKeyService {
  HardwareKeyService._();

  static const MethodChannel _channel = MethodChannel('ai_saga/hardware_key');

  /// Web 演示令牌：URL 查询参数名（?demo_token=xxx）
  static const String _webTokenParam = 'demo_token';

  /// Web 演示令牌：.env 环境变量名
  static const String _webTokenEnvKey = 'WEB_DEMO_CODE';

  /// Web 软件密钥 JWK 的本地存储 key（shared_preferences / localStorage）
  static const String _webJwkKey = 'ai_saga_web_ecdsa_jwk';

  static String? _presentedWebToken;
  static bool _webTokenChecked = false;
  static EcdsaPrivateKey? _webKey;
  static EcdsaPublicKey? _webPubKey;

  /// 是否为本地开发环境（VS Code 启动 Chrome 时的 localhost）。
  static bool get _isLocalDev {
    final host = Uri.base.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '0.0.0.0' ||
        host == '::1' ||
        host == '[::1]';
  }

  /// 校验 Web 演示令牌（仅 Web 生效；移动/桌面不受影响）。
  ///
  /// - 本地（VS Code 启动的 localhost）→ 直接放行，无需令牌；
  /// - 非本地访问：未配置 [WEB_DEMO_CODE] 时放行；配置后必须
  ///   通过 `?demo_token=<值>` 传入，否则抛错提示。
  static void _ensureWebAllowed() {
    if (!kIsWeb) return;
    if (_isLocalDev) return; // 本地调试 → 直接授权运行
    if (!_webTokenChecked) {
      _webTokenChecked = true;
      _presentedWebToken = Uri.base.queryParameters[_webTokenParam];
    }
    final expected = dotenv.env[_webTokenEnvKey] ?? '';
    if (expected.isEmpty) return; // 未配置令牌 → 放行
    if (_presentedWebToken == expected) return;
    throw Exception(
      'Web 演示未授权：非本地访问需在链接后追加 '
      '?demo_token=<WEB_DEMO_CODE 的值>',
    );
  }

  /// 获取（存在则复用）Web 软件 ECDSA P-256 密钥对。
  ///
  /// 私钥以 JWK 持久化在 shared_preferences（localStorage），保证同一浏览器
  /// 下公钥稳定，与原生"设备公钥稳定"的语义一致。
  static Future<(EcdsaPrivateKey, EcdsaPublicKey)> _webGetOrCreateKeyPair() async {
    if (_webKey != null && _webPubKey != null) {
      return (_webKey!, _webPubKey!);
    }
    final prefs = await SharedPreferences.getInstance();
    final savedJwk = prefs.getString(_webJwkKey);
    if (savedJwk != null && savedJwk.isNotEmpty) {
      try {
        final jwk = jsonDecode(savedJwk) as Map<String, dynamic>;
        _webKey =
            await EcdsaPrivateKey.importJsonWebKey(jwk, EllipticCurve.p256);
        // 公钥 JWK 去除私钥字段 d 后导入（与原生 SPKI 公钥等价）
        final pubJwk = Map<String, dynamic>.from(jwk)..remove('d');
        _webPubKey =
            await EcdsaPublicKey.importJsonWebKey(pubJwk, EllipticCurve.p256);
        return (_webKey!, _webPubKey!);
      } catch (_) {
        // JWK 损坏时重新生成
      }
    }
    final pair = await EcdsaPrivateKey.generateKey(EllipticCurve.p256);
    _webKey = pair.privateKey;
    _webPubKey = pair.publicKey;
    final jwk = await _webKey!.exportJsonWebKey();
    await prefs.setString(_webJwkKey, jsonEncode(jwk));
    return (_webKey!, _webPubKey!);
  }

  /// ASN.1 DER 编码一个 INTEGER（用于构造 X9.62 ECDSA 签名）。
  static List<int> _derInteger(List<int> bytes) {
    var i = 0;
    while (i < bytes.length - 1 && bytes[i] == 0) {
      i++;
    }
    var value = bytes.sublist(i);
    if (value[0] & 0x80 != 0) {
      value = [0, ...value];
    }
    return [0x02, value.length, ...value];
  }

  /// 将 WebCrypto 的 raw R||S 签名编码为 X9.62 DER（与原生输出一致）。
  static List<int> _rawSigToDer(List<int> raw) {
    final half = raw.length ~/ 2;
    final content = [
      ..._derInteger(raw.sublist(0, half)),
      ..._derInteger(raw.sublist(half)),
    ];
    return [0x30, content.length, ...content];
  }

  /// 获取（不存在则生成）设备硬件密钥对，返回 Base64 公钥（SPKI DER）。
  ///
  /// 同一台设备的同一应用，公钥保持稳定；清除应用数据可能导致系统
  /// 安全硬件中的密钥被删除（Android Keystore 与应用数据绑定）。
  static Future<String> getPublicKey() async {
    if (kIsWeb) {
      _ensureWebAllowed();
      final (_, publicKey) = await _webGetOrCreateKeyPair();
      final spki = await publicKey.exportSpkiKey();
      return base64Encode(spki);
    }
    final publicKey = await _channel.invokeMethod<String>('getPublicKey');
    if (publicKey == null || publicKey.isEmpty) {
      throw Exception('无法读取安全硬件公钥');
    }
    return publicKey;
  }

  /// 用安全硬件私钥对 [data]（UTF-8 文本）签名，返回 Base64（X9.62 DER）。
  static Future<String> sign(String data) async {
    if (kIsWeb) {
      _ensureWebAllowed();
      final (privateKey, _) = await _webGetOrCreateKeyPair();
      final rawSig = await privateKey.signBytes(utf8.encode(data), Hash.sha256);
      return base64Encode(_rawSigToDer(rawSig));
    }
    final dataB64 = base64Encode(utf8.encode(data));
    final signature = await _channel.invokeMethod<String>('sign', {
      'data': dataB64,
    });
    if (signature == null || signature.isEmpty) {
      throw Exception('安全硬件签名失败');
    }
    return signature;
  }

  /// 查询本机是否已生成硬件密钥。
  static Future<bool> hasKey() async {
    if (kIsWeb) {
      _ensureWebAllowed();
      return (await SharedPreferences.getInstance())
              .getString(_webJwkKey)?.isNotEmpty ??
          false;
    }
    final result = await _channel.invokeMethod<bool>('hasKey');
    return result ?? false;
  }
}
