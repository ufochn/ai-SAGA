import 'package:flutter/widgets.dart';

/// 优雅重启：通过更换整棵 Widget 树的 Key 强制重建，
/// 重新走一遍启动流程（启动页 → 同步门禁 → 重新激活本设备并拉取最新数据）。
///
/// 不杀进程、不调用 exit(0)，对 App Store 审核更友好。
class RestartWidget extends StatefulWidget {
  final Widget child;
  const RestartWidget({super.key, required this.child});

  /// 从任意子组件触发整棵 App 优雅重启。
  static void restartApp(BuildContext context) {
    context
        .findAncestorStateOfType<_RestartWidgetState>()
        ?.restart();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  Key _key = UniqueKey();

  void restart() {
    setState(() {
      _key = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}
