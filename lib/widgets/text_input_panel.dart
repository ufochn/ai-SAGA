import 'package:flutter/material.dart';

/// 输入框和确定输入按钮组件
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

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: 8,
        horizontal: MediaQuery.of(context).size.width * 0.025,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 输入框（支持多行自动换行，占据剩余空间）
          Expanded(
            child: TextField(
              controller: _textController,
              maxLines: 5,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '输入文字...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          // 确定输入按钮（在输入框右侧）
          SizedBox(
            width: 100,
            child: ElevatedButton(
              onPressed: hasText
                  ? () {
                      widget.onConfirm(_textController.text);
                      _textController.clear();
                      setState(() {});
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                '确定输入',
                style: TextStyle(
                  fontSize: 16,
                  color: hasText ? null : Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
