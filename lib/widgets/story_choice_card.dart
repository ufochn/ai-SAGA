import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/text_width.dart';

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

  /// 本卡片所属的文本段绝对下标（= 服务器 seq），用于"时间树/从这里重写"
  /// 在代码与数据库中定位到正确的段落（按钮 ↔ 文本 ↔ 数据库行的对应）。
  final int segmentIndex;

  /// 重写按钮回调：携带本卡片所属的段下标 + 该段输入框当前文本
  /// （时间树"从这里重写"：用该文本作为从该段续写的用户输入）
  final void Function(int segmentIndex, String text)? onPressed;

  /// 本段对应的三个选项内容（choice_1/2/3，与正文一起从服务器拉取），
  /// 预填到三个输入框显示；缺省/不足 3 个时对应框留空。
  final List<String>? initialValues;

  /// 加权字数上限（汉字/日文/韩文按 2 字，英文按 1 字），与正文底部输入框一致
  final int maxLength;

  const StoryChoiceCard({
    super.key,
    required this.segmentIndex,
    required this.buttonText,
    required this.inputPlaceholder,
    required this.enabled,
    this.onPressed,
    this.initialValues,
    this.maxLength = 200,
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
              segmentIndex: segmentIndex,
              placeholder: inputPlaceholder,
              buttonText: buttonText,
              enabled: enabled,
              onPressed: onPressed,
              initialValue: (initialValues != null && i < initialValues!.length)
                  ? initialValues![i]
                  : '',
              maxLength: maxLength,
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
  final int segmentIndex;
  final String placeholder;
  final String buttonText;
  final bool enabled;
  final void Function(int segmentIndex, String text)? onPressed;
  final String initialValue;
  final int maxLength;

  const _StoryChoiceInputRow({
    required this.segmentIndex,
    required this.placeholder,
    required this.buttonText,
    required this.enabled,
    this.onPressed,
    this.initialValue = '',
    this.maxLength = 200,
  });

  @override
  State<_StoryChoiceInputRow> createState() => _StoryChoiceInputRowState();
}

class _StoryChoiceInputRowState extends State<_StoryChoiceInputRow> {
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 预填本段对应的选项内容（来自服务器拉取的 choice_1/2/3）
    _textController.text = widget.initialValue;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// 是否超过加权字数上限（与 TextInputPanel 一致：汉字/日文/韩文按 2 字，
  /// 英文按 1 字；超限不截断输入，仅文字变红、按钮置灰禁用）
  bool get _isOverLimit =>
      weightedCharCount(_textController.text) > widget.maxLength;

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final overLimit = _isOverLimit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 输入框（iOS风格，与 TextInputPanel 一致；超限时文字变红）
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
              color: overLimit
                  ? (isDark
                        ? AppTheme.destructiveRedDark
                        : AppTheme.destructiveRedLight)
                  : (isDark
                        ? AppTheme.primaryTextDark
                        : AppTheme.primaryTextLight),
            ),
            onChanged: (value) {
              setState(() {});
            },
          ),
        ),
        const SizedBox(height: 8),
        // 时间树占位按钮（按钮位于输入框下方；超限或打字期间按钮变灰不可点击）
        SizedBox(
          height: 44,
          child: CupertinoButton.filled(
            onPressed: widget.enabled && !overLimit
                ? () {
                    SoundService.playClick();
                    widget.onPressed?.call(
                      widget.segmentIndex,
                      _textController.text.trim(),
                    );
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
                color: widget.enabled && !overLimit
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
