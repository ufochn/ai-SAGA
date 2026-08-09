import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/text_width.dart';

/// 输入框和确定输入按钮组件（iOS风格）。
///
/// 字数按"显示宽度"统计：汉字/日文/韩文等宽字符按 2 字计，英文字母/数字/
/// 标点按 1 字计；加权总字数超过 [maxLength]（默认 200）时，输入文字变红、
/// 确定按钮变灰禁用（不截断输入，与地名设置页一致）。
class TextInputPanel extends StatefulWidget {
  final void Function(String text) onConfirm;

  /// 输入内容变化回调：用于在确认前把当前输入值上报给外部（如记录本轮三个选择）
  final void Function(String text)? onChanged;

  /// 输入框占位文字（背景提示）
  final String placeholder;

  /// 确定按钮文字
  final String confirmText;

  /// 加权字数上限（汉字/日文/韩文按 2 字，英文按 1 字）
  final int maxLength;

  /// 按钮是否放在输入框下方（true=纵向：输入框在上、按钮在下全宽；
  /// false=横向：输入框在左、按钮在右，默认）
  final bool buttonBelow;

  /// 生成中置灰禁用确定按钮：保持按钮可见但不可点击
  final bool disabled;

  const TextInputPanel({
    super.key,
    required this.onConfirm,
    this.onChanged,
    this.placeholder = '输入文字...',
    this.confirmText = '确定',
    this.maxLength = 200,
    this.buttonBelow = false,
    this.disabled = false,
  });

  @override
  State<TextInputPanel> createState() => _TextInputPanelState();
}

class _TextInputPanelState extends State<TextInputPanel> {
  final TextEditingController _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  bool get _hasText => _textController.text.trim().isNotEmpty;
  bool get _isOverLimit =>
      weightedCharCount(_textController.text) > widget.maxLength;
  bool get _canConfirm => !_isOverLimit && _hasText;

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final overLimit = _isOverLimit;

    // 输入框（iOS风格）
    final Widget inputField = Container(
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
          color: overLimit
              ? (isDark
                    ? AppTheme.destructiveRedDark
                    : AppTheme.destructiveRedLight)
              : (isDark
                    ? AppTheme.primaryTextDark
                    : AppTheme.primaryTextLight),
          fontSize: 17,
        ),
        onChanged: (value) {
          setState(() {});
          widget.onChanged?.call(value);
        },
      ),
    );

    // 确定输入按钮（生成中/超限/为空时置灰禁用）
    final bool canConfirm = !widget.disabled && _canConfirm;
    final Widget confirmButton = SizedBox(
      height: 44,
      child: CupertinoButton.filled(
        onPressed: canConfirm
            ? () {
                SoundService.playConfirm();
                widget.onConfirm(_textController.text);
                _textController.clear();
                setState(() {});
              }
            : null,
        borderRadius: BorderRadius.circular(10),
        padding: EdgeInsets.zero,
        color: isDark
            ? AppTheme.buttonFillDark
            : AppTheme.buttonFillLight,
        disabledColor: isDark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFF2F2F7),
        child: Text(
          widget.confirmText,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: canConfirm
                ? AppTheme.buttonText
                : (isDark
                      ? AppTheme.buttonDisabledTextDark
                      : AppTheme.buttonDisabledTextLight),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: widget.buttonBelow
          // 纵向布局：输入框在上、按钮在下（全宽）
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                inputField,
                const SizedBox(height: 8),
                confirmButton,
              ],
            )
          // 横向布局：输入框在左、按钮在右（默认）
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: inputField),
                const SizedBox(width: 10),
                SizedBox(width: 80, child: confirmButton),
              ],
            ),
    );
  }
}
