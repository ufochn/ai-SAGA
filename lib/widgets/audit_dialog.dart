import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/widgets/account_limit_warning.dart';
import 'package:ai_saga/widgets/app_restart.dart';
import 'package:ai_saga/widgets/light_auth_page.dart';

/// 审核弹窗 - 调取服务器审核器（AWS Guard）进行审核。
/// 等待期间显示"正在审核输入，请稍后"；收到结果后：
/// - 若服务器返回有效判定且 action == none（通过）→ 自动调用 onApproved 进入下一步；
/// - 若 action != none（不通过）→ 以当前语言弹出警告，提示设置可能包含敏感信息需修改；
/// - 若拿不到服务器的有效判定（网络异常 / 超时 / 响应无效）→ 以当前语言提示检查网络后重试。
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
        final msg = _extractErrorMessage(response);
        if (msg == 'device_conflict') {
          // 多设备同时登入：弹出警告并重启本 App
          _handleDeviceConflict();
          return;
        }
        setState(() {
          _loading = false;
          _errorMessage = msg;
        });
        return;
      }

      final action = _parseAction(response.body);
      if (action == null) {
        // 服务器没有返回有效的审核判定（非 JSON / 非对象 / 无 action 字段）：
        // 一律按"未取得判定结果"处理，以当前语言提示检查网络后重试
        if (!mounted) return;
        setState(() {
          _loading = false;
          _errorMessage = getNetworkErrorMessage();
        });
        return;
      }
      if (action == 'none') {
        // 审核通过（action == none）：不显示任何提示，直接关闭弹窗并进入下一步
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onApproved();
      } else {
        // 审核未通过（action != none）：以当前语言弹出警告，提示用户修改
        setState(() {
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // 同硬件 24h 内切换账号过多：弹出英文警告，用户确认后退出 App
      if (e is HardwareAccountLimitException) {
        setState(() {
          _loading = false;
        });
        await showAccountLimitWarning(context);
        return;
      }
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
      // 网络异常 / 超时 / 服务端不可达等一切拿不到判定结果的错误：
      // 以当前语言提示用户检查网络连接后重试
      setState(() {
        _loading = false;
        _errorMessage = getNetworkErrorMessage();
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

  /// 从服务器返回的判定 JSON 中严格读取 action 字段。
  ///
  /// 只认真正的 action 字段，且值忽略大小写与首尾空白后等于 "none" 才算通过；
  /// 若响应不是合法 JSON、不是对象、或找不到 action 字段，返回 null
  /// （调用方按"未取得判定结果"处理，fail-closed）。
  String? _parseAction(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      String? action;
      decoded.forEach((key, value) {
        if (key is String && key.trim().toLowerCase() == 'action') {
          if (value is String) action = value;
        }
      });
      return action?.trim().toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// 服务器判定本机已不是活跃设备（检测到多设备同时登入）：
  /// 弹出警告，用户同意后重启本 App。
  Future<void> _handleDeviceConflict() async {
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        title: Text(getDeviceConflictTitle()),
        content: Text(getDeviceConflictMessage()),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(getDeviceConflictConfirm()),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // 用户同意：优雅重启本 App（重建整棵树 → 重新走同步门禁 → 重新登记活跃设备）
    RestartWidget.restartApp(context);
  }

  /// "多设备同时登入"警告标题（本地化）
  String getDeviceConflictTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '偵測到多裝置同時登入';
      case 'en':
        return 'Multiple Devices Detected';
      case 'es':
        return 'Se detectaron varios dispositivos';
      case 'fr':
        return 'Plusieurs appareils détectés';
      case 'de':
        return 'Mehrere Geräte erkannt';
      case 'pt':
        return 'Vários dispositivos detectados';
      case 'ja':
        return '複数のデバイスを検出しました';
      case 'ko':
        return '여러 기기가 감지되었습니다';
      default:
        return '检测到多设备同时登入';
    }
  }

  /// "多设备同时登入"警告内容（本地化）
  String getDeviceConflictMessage() {
    switch (_language) {
      case 'zh-TW':
        return '您似乎有兩個以上的裝置在同時登入本 App。為保持小說同步，本 App 需要重新啟動。';
      case 'yue':
        return '你似乎有兩個以上嘅裝置同時登入呢個 App。為咗保持小說同步，呢個 App 需要重新啟動。';
      case 'en':
        return 'It looks like this App is signed in on more than one device at the same time. To keep your story in sync, this App needs to restart.';
      case 'es':
        return 'Parece que esta App inició sesión en más de un dispositivo al mismo tiempo. Para mantener sincronizada tu historia, esta App debe reiniciarse.';
      case 'fr':
        return 'Il semble que cette app soit connectée sur plus d\'un appareil en même temps. Pour garder votre histoire synchronisée, cette app doit redémarrer.';
      case 'de':
        return 'Diese App scheint gleichzeitig auf mehr als einem Gerät angemeldet zu sein. Um Ihre Geschichte synchron zu halten, muss diese App neu gestartet werden.';
      case 'pt':
        return 'Parece que este app está conectado em mais de um dispositivo ao mesmo tempo. Para manter sua história sincronizada, este app precisa ser reiniciado.';
      case 'ja':
        return 'このアプリが複数のデバイスで同時にログインしているようです。小説の同期を保つため、このアプリを再起動する必要があります。';
      case 'ko':
        return '이 앱이 여러 기기에서 동시에 로그인된 것 같습니다. 이야기 동기화를 유지하려면 이 앱을 다시 시작해야 합니다.';
      default:
        return '您似乎有两个以上的设备在同时登入本 App。为保持小说同步，本 App 需要重新启动。';
    }
  }

  /// "多设备同时登入"警告确认按钮文字（本地化）
  String getDeviceConflictConfirm() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '同意';
      case 'en':
        return 'OK';
      case 'es':
        return 'OK';
      case 'fr':
        return 'OK';
      case 'de':
        return 'OK';
      case 'pt':
        return 'OK';
      case 'ja':
        return 'OK';
      case 'ko':
        return '확인';
      default:
        return '同意';
    }
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

  // 拿不到服务器判定结果时（网络异常 / 超时 / 服务端不可达 / 响应无效）的提示文字
  String getNetworkErrorMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '網路連線似乎出現問題，請檢查您的網路連線後再試。';
      case 'en':
        return 'It seems your network connection is having issues. Please check your connection and try again.';
      case 'es':
        return 'Parece que hay un problema con su conexión de red. Compruebe su conexión e inténtelo de nuevo.';
      case 'fr':
        return 'Votre connexion réseau semble avoir un problème. Veuillez vérifier votre connexion et réessayer.';
      case 'de':
        return 'Es scheint ein Problem mit Ihrer Netzwerkverbindung zu geben. Bitte überprüfen Sie Ihre Verbindung und versuchen Sie es erneut.';
      case 'pt':
        return 'Parece que há um problema com sua conexão de rede. Verifique sua conexão e tente novamente.';
      case 'ja':
        return 'ネットワーク接続に問題があるようです。接続を確認して、もう一度お試しください。';
      case 'ko':
        return '네트워크 연결에 문제가 있는 것 같습니다. 연결을 확인한 후 다시 시도해 주세요.';
      default:
        return '网络连接似乎出现问题，请检查您的网络连接后重试。';
    }
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
        return '審核未通過';
      case 'en':
        return 'Audit Not Passed';
      case 'es':
        return 'Auditoría No Superada';
      case 'fr':
        return 'Audit Non Réussi';
      case 'de':
        return 'Prüfung Nicht Bestanden';
      case 'pt':
        return 'Auditoria Não Aprovada';
      case 'ja':
        return '審査未通過';
      case 'ko':
        return '심사 통과 실패';
      default:
        return '审核未通过';
    }
  }

  // 审核未通过时的提示文字
  String getRejectedMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您的設定可能包含某些敏感資訊，請檢查後重新設定。抱歉。';
      case 'en':
        return 'Your settings may contain sensitive information. Please review and set them again. Sorry.';
      case 'es':
        return 'Sus configuraciones pueden contener información sensible. Por favor revíselas y vuelva a configurarlas. Lo sentimos.';
      case 'fr':
        return 'Vos paramètres peuvent contenir des informations sensibles. Veuillez les vérifier et les reconfigurer. Désolé.';
      case 'de':
        return 'Ihre Einstellungen könnten sensible Informationen enthalten. Bitte überprüfen Sie sie und stellen Sie sie erneut ein. Es tut uns leid.';
      case 'pt':
        return 'Suas configurações podem conter informações sensíveis. Por favor, verifique-as e redefina. Desculpe.';
      case 'ja':
        return '設定に機密情報が含まれている可能性があります。確認して再設定してください。申し訳ございません。';
      case 'ko':
        return '설정에 민감한 정보가 포함되어 있을 수 있습니다. 확인 후 다시 설정해 주세요. 죄송합니다.';
      default:
        return '您的设置可能包含某些敏感信息，请检查后重新设置。抱歉。';
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
      case 'es':
        return 'Cerrar';
      case 'fr':
        return 'Fermer';
      case 'de':
        return 'Schließen';
      case 'pt':
        return 'Fechar';
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
