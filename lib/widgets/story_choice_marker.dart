import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';

/// 正文内的用户选择节点（iOS风格）
///
/// 用户在输入框确认后，把选择内容以"用户选择：xxx"的格式显示在正文中，
/// 文字颜色与正文其他文字不同；下方放置一个"点击选择在此重续故事"按钮，
/// 该按钮是未来"时间树"返回功能的占位：打字期间按钮变灰不可点击，
/// 打字结束后恢复可点击。
class StoryChoiceMarker extends StatelessWidget {
  /// 本地化后的"用户选择："前缀
  final String prefix;

  /// 用户选择的内容
  final String text;

  /// 本地化后的按钮文字（点击选择在此重续故事）
  final String buttonText;

  /// 打字期间为 false（按钮变灰不可点击）；打字结束后为 true（可点击）
  final bool enabled;

  final VoidCallback? onPressed;

  const StoryChoiceMarker({
    super.key,
    required this.prefix,
    required this.text,
    required this.buttonText,
    required this.enabled,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 用户选择内容：颜色与正文其他文字不同
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: prefix),
                TextSpan(
                  text: text,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            style: TextStyle(
              fontSize: 16,
              height: 1.5,
              color: isDark
                  ? AppTheme.accentBlueDark
                  : AppTheme.accentBlueLight,
            ),
          ),
          const SizedBox(height: 6),
          // 时间树返回占位按钮
          SizedBox(
            height: 40,
            child: CupertinoButton.filled(
              onPressed: enabled ? onPressed : null,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              borderRadius: BorderRadius.circular(10),
              color: isDark
                  ? AppTheme.buttonFillDark
                  : AppTheme.buttonFillLight,
              disabledColor: isDark
                  ? const Color(0xFF2C2C2E)
                  : const Color(0xFFF2F2F7),
              child: Text(
                buttonText,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: enabled
                      ? AppTheme.buttonText
                      : (isDark
                            ? AppTheme.buttonDisabledTextDark
                            : AppTheme.buttonDisabledTextLight),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
