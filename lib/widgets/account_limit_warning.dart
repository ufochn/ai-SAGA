import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/security_service.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 同硬件 24 小时内切换账号过多的警告弹窗。
///
/// 触发条件：服务器拒绝注册（409 hardware_account_limit）。
/// 直接提供"退出 App"按钮，防止继续更换账号刷试用/配额。
/// 文案随客户选择的语言显示（未选择语言时回退系统语言）。
Future<void> showAccountLimitWarning(BuildContext context) {
  return showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(
        _getAccountLimitTitleText(),
        textAlign: TextAlign.center,
      ),
      content: Text(
        _getAccountLimitMessageText(),
        textAlign: TextAlign.center,
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: SecurityService.exitApp,
          child: Text(_getAccountLimitExitText()),
        ),
      ],
    ),
  );
}

/// "切换账号次数过多"警告标题（本地化）
String _getAccountLimitTitleText() {
  switch (StorageService.getLanguage()) {
    case 'zh-TW':
    case 'yue':
      return '切換帳號次數過多';
    case 'en':
      return 'Too Many Account Switches';
    case 'es':
      return 'Demasiados cambios de cuenta';
    case 'fr':
      return 'Trop de changements de compte';
    case 'de':
      return 'Zu viele Kontowechsel';
    case 'pt':
      return 'Muitas trocas de conta';
    case 'ja':
      return 'アカウントの切り替えが多すぎます';
    case 'ko':
      return '계정 전환 횟수가 너무 많습니다';
    default:
      return '切换账号次数过多';
  }
}

/// "切换账号次数过多"警告内容（本地化）
String _getAccountLimitMessageText() {
  switch (StorageService.getLanguage()) {
    case 'zh-TW':
      return '此裝置在過去 24 小時內切換了過多帳號。為了您帳號的安全，目前無法再次登入。請於 24 小時後再試。';
    case 'yue':
      return '呢部裝置喺過去 24 小時內切換咗太多帳號。為咗你帳號嘅安全，而家暫時唔可以再登入。請 24 小時後再試。';
    case 'en':
      return 'This device has switched between too many accounts in the last 24 hours. For the security of your account, you cannot sign in again right now. Please try again in 24 hours.';
    case 'es':
      return 'Este dispositivo ha cambiado entre demasiadas cuentas en las últimas 24 horas. Por la seguridad de tu cuenta, no puedes iniciar sesión de nuevo en este momento. Vuelve a intentarlo en 24 horas.';
    case 'fr':
      return 'Cet appareil est passé entre trop de comptes au cours des dernières 24 heures. Pour la sécurité de votre compte, vous ne pouvez pas vous reconnecter pour le moment. Réessayez dans 24 heures.';
    case 'de':
      return 'Dieses Gerät hat in den letzten 24 Stunden zwischen zu vielen Konten gewechselt. Aus Sicherheitsgründen können Sie sich derzeit nicht erneut anmelden. Bitte versuchen Sie es in 24 Stunden erneut.';
    case 'pt':
      return 'Este dispositivo alternou entre muitas contas nas últimas 24 horas. Para a segurança da sua conta, você não pode entrar novamente agora. Tente novamente em 24 horas.';
    case 'ja':
      return 'この端末は過去 24 時間にあまりにも多くのアカウントを切り替えました。アカウントの安全のため、現在は再ログインできません。24 時間後にもう一度お試しください。';
    case 'ko':
      return '이 기기는 지난 24시간 동안 너무 많은 계정을 전환했습니다. 계정 보안을 위해 지금은 다시 로그인할 수 없습니다. 24시간 후에 다시 시도해 주세요.';
    default:
      return '此设备在过去 24 小时内切换了过多账号。为了您账号的安全，目前无法再次登入。请于 24 小时后重试。';
  }
}

/// "退出 App"按钮文字（本地化）
String _getAccountLimitExitText() {
  switch (StorageService.getLanguage()) {
    case 'zh-TW':
    case 'yue':
      return '退出 App';
    case 'en':
      return 'Exit App';
    case 'es':
      return 'Salir de la app';
    case 'fr':
      return 'Quitter l\'app';
    case 'de':
      return 'App beenden';
    case 'pt':
      return 'Sair do app';
    case 'ja':
      return 'アプリを終了';
    case 'ko':
      return '앱 종료';
    default:
      return '退出 App';
  }
}
