import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 输入框和确定输入按钮组件（iOS风格）
class TextInputPanel extends StatefulWidget {
  final void Function(String text) onConfirm;

  const TextInputPanel({super.key, required this.onConfirm});

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

  @override
  Widget build(BuildContext context) {
    final bool hasText = _textController.text.isNotEmpty;
    final isDark = AppTheme.isDark(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 输入框（iOS风格）
          Expanded(
            child: Container(
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
                placeholder: '输入文字...',
                placeholderStyle: TextStyle(
                  color: isDark
                      ? AppTheme.tertiaryTextDark
                      : AppTheme.tertiaryTextLight,
                ),
                padding: const EdgeInsets.all(12),
                decoration: null,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.primaryTextDark
                      : AppTheme.primaryTextLight,
                  fontSize: 17,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 确定输入按钮
          SizedBox(
            width: 80,
            height: 44,
            child: CupertinoButton.filled(
              onPressed: hasText
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
                '确定',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: hasText
                      ? AppTheme.buttonText
                      : (isDark
                            ? AppTheme.buttonDisabledTextDark
                            : AppTheme.buttonDisabledTextLight),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
