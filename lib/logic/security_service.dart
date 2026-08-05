import 'package:flutter_jailbreak_detection/flutter_jailbreak_detection.dart';

// 平台相关的“硬退出”实现：
//  - Android/iOS/桌面：terminate_io.dart 使用 exit(0) 直接结束进程
//  - Web：terminate_stub.dart 仅编译占位（Web 无 root/越狱概念）
import 'security_terminate_stub.dart'
    if (dart.library.io) 'security_terminate_io.dart';

/// 设备完整性防护。
///
/// 只允许在未 root / 未越狱的移动设备上运行本应用：
/// 启动时进行硬件/系统完整性检测，一旦发现设备已被 root 或越狱，
/// 立即静默终止进程，不显示任何提示，以防止攻击者借用已提权设备
/// 绕过审核、盗用后端 LLM 能力。
class SecurityService {
  SecurityService._();

  /// 检查设备完整性；若设备已被 root / 越狱则直接退出进程（无任何提示）。
  ///
  /// 该检测必须在 [WidgetsFlutterBinding.ensureInitialized] 之后调用，
  /// 因为底层依赖原生平台通道。检测异常（例如在无 root 概念的桌面/Web
  /// 平台）时按“未越狱”处理，避免误杀正常用户；在目标平台
  /// Android / iOS 上该检测可靠有效。
  static Future<void> ensureNonRootedDevice() async {
    bool compromised = false;
    try {
      compromised = await FlutterJailbreakDetection.jailbroken;
    } catch (_) {
      // 检测不可用时按未越狱处理，保证正常用户不受影响。
      compromised = false;
    }

    if (compromised) {
      // 静默退出进程，不向用户展示任何提示。
      terminateProcess();
    }
  }
}
