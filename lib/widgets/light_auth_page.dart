import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/account_service.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/widgets/privacy_policy_page.dart';

/// 轻授权页面。
///
/// 首次启动时展示一个"开始使用"按钮，点击后触发平台登录
/// （Android = Google，iOS = Sign in with Apple），完成后回调。
/// 页面底部提供《隐私政策》链接，满足合规披露要求。
class LightAuthPage extends StatefulWidget {
  final VoidCallback onComplete;

  /// 是否在授权完成后以 pop(true) 的形式返回导航栈上一层。
  ///
  /// 默认 false：由 [onComplete] 负责后续页面切换（如进入主界面）。
  /// 审核弹窗等以 push 方式弹出本页并期望拿回"是否已授权"结果的场景
  /// 应设为 true，授权成功后 pop(true) 让调用方继续重试。
  final bool popOnComplete;

  const LightAuthPage({
    super.key,
    required this.onComplete,
    this.popOnComplete = false,
  });

  @override
  State<LightAuthPage> createState() => _LightAuthPageState();
}

class _LightAuthPageState extends State<LightAuthPage> {
  bool _loading = false;
  String? _error;

  /// 当前用户选择的语言代码
  String get _language => StorageService.getLanguage();

  /// 按钮文案：使用平台账号继续
  String _getContinueText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '使用平台帳號繼續';
      case 'en':
        return 'Continue with Platform Account';
      case 'es':
        return 'Continuar con Cuenta de Plataforma';
      case 'fr':
        return 'Continuer avec un Compte de Plateforme';
      case 'de':
        return 'Mit Plattformkonto fortfahren';
      case 'pt':
        return 'Continuar com Conta da Plataforma';
      case 'ja':
        return 'プラットフォームアカウントで続ける';
      case 'ko':
        return '플랫폼 계정으로 계속하기';
      default:
        return '使用平台账号继续';
    }
  }

  /// 按钮文案：开始使用（非移动端）
  String _getStartText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '開始使用';
      case 'en':
        return 'Get Started';
      case 'es':
        return 'Comenzar';
      case 'fr':
        return 'Commencer';
      case 'de':
        return 'Loslegen';
      case 'pt':
        return 'Começar';
      case 'ja':
        return 'はじめる';
      case 'ko':
        return '시작하기';
      default:
        return '开始使用';
    }
  }

  /// 隐私政策链接前缀
  String _getPrivacyPrefix() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '繼續即表示你同意 ';
      case 'en':
        return 'By continuing, you agree to the ';
      case 'es':
        return 'Al continuar, aceptas la ';
      case 'fr':
        return 'En continuant, vous acceptez la ';
      case 'de':
        return 'Mit dem Fortfahren akzeptierst du die ';
      case 'pt':
        return 'Ao continuar, você concorda com a ';
      case 'ja':
        return '続行すると、次の内容に同意したものとみなされます：';
      case 'ko':
        return '계속하면 다음에 동의하게 됩니다: ';
      default:
        return '继续即表示你同意 ';
    }
  }

  /// 隐私政策名称（可点击部分）
  String _getPrivacyPolicyName() {
    switch (_language) {
      case 'yue':
        return '《私隱政策》';
      case 'zh-TW':
        return '《隱私政策》';
      case 'en':
        return 'Privacy Policy';
      case 'es':
        return 'Política de Privacidad';
      case 'fr':
        return 'Politique de confidentialité';
      case 'de':
        return 'Datenschutzrichtlinie';
      case 'pt':
        return 'Política de Privacidade';
      case 'ja':
        return 'プライバシーポリシー';
      case 'ko':
        return '개인정보 처리방침';
      default:
        return '《隐私政策》';
    }
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AccountService.authorize();
      if (!mounted) return;
      widget.onComplete();
      // 若调用方期望以 pop(true) 拿回授权结果（如审核弹窗引导授权），
      // 且导航栈中尚有可返回的页面，则 pop(true) 让调用方继续。
      if (widget.popOnComplete && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildStartButton(context),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _buildPrivacyLink(context),
                  ],
                ),
              ),
            ),
            // 左上角返回按钮：当本页是被 push 出来的（如从语言选择页进入）
            // 时显示，点击返回上一页（语言选择页）。
            if (Navigator.of(context).canPop())
              Positioned(
                top: 8,
                left: 8,
                child: CupertinoButton(
                  padding: const EdgeInsets.all(8),
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Icon(
                    CupertinoIcons.back,
                    size: 28,
                    color: isDark
                        ? AppTheme.accentBlueDark
                        : AppTheme.accentBlueLight,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStartButton(BuildContext context) {
    return CupertinoButton.filled(
      onPressed: _loading ? null : _start,
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
      child: _loading
          ? const CupertinoActivityIndicator(color: CupertinoColors.white)
          : Text(
              AccountService.isMobilePlatform
                  ? _getContinueText()
                  : _getStartText(),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
    );
  }

  /// 按钮下方的隐私政策链接（常见做法：继续即表示同意）。
  Widget _buildPrivacyLink(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return GestureDetector(
      onTap: _loading
          ? null
          : () => Navigator.of(context).push(
              CupertinoPageRoute(builder: (_) => const PrivacyPolicyPage()),
            ),
      child: RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          style: TextStyle(
            fontSize: 13,
            color: isDark
                ? AppTheme.secondaryTextDark
                : AppTheme.secondaryTextLight,
          ),
          children: [
            TextSpan(text: _getPrivacyPrefix()),
            TextSpan(
              text: _getPrivacyPolicyName(),
              style: TextStyle(
                color: isDark
                    ? AppTheme.accentBlueDark
                    : AppTheme.accentBlueLight,
                decoration: TextDecoration.underline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
