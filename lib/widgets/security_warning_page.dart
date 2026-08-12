import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/security_service.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 设备安全警告页：检测到设备疑似被 root / 越狱时显示。
///
/// 文案随客户选择的语言显示（未选择语言时回退系统语言），
/// 并提供"退出"按钮；用户确认后关闭 App。
class DeviceSecurityWarningPage extends StatelessWidget {
  const DeviceSecurityWarningPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  CupertinoIcons.exclamationmark_triangle_fill,
                  size: 64,
                  color: CupertinoColors.systemRed,
                ),
                const SizedBox(height: 20),
                Text(
                  _getSecurityTitleText(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? AppTheme.primaryTextDark
                        : AppTheme.primaryTextLight,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _getSecurityMessageText(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.5,
                    color: isDark
                        ? AppTheme.secondaryTextDark
                        : AppTheme.secondaryTextLight,
                  ),
                ),
                const SizedBox(height: 28),
                CupertinoButton.filled(
                  onPressed: SecurityService.exitApp,
                  child: Text(_getSecurityExitText()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "安全警告"标题（本地化）
  String _getSecurityTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '安全警告';
      case 'en':
        return 'Security Warning';
      case 'es':
        return 'Advertencia de seguridad';
      case 'fr':
        return 'Avertissement de sécurité';
      case 'de':
        return 'Sicherheitswarnung';
      case 'pt':
        return 'Aviso de segurança';
      case 'ja':
        return 'セキュリティ警告';
      case 'ko':
        return '보안 경고';
      default:
        return '安全警告';
    }
  }

  /// 安全警告内容（本地化）
  String _getSecurityMessageText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '此裝置疑似已被 root 或越獄。root 或越獄的裝置可能危及您的資料與 App 安全，請檢查您的裝置並關閉本 App。';
      case 'yue':
        return '呢部裝置疑似已被 root 或越獄。root 或越獄嘅裝置可能危及你嘅資料同 App 安全，請檢查你嘅裝置並關閉呢個 App。';
      case 'en':
        return 'This device appears to be rooted or jailbroken. Rooted or jailbroken devices may compromise your data and app security. Please check your device and close this app.';
      case 'es':
        return 'Este dispositivo parece estar rooteado o con jailbreak. Los dispositivos rooteados o con jailbreak pueden comprometer sus datos y la seguridad de la app. Revise su dispositivo y cierre esta app.';
      case 'fr':
        return 'Cet appareil semble être rooté ou jailbreaké. Les appareils rootés ou jailbreakés peuvent compromettre vos données et la sécurité de l\'app. Vérifiez votre appareil et fermez cette app.';
      case 'de':
        return 'Dieses Gerät scheint gerootet oder jailbroken zu sein. Gerootete oder jailbroken Geräte können Ihre Daten und die App-Sicherheit gefährden. Bitte prüfen Sie Ihr Gerät und schließen Sie diese App.';
      case 'pt':
        return 'Este dispositivo parece estar com root ou jailbreak. Dispositivos com root ou jailbreak podem comprometer seus dados e a segurança do app. Verifique seu dispositivo e feche este app.';
      case 'ja':
        return 'この端末は root 化または脱獄されているようです。root 化・脱獄された端末はデータやアプリの安全性を損なう可能性があります。端末を確認して、このアプリを閉じてください。';
      case 'ko':
        return '이 기기가 루팅되었거나 탈옥된 것으로 보입니다. 루팅 또는 탈옥된 기기는 데이터와 앱 보안을 위협할 수 있습니다. 기기를 확인하고 이 앱을 종료하세요.';
      default:
        return '此设备疑似已被 root 或越狱。root 或越狱的设备可能危及您的数据与 App 安全，请检查您的设备并关闭本 App。';
    }
  }

  /// "退出"按钮文字（本地化）
  String _getSecurityExitText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '退出';
      case 'en':
        return 'Exit';
      case 'es':
        return 'Salir';
      case 'fr':
        return 'Quitter';
      case 'de':
        return 'Beenden';
      case 'pt':
        return 'Sair';
      case 'ja':
        return '終了';
      case 'ko':
        return '종료';
      default:
        return '退出';
    }
  }
}
