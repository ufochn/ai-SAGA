import 'dart:io';

/// IO 平台（Android / iOS / 桌面）：立即终止进程，
/// 实现“检测到 root/越狱后直接结束运行”的真正硬退出。
void terminateProcess() {
  exit(0);
}
