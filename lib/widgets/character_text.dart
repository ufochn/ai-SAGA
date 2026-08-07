import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';

/// 字符文本显示组件（iOS风格）
class CharacterText extends StatelessWidget {
  final String text;

  const CharacterText({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.cardBackgroundDark
              : AppTheme.cardBackgroundLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 17,
            color: isDark
                ? AppTheme.primaryTextDark
                : AppTheme.primaryTextLight,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// 打字机文本显示组件：随时间逐步揭示 [text]，并随打字进度持续加速。
///
/// - 外部通过重建并传入更长的 [text]（如流式 chunk 追加）来继续打字；
/// - 从第一个字即以最慢速度 [charsPerTick]（默认 1 字/拍）输出；
/// - 之后每隔 [speedUpEvery]（默认 20）字提速最小一档（+1 字/拍），
///   形成「不断加速」的感觉；
/// - [segmentStart] 为本段内容在 [text] 中的起始下标：速度按「段落内进度」
///   计算（`_visibleLen - segmentStart`），因此每次续写（新段落）都会
///   从最慢重新开始加速；
/// - [revealAll] 为 true 时仍可立即显示全部（备用，主流程不再使用）；
/// - [abortReason] 非空时停止并隐藏正文，仅显示中止提示。
class TypewriterText extends StatefulWidget {
  final String text;
  final int charsPerTick;
  final Duration tickInterval;
  final int speedUpEvery;
  final int segmentStart;
  final bool revealAll;
  final String? abortReason;
  final VoidCallback? onTypingDone;

  const TypewriterText({
    super.key,
    required this.text,
    this.charsPerTick = 1,
    this.tickInterval = const Duration(milliseconds: 150),
    this.speedUpEvery = 20,
    this.segmentStart = 0,
    this.revealAll = false,
    this.abortReason,
    this.onTypingDone,
  });

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  int _visibleLen = 0;
  Timer? _timer;
  bool _doneFired = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TypewriterText old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    // 中止：停表，隐藏正文
    if (widget.abortReason != null) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    // 一次性显示全部（reveal 事件）：跳到末尾
    if (widget.revealAll && _visibleLen < widget.text.length) {
      _timer?.cancel();
      _timer = null;
      setState(() => _visibleLen = widget.text.length);
      _fireDone();
      return;
    }
    // 文本变长：继续打字（若已到末尾则重启）
    if (_visibleLen < widget.text.length && _timer == null) {
      _start();
    }
  }

  void _start() {
    _timer = Timer.periodic(widget.tickInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _visibleLen =
            min(_visibleLen + _currentCharsPerTick(), widget.text.length);
      });
      if (_visibleLen >= widget.text.length) {
        timer.cancel();
        _timer = null;
        _fireDone();
      }
    });
  }

  /// 随打字进度动态提速：
  /// - 从第一个字即以最慢速度 [charsPerTick]（1 字/拍）输出；
  /// - 之后每隔 [speedUpEvery]（20）字提速最小一档（+1 字/拍），
  ///   营造不断加速的感觉；
  /// - 进度以「段落内进度」（`_visibleLen - segmentStart`）计算，
  ///   保证每次续写新段落都从最慢重新加速。
  int _currentCharsPerTick() {
    final inSegment = max(0, _visibleLen - widget.segmentStart);
    return widget.charsPerTick + (inSegment ~/ widget.speedUpEvery);
  }

  void _fireDone() {
    if (!_doneFired && widget.onTypingDone != null) {
      _doneFired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onTypingDone?.call();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    if (widget.abortReason != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark
                ? AppTheme.cardBackgroundDark
                : AppTheme.cardBackgroundLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.abortReason!,
            style: const TextStyle(
              fontSize: 15,
              color: CupertinoColors.systemRed,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    final shown = widget.text.substring(0, min(_visibleLen, widget.text.length));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.cardBackgroundDark
              : AppTheme.cardBackgroundLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          shown,
          style: TextStyle(
            fontSize: 17,
            color: isDark
                ? AppTheme.primaryTextDark
                : AppTheme.primaryTextLight,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
