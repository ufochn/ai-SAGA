import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/widgets/light_auth_page.dart';

/// 审核弹窗 - 调取服务器审核器（AWS Guard）进行审核。
/// 等待期间显示"正在审核输入，请稍后"；收到结果后：
/// - 若为 Action: NONE（通过）→ 自动调用 onApproved 进入下一步；
/// - 若不为 Action: NONE（不通过）→ 以当前语言弹出警告，提示内容可能不合适需修改。
class AuditDialog extends StatefulWidget {
  final String text;
  final VoidCallback onApproved;

  const AuditDialog({super.key, required this.text, required this.onApproved});

  @override
  State<AuditDialog> createState() => _AuditDialogState();
}

class _AuditDialogState extends State<AuditDialog> {
  /// 审核服务器地址（读取自 .env 环境变量）
  String get _auditApiUrl => dotenv.env['AUDIT_API_URL'] ?? '';

  bool _loading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _callAuditServer();
  }

  /// 调用审核服务器，等待审核结果
  Future<void> _callAuditServer() async {
    try {
      // 环境变量缺失时给出明确提示，避免用空配置发起请求
      if (_auditApiUrl.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _errorMessage = getConfigMissingMessage();
        });
        return;
      }

      // 获取服务器签发的审核令牌（未注册或已过期时自动注册），
      // 令牌保存在系统安全存储中，不再在 App 内保存任何共享密钥
      final token = await AuthService.ensureToken();

      final response = await http
          .post(
            Uri.parse(_auditApiUrl),
            headers: {
              'accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'user_id': StorageService.getUserUniqueId(),
              'text': widget.text,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      // 请求级失败（非 2xx）：限流/鉴权/服务端错误，展示错误而不是"内容违规"
      if (response.statusCode < 200 || response.statusCode >= 300) {
        setState(() {
          _loading = false;
          _errorMessage = _extractErrorMessage(response);
        });
        return;
      }

      if (_isApproved(response.body)) {
        // 审核通过：不显示任何提示，直接关闭弹窗并进入下一步
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onApproved();
      } else {
        // 审核未通过（非 action: NONE）：以当前语言弹出警告，提示用户修改
        setState(() {
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // 未授权：引导用户完成轻授权后重试本次审核
      if (e is AuthNotAuthorizedException) {
        final needRetry = await _promptLightAuth();
        if (!mounted) return;
        if (needRetry) {
          _callAuditServer();
          return;
        }
        setState(() {
          _loading = false;
          _errorMessage = getAuthRequiredMessage();
        });
        return;
      }
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  /// 弹出轻授权页，返回用户是否完成授权。
  Future<bool> _promptLightAuth() async {
    final needRetry = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => const LightAuthPage(
          onComplete: _dummyComplete,
          popOnComplete: true,
        ),
      ),
    );
    return needRetry ?? false;
  }

  /// 占位回调（LightAuthPage 授权完成后由 push 返回值触发重试）。
  static void _dummyComplete() {}

  /// 判断审核结果是否通过。
  ///
  /// 服务器返回的是一段字符串文本（如 "Action: NONE\nProcessed Output: ..."），
  /// 只判断文本中是否包含 Action: NONE（忽略大小写与空格差异），不做 JSON 解析。
  bool _isApproved(String body) {
    return RegExp(r'action\s*[:=]\s*none', caseSensitive: false)
        .hasMatch(body);
  }

  /// 从非 2xx 响应中提取可读的错误信息（兼容 {message}/{error}/{detail} 与纯文本）
  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        for (final key in ['message', 'error', 'detail', 'msg']) {
          final v = decoded[key];
          if (v is String && v.isNotEmpty) return v;
          if (v is Map &&
              v['message'] is String &&
              (v['message'] as String).isNotEmpty) {
            return v['message'] as String;
          }
        }
      }
    } catch (_) {}
    final text = response.body.trim();
    return text.isEmpty ? 'HTTP ${response.statusCode}' : text;
  }

  String get _language => StorageService.getLanguage();

  // 等待时的标题文字
  String getWaitingTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請稍後';
      case 'en':
        return 'Please Wait';
      case 'es':
        return 'Espere';
      case 'fr':
        return 'Veuillez Patienter';
      case 'de':
        return 'Bitte Warten';
      case 'pt':
        return 'Aguarde';
      case 'ja':
        return '少々お待ちください';
      case 'ko':
        return '잠시 기다려 주세요';
      default:
        return '请稍后';
    }
  }

  // 审核失败时的标题文字
  String getErrorTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '審核失敗';
      case 'en':
        return 'Audit Failed';
      case 'es':
        return 'Error de Auditoría';
      case 'fr':
        return 'Échec de l\'Audit';
      case 'de':
        return 'Prüfung fehlgeschlagen';
      case 'pt':
        return 'Falha na Auditoria';
      case 'ja':
        return '審査に失敗しました';
      case 'ko':
        return '심사 실패';
      default:
        return '审核失败';
    }
  }

  // 环境变量缺失时的提示文字
  String getConfigMissingMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '伺服器設定缺失，請在 .env 中設定 AUDIT_API_URL 與 REGISTER_API_URL。';
      case 'en':
        return 'Server configuration is missing. Please set AUDIT_API_URL and REGISTER_API_URL in the .env file.';
      case 'es':
        return 'Falta la configuración del servidor. Configure AUDIT_API_URL y REGISTER_API_URL en el archivo .env.';
      case 'fr':
        return 'La configuration du serveur est manquante. Définissez AUDIT_API_URL et REGISTER_API_URL dans le fichier .env.';
      case 'de':
        return 'Serverkonfiguration fehlt. Bitte setzen Sie AUDIT_API_URL und REGISTER_API_URL in der .env-Datei.';
      case 'pt':
        return 'Falta a configuração do servidor. Defina AUDIT_API_URL e REGISTER_API_URL no arquivo .env.';
      case 'ja':
        return 'サーバー設定がありません。.env ファイルで AUDIT_API_URL と REGISTER_API_URL を設定してください。';
      case 'ko':
        return '서버 설정이 없습니다. .env 파일에서 AUDIT_API_URL과 REGISTER_API_URL을 설정해 주세요.';
      default:
        return '服务器配置缺失，请在 .env 中设置 AUDIT_API_URL 与 REGISTER_API_URL。';
    }
  }

  // 需要轻授权时的提示文字
  String getAuthRequiredMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請先完成帳號授權後再繼續';
      case 'en':
        return 'Please authorize your account to continue';
      case 'es':
        return 'Autorice su cuenta para continuar';
      case 'fr':
        return 'Autorisez votre compte pour continuer';
      case 'de':
        return 'Bitte autorisieren Sie Ihr Konto, um fortzufahren';
      case 'pt':
        return 'Autorize sua conta para continuar';
      case 'ja':
        return 'アカウントを承認して続行してください';
      case 'ko':
        return '계속하려면 계정을 승인하세요';
      default:
        return '请先完成账号授权后再继续';
    }
  }

  // 审核未通过时的标题文字
  String getRejectedTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您的用戶名似乎需要修改';
      case 'en':
        return 'Your username seems to need changes';
      case 'es':
        return 'Su nombre de usuario parece necesitar cambios';
      case 'fr':
        return 'Votre nom d\'utilisateur semble devoir être modifié';
      case 'de':
        return 'Ihr Benutzername scheint geändert werden zu müssen';
      case 'pt':
        return 'Seu nome de usuário parece precisar de alterações';
      case 'ja':
        return 'ユーザー名の修正が必要なようです';
      case 'ko':
        return '사용자 이름을 수정해야 할 것 같습니다';
      default:
        return '您的用户名似乎需要修改';
    }
  }

  // 审核未通过时的提示文字
  String getRejectedMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請重新輸入';
      case 'en':
        return 'Please enter it again.';
      case 'es':
        return 'Por favor, vuelva a introducirlo.';
      case 'fr':
        return 'Veuillez le saisir à nouveau.';
      case 'de':
        return 'Bitte erneut eingeben.';
      case 'pt':
        return 'Por favor, digite novamente.';
      case 'ja':
        return 'もう一度入力してください。';
      case 'ko':
        return '다시 입력해 주세요.';
      default:
        return '请重新输入';
    }
  }

  // 关闭按钮文字
  String getCloseText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '關閉';
      case 'en':
        return 'Close';
      case 'ja':
        return '閉じる';
      case 'ko':
        return '닫기';
      default:
        return '关闭';
    }
  }

  // "知道了"按钮文字
  String getGotItText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '知道了';
      case 'en':
        return 'OK';
      case 'es':
        return 'Aceptar';
      case 'fr':
        return 'OK';
      case 'de':
        return 'OK';
      case 'pt':
        return 'OK';
      case 'ja':
        return '了解';
      case 'ko':
        return '확인';
      default:
        return '知道了';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);

    final title = _loading
        ? getWaitingTitle()
        : (_errorMessage != null ? getErrorTitle() : getRejectedTitle());

    // 等待中无按钮
    final actions = _loading
        ? const <Widget>[]
        : <Widget>[
            CupertinoDialogAction(
              child: Text(
                _errorMessage != null ? getCloseText() : getGotItText(),
                style: TextStyle(
                  color: isDark
                      ? AppTheme.accentBlueDark
                      : AppTheme.accentBlueLight,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ];

    return CupertinoAlertDialog(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: isDark ? AppTheme.primaryTextDark : AppTheme.primaryTextLight,
        ),
      ),
      content: _buildContent(isDark),
      actions: actions,
    );
  }

  /// 根据审核状态构建弹窗内容
  Widget _buildContent(bool isDark) {
    // 等待审核结果中：仅显示动态图标
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: CupertinoActivityIndicator(radius: 14),
      );
    }

    // 审核失败
    if (_errorMessage != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          SelectableText(
            _errorMessage!,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark
                  ? AppTheme.secondaryTextDark
                  : AppTheme.secondaryTextLight,
            ),
          ),
        ],
      );
    }

    // 审核未通过（Action 非 NONE）：以当前语言弹出警告
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        const Icon(
          CupertinoIcons.exclamationmark_triangle_fill,
          color: Color(0xFFFF9F0A),
          size: 44,
        ),
        const SizedBox(height: 10),
        Text(
          getRejectedMessage(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: isDark
                ? AppTheme.secondaryTextDark
                : AppTheme.secondaryTextLight,
          ),
        ),
      ],
    );
  }
}
