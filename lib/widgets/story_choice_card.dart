import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 历史段落下方的"时间树"选择卡片（iOS 风格）
///
/// 每个已生成的历史正文段落下方固定显示三个输入框（选择一/选择二/选择三），
/// 每个输入框下方各带一个按钮。历史段落的按钮文字为"从这里重新开始"，
/// 该按钮是"时间树"功能的占位：点击暂不跳转；打字期间按钮变灰不可点击。
class StoryChoiceCard extends StatelessWidget {
  /// 本地化后的按钮文字（历史段落："从这里重新开始"）
  final String buttonText;

  /// 本地化后的输入框占位文字
  final String inputPlaceholder;

  /// 打字期间为 false（按钮变灰不可点击）；打字结束后为 true（可点击）
  final bool enabled;

  /// 占位回调（时间树功能，未来实现）
  final VoidCallback? onPressed;

  const StoryChoiceCard({
    super.key,
    required this.buttonText,
    required this.inputPlaceholder,
    required this.enabled,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < 3; i++) ...[
            _StoryChoiceInputRow(
              placeholder: inputPlaceholder,
              buttonText: buttonText,
              enabled: enabled,
              onPressed: onPressed,
            ),
            if (i < 2) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// 卡片中的一行：输入框 + 下方全宽按钮
class _StoryChoiceInputRow extends StatefulWidget {
  final String placeholder;
  final String buttonText;
  final bool enabled;
  final VoidCallback? onPressed;

  const _StoryChoiceInputRow({
    required this.placeholder,
    required this.buttonText,
    required this.enabled,
    this.onPressed,
  });

  @override
  State<_StoryChoiceInputRow> createState() => _StoryChoiceInputRowState();
}

class _StoryChoiceInputRowState extends State<_StoryChoiceInputRow> {
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 输入框（iOS风格，与 TextInputPanel 一致）
        Container(
          decoration: BoxDecoration(
            color: isDark
                ? AppTheme.fieldBackgroundDark
                : AppTheme.fieldBackgroundLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isDark
                  ? AppTheme.inputBorderDark
                  : AppTheme.inputBorderLight,
              width: 1.0,
            ),
          ),
          child: CupertinoTextField(
            controller: _textController,
            maxLines: 5,
            minLines: 1,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            placeholder: widget.placeholder,
            placeholderStyle: TextStyle(
              color: isDark
                  ? AppTheme.tertiaryTextDark
                  : AppTheme.tertiaryTextLight,
            ),
            padding: const EdgeInsets.all(12),
            decoration: null,
            style: TextStyle(
              fontSize: 17,
              color: isDark
                  ? AppTheme.primaryTextDark
                  : AppTheme.primaryTextLight,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 时间树占位按钮（按钮位于输入框下方）
        SizedBox(
          height: 44,
          child: CupertinoButton.filled(
            onPressed: widget.enabled
                ? () {
                    SoundService.playClick();
                    widget.onPressed?.call();
                  }
                : null,
            borderRadius: BorderRadius.circular(10),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: isDark ? AppTheme.buttonFillDark : AppTheme.buttonFillLight,
            disabledColor: isDark
                ? const Color(0xFF2C2C2E)
                : const Color(0xFFF2F2F7),
            child: Text(
              widget.buttonText,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: widget.enabled
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
    );
  }
}
