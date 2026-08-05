import 'dart:convert';

import 'package:flutter/services.dart';

/// 安全硬件密钥服务（Android Keystore / iOS Secure Enclave）。
///
/// 私钥始终保存在系统安全硬件中，永不导出到 Dart 层；
/// 本服务只暴露两个能力：
///  - [getPublicKey]：获取/生成设备公钥（Base64 编码的 SPKI/原始公钥）
///  - [sign]：用设备私钥对给定 UTF-8 文本做签名，返回 Base64 签名
class HardwareKeyService {
  HardwareKeyService._();

  static const MethodChannel _channel = MethodChannel('ai_saga/hardware_key');

  /// 获取（不存在则生成）设备硬件密钥对，返回 Base64 公钥。
  ///
  /// 同一台设备的同一应用，公钥保持稳定；清除应用数据可能导致系统
  /// 安全硬件中的密钥被删除（Android Keystore 与应用数据绑定）。
  static Future<String> getPublicKey() async {
    final publicKey = await _channel.invokeMethod<String>('getPublicKey');
    if (publicKey == null || publicKey.isEmpty) {
      throw Exception('无法读取安全硬件公钥');
    }
    return publicKey;
  }

  /// 用安全硬件私钥对 [data]（UTF-8 文本）签名，返回 Base64 编码的签名。
  static Future<String> sign(String data) async {
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
    final result = await _channel.invokeMethod<bool>('hasKey');
    return result ?? false;
  }
}
