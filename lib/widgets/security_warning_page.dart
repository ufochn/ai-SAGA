import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/security_service.dart';

/// 设备安全警告页：检测到设备疑似被 root / 越狱时显示。
///
/// 英文提示，并提供 "Exit"（退出）按钮；用户确认后关闭 App。
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
                  'Security Warning',
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
                  'This device appears to be rooted or jailbroken. '
                  'Rooted or jailbroken devices may compromise your data and '
                  'app security. Please check your device and close this app.',
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
                const CupertinoButton.filled(
                  onPressed: SecurityService.exitApp,
                  child: Text('Exit'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
