import 'package:flutter/material.dart';

/// 页面中的通用按钮组件
class PositionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const PositionButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: 8,
        horizontal: MediaQuery.of(context).size.width * 0.025,
      ),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onPressed,
          child: Text(label, style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
  }
}
