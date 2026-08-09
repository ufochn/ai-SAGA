import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';

/// 正文内的用户选择标记（iOS 风格）
///
/// 用户在输入框确认后，把选择内容以"用户选择：xxx"的格式显示在正文中，
/// 文字颜色与正文其他文字不同。"时间树"的返回按钮由每段下方的选择卡片
/// （StoryChoiceCard）承载，此处仅保留选择内容的文本标记。
class StoryChoiceMarker extends StatelessWidget {
  /// 本地化后的"用户选择："前缀
  final String prefix;

  /// 用户选择的内容
  final String text;

  const StoryChoiceMarker({
    super.key,
    required this.prefix,
    required this.text,
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
        ],
      ),
    );
  }
}
