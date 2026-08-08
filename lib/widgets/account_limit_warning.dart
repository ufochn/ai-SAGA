import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/security_service.dart';

/// 同硬件 24 小时内切换账号过多的英文警告弹窗。
///
/// 触发条件：服务器拒绝注册（409 hardware_account_limit）。根据产品要求，
/// 该警告固定使用英文（不随语言切换），并直接提供 "Exit App"（退出 App）
/// 按钮，防止继续更换账号刷试用/配额。
Future<void> showAccountLimitWarning(BuildContext context) {
  return showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => const CupertinoAlertDialog(
      title: const Text(
        'Too Many Account Switches',
        textAlign: TextAlign.center,
      ),
      content: const Text(
        'This device has switched between too many accounts in the last '
        '24 hours. For the security of your account, you cannot sign in '
        'again right now. Please try again in 24 hours.',
        textAlign: TextAlign.center,
      ),
      actions: [
        const CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: SecurityService.exitApp,
          child: const Text('Exit App'),
        ),
      ],
    ),
  );
}
