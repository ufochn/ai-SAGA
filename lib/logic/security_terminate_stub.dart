import 'package:flutter/services.dart';

/// Web 等非 IO 平台：不存在 root/越狱概念，此处仅作编译占位。
/// 若意外触发，SystemNavigator.pop() 在 Web 上是无操作，不会影响页面。
void terminateProcess() {
  SystemNavigator.pop();
}
