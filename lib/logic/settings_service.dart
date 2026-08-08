import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/setup_draft.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 用户设定上传服务：把用户的地点/年代/主角等设定保存到服务器（服务器权威）。
///
/// 设定只在首次设定/修改设定（确认页）时上传一次；之后每次生成，服务器
/// 直接从自己的数据库读取设定与上一段，App 只上传用户最新输入。
class SettingsService {
  SettingsService._();

  /// 设定上传接口地址（来自 .env 的 SETTINGS_API_URL；
  /// 未配置时由 AUDIT_API_URL 推导，保证服务器地址一致）。
  static String get _settingsApiUrl {
    final direct = dotenv.env['SETTINGS_API_URL'] ?? '';
    if (direct.isNotEmpty) return direct;
    final audit = dotenv.env['AUDIT_API_URL'] ?? '';
    if (audit.contains('/api/audit-and-chat')) {
      return audit.replaceFirst('/api/audit-and-chat', '/api/settings');
    }
    return '';
  }

  /// 把当前设定草稿上传到服务器（失败抛异常，由上层处理/重试）。
  static Future<void> saveSettings() async {
    final url = _settingsApiUrl;
    if (url.isEmpty) {
      throw Exception('设定上传地址未配置：请检查 .env 中的 SETTINGS_API_URL');
    }
    final token = await AuthService.ensureToken();
    final resp = await http
        .post(
          Uri.parse(url),
          headers: {
            'accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'location': SetupDraft.instance.location,
            'era': SetupDraft.instance.era,
            'player_name': SetupDraft.instance.playerName,
            'player_gender': SetupDraft.instance.playerGender,
            'partner_name': SetupDraft.instance.partnerName,
            'partner_gender': SetupDraft.instance.partnerGender,
            'partner_traits': SetupDraft.instance.partnerTraits,
            'language': StorageService.getLanguage(),
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('设定上传失败：HTTP ${resp.statusCode} ${resp.body}');
    }
  }
}
