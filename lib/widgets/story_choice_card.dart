import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/text_width.dart';

/// 历史段落下方的"时间树"选择卡片（iOS 风格）
///
/// 每个已生成的历史正文段落下方固定显示三个输入框（选择一/选择二/选择三），
/// 每个输入框下方各带一个按钮。历史段落的按钮文字为"从这里重新开始"，
/// 该按钮是"时间树"功能的入口：点击后把本段三个输入框当前值（用户可能已编辑）
/// 连同本段绝对下标一起回传给上层，由上层覆盖保存到服务器对应段，并从此处重写续写。
/// 打字期间按钮变灰不可点击。
class StoryChoiceCard extends StatefulWidget {
  /// 本地化后的按钮文字（历史段落："从这里重新开始"）
  final String buttonText;

  /// 本地化后的输入框占位文字
  final String inputPlaceholder;

  /// 各输入框的占位提示（长度 3，与正文底部三个输入框一致）；
  /// 缺省或某项为空时回退到 [inputPlaceholder]
  final List<String>? placeholders;

  /// 打字期间为 false（按钮变灰不可点击）；打字结束后为 true（可点击）
  final bool enabled;

  /// 本卡片所属的文本段绝对下标（= 服务器 seq），用于"时间树/从这里重写"
  /// 在代码与数据库中定位到正确的段落（按钮 ↔ 文本 ↔ 数据库行的对应）。
  final int segmentIndex;

  /// 重写按钮回调：携带本卡片所属的段下标 + 被点击输入框的文本 +
  /// 本段三个输入框的当前值（用户可能已编辑，需覆盖保存到服务器该段）。
  final void Function(int segmentIndex, String text, List<String> choices)?
  onPressed;

  /// 本段对应的三个选项内容（choice_1/2/3，与正文一起从服务器拉取），
  /// 预填到三个输入框显示；缺省/不足 3 个时对应框留空。
  final List<String>? initialValues;

  /// 加权字数上限（汉字/日文/韩文按 3 字，英文按 1 字），与正文底部输入框一致
  final int maxLength;

  const StoryChoiceCard({
    super.key,
    required this.segmentIndex,
    required this.buttonText,
    required this.inputPlaceholder,
    required this.enabled,
    this.placeholders,
    this.onPressed,
    this.initialValues,
    this.maxLength = 300,
  });

  @override
  State<StoryChoiceCard> createState() => _StoryChoiceCardState();
}

class _StoryChoiceCardState extends State<StoryChoiceCard> {
  /// 三个输入框的控制器（由本卡片持有，按钮点击时能取到整段三个值）
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    final init = widget.initialValues ?? const <String>[];
    _controllers = [
      for (int i = 0; i < 3; i++)
        TextEditingController(text: (i < init.length ? init[i] : null) ?? ''),
    ];
  }

  @override
  void didUpdateWidget(covariant StoryChoiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 服务器拉取的选项变化（如重写后重新同步）时同步刷新输入框
    if (oldWidget.initialValues != widget.initialValues) {
      final init = widget.initialValues ?? const <String>[];
      for (int i = 0; i < 3; i++) {
        final v = (i < init.length ? init[i] : null) ?? '';
        if (_controllers[i].text != v) _controllers[i].text = v;
      }
    }
  }

  List<String> get _currentChoices => [
    for (final c in _controllers) c.text.trim(),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < 3; i++) ...[
            _StoryChoiceInputRow(
              controller: _controllers[i],
              placeholder:
                  (widget.placeholders != null &&
                      i < widget.placeholders!.length &&
                      widget.placeholders![i].trim().isNotEmpty)
                  ? widget.placeholders![i]
                  : widget.inputPlaceholder,
              buttonText: widget.buttonText,
              enabled: widget.enabled,
              onPressed: () => widget.onPressed?.call(
                widget.segmentIndex,
                _controllers[i].text.trim(),
                _currentChoices,
              ),
              maxLength: widget.maxLength,
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
  final TextEditingController controller;
  final int maxLength;

  const _StoryChoiceInputRow({
    required this.placeholder,
    required this.buttonText,
    required this.enabled,
    required this.controller,
    this.onPressed,
    this.maxLength = 300,
  });

  @override
  State<_StoryChoiceInputRow> createState() => _StoryChoiceInputRowState();
}

class _StoryChoiceInputRowState extends State<_StoryChoiceInputRow> {
  /// 是否超过加权字数上限（与 TextInputPanel 一致：汉字/日文/韩文按 3 字，
  /// 英文按 1 字；超限不截断输入，仅文字变红、按钮置灰禁用）
  bool get _isOverLimit =>
      weightedCharCount(widget.controller.text) > widget.maxLength;

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final overLimit = _isOverLimit;
    // 输入框为空白时不渲染时间树"从这里重新开始"按钮为可点击：
    // 避免在无用户指引的情况下仅凭时间树生成新小说内容
    final hasText = widget.controller.text.trim().isNotEmpty;
    final canPress =
        widget.enabled && !overLimit && hasText && widget.onPressed != null;
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
            controller: widget.controller,
            // 生成/打字阶段（enabled=false）置灰不可输入，但输入框保持显示（不消失）
            enabled: widget.enabled,
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
        // 时间树"从这里重新开始"按钮（按钮位于输入框下方；超限或打字期间按钮变灰不可点击）
        // 灰化（禁用）期间整体降低透明度：保留蓝色按钮外形与圆角，辨识度不减，
        // 又明显区别于上方灰底带边框的输入框；可点击时全透明度显示
        Opacity(
          opacity: canPress ? 1.0 : 0.4,
          child: SizedBox(
            height: 44,
            child: CupertinoButton.filled(
              onPressed: canPress
                  ? () {
                      SoundService.playClick();
                      widget.onPressed!();
                    }
                  : null,
              borderRadius: BorderRadius.circular(10),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: isDark
                  ? AppTheme.buttonFillDark
                  : AppTheme.buttonFillLight,
              // 禁用时也使用蓝色填充，靠外层 Opacity 整体变淡（避免变成灰底、与输入框混淆）
              disabledColor: isDark
                  ? AppTheme.buttonFillDark
                  : AppTheme.buttonFillLight,
              child: Text(
                widget.buttonText,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.buttonText,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
