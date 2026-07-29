import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';

/// 字符文本显示组件（iOS风格）
class CharacterText extends StatelessWidget {
  final String text;

  const CharacterText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.cardBackgroundDark
              : AppTheme.cardBackgroundLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 17,
            color: isDark
                ? AppTheme.primaryTextDark
                : AppTheme.primaryTextLight,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
