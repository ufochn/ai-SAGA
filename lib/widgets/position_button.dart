import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 页面中的通用按钮组件（iOS风格）
class PositionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const PositionButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: CupertinoButton.filled(
          onPressed: onPressed != null
              ? () {
                  SoundService.playClick();
                  onPressed!();
                }
              : null,
          borderRadius: BorderRadius.circular(12),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: isDark ? AppTheme.buttonFillDark : AppTheme.buttonFillLight,
          disabledColor: isDark
              ? const Color(0xFF2C2C2E)
              : const Color(0xFFF2F2F7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: onPressed != null
                  ? AppTheme.buttonText
                  : (isDark
                        ? AppTheme.buttonDisabledTextDark
                        : AppTheme.buttonDisabledTextLight),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
