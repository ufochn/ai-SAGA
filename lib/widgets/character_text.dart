import 'package:flutter/material.dart';

/// 字符文本显示组件
class CharacterText extends StatelessWidget {
  final String text;

  const CharacterText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: 1,
        horizontal: MediaQuery.of(context).size.width * 0.025,
      ),
      child: Text(text, style: const TextStyle(fontSize: 18)),
    );
  }
}
