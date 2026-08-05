import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:ai_saga/logic/account_service.dart';
import 'package:ai_saga/logic/home_content.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/security_service.dart';
import 'package:ai_saga/widgets/light_auth_page.dart';
import 'package:ai_saga/widgets/initialization_page.dart';

/// 全局主题亮度通知器
final ValueNotifier<Brightness> themeBrightnessNotifier =
    ValueNotifier<Brightness>(
      StorageService.getIsDarkMode() ? Brightness.dark : Brightness.light,
    );

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 设备完整性防护：启动时检测硬件/系统完整性，
  // 若发现设备已被 root / 越狱，立即静默退出进程，不显示任何提示。
  await SecurityService.ensureNonRootedDevice();
  // 加载环境变量配置（.env 已加入 .gitignore，不随仓库上传；
  // 缺少时保持空配置，不影响应用启动）
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env 缺失时不阻塞启动，审核时会有明确提示
  }
  await StorageService.init();
  // 初始化时读取存储的夜间模式偏好
  themeBrightnessNotifier.value = StorageService.getIsDarkMode()
      ? Brightness.dark
      : Brightness.light;
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeBrightnessNotifier,
      builder: (context, _) {
        final isDark = themeBrightnessNotifier.value == Brightness.dark;
        return CupertinoApp(
          title: 'Hello World',
          debugShowCheckedModeBanner: false,
          theme: CupertinoThemeData(
            brightness: themeBrightnessNotifier.value,
            primaryColor: isDark
                ? AppTheme.accentBlueDark
                : AppTheme.accentBlueLight,
            scaffoldBackgroundColor: isDark
                ? AppTheme.pageBackgroundDark
                : AppTheme.pageBackgroundLight,
            textTheme: CupertinoTextThemeData(
              textStyle: TextStyle(
                fontFamily: '.SF Pro Display',
                fontSize: 17,
                color: isDark
                    ? AppTheme.primaryTextDark
                    : AppTheme.primaryTextLight,
              ),
              primaryColor: isDark
                  ? AppTheme.accentBlueDark
                  : AppTheme.accentBlueLight,
            ),
            barBackgroundColor: isDark
                ? AppTheme.pageBackgroundDark
                : AppTheme.pageBackgroundLight,
          ),
          home: const SplashScreen(),
        );
      },
    );
  }
}

/// 轻授权门卫：未授权时先进入轻授权页，完成后进入主界面。
class LightAuthGate extends StatelessWidget {
  const LightAuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return LightAuthPage(
      onComplete: () {
        // 授权完成后直接进入主界面，并清空导航栈（移除语言选择页等），
        // 避免主界面返回时回到设置流程。
        Navigator.of(context).pushAndRemoveUntil(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const MyHomePage(),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(
                    opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: const Cubic(0.22, 1.0, 0.36, 1.0),
                      ),
                    ),
                    child: child,
                  );
                },
            transitionDuration: const Duration(milliseconds: 1200),
          ),
          (route) => false,
        );
      },
    );
  }
}

/// 语言优先门卫：新用户先选择语言，完成后再进入轻授权页（开始你的故事）。
/// 使用 push 而非 pushReplacement，保留语言选择页在导航栈中，
/// 以便用户在轻授权页通过左上角返回按钮回到语言选择页。
class LanguageFirstGate extends StatelessWidget {
  const LanguageFirstGate({super.key});

  @override
  Widget build(BuildContext context) {
    return InitializationPage(
      onComplete: () {
        Navigator.of(context).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) =>
                const LightAuthGate(),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(
                    opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: const Cubic(0.22, 1.0, 0.36, 1.0),
                      ),
                    ),
                    child: child,
                  );
                },
            transitionDuration: const Duration(milliseconds: 1200),
          ),
        );
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeOutAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _fadeOutAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Cubic(0.22, 1.0, 0.36, 1.0), // Apple easeInOutCubic
      ),
    );

    // 2秒后开始封面淡出
    Future.delayed(const Duration(seconds: 2), () {
      _animationController.forward();
    });

    // 淡出动画结束后执行页面切换（与淡出重叠），同时播放恐怖音效
    Future.delayed(const Duration(milliseconds: 2600), () async {
      SoundService.playHorror();
      if (!mounted) return;
      // 新用户最先选择语言：尚未选择语言且未授权时，先进入语言选择页，
      // 完成后进入轻授权页（开始你的故事）；已选择语言或已授权则直接进入对应页面。
      final authorized = await AccountService.isAuthorized();
      final hasLanguage = StorageService.getLanguage().isNotEmpty;
      if (!mounted) return;
      final Widget nextPage;
      if (authorized) {
        nextPage = const MyHomePage();
      } else if (hasLanguage) {
        nextPage = const LightAuthGate();
      } else {
        nextPage = const LanguageFirstGate();
      }
      Navigator.of(context).pushReplacement(
        // Apple 风格的交叉溶解过渡（cross dissolve）
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => nextPage,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: const Cubic(0.22, 1.0, 0.36, 1.0),
                ),
              ),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 1200),
        ),
      );
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  /// 根据语言返回对应语言的标题
  String _getLocalizedTitle(String language) {
    switch (language) {
      case 'zh-TW':
      case 'yue':
        return 'AI 傳奇';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'AI SAGA';
      case 'ja':
        return 'AI サーガ';
      case 'ko':
        return 'AI 사가';
      default:
        return 'AI SAGA';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final language = StorageService.getLanguage();
    final hasLanguage = language.isNotEmpty;

    return FadeTransition(
      opacity: _fadeOutAnimation,
      child: CupertinoPageScaffold(
        backgroundColor: isDark
            ? AppTheme.pageBackgroundDark
            : AppTheme.pageBackgroundLight,
        child: Center(
          child: hasLanguage
              ? Text(
                  _getLocalizedTitle(language),
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? AppTheme.accentBlueDark
                        : AppTheme.accentBlueLight,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'AI SAGA',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppTheme.accentBlueDark
                            : AppTheme.accentBlueLight,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'AI 傳奇',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppTheme.accentBlueDark
                            : AppTheme.accentBlueLight,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'AI サーガ',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppTheme.accentBlueDark
                            : AppTheme.accentBlueLight,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'AI 사가',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppTheme.accentBlueDark
                            : AppTheme.accentBlueLight,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _homeContentKey = 0;

  // ---- 菜单文本本地化 ----

  /// 菜单标题
  String _getMenuTitle() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '選單';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Menu';
      case 'ja':
        return 'メニュー';
      case 'ko':
        return '메뉴';
      default:
        return '菜单';
    }
  }

  /// 订阅管理
  String _getSubscriptionText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '訂閱管理';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Subscription';
      case 'ja':
        return 'サブスクリプション';
      case 'ko':
        return '구독 관리';
      default:
        return '订阅管理';
    }
  }

  /// 日间模式
  String _getDayModeText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '日間模式';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Light Mode';
      case 'ja':
        return 'ライトモード';
      case 'ko':
        return '라이트 모드';
      default:
        return '日间模式';
    }
  }

  /// 夜间模式
  String _getNightModeText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '夜間模式';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Dark Mode';
      case 'ja':
        return 'ダークモード';
      case 'ko':
        return '다크 모드';
      default:
        return '夜间模式';
    }
  }

  /// 重新开始
  String _getRestartText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重新開始';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Restart';
      case 'ja':
        return '最初から';
      case 'ko':
        return '다시 시작';
      default:
        return '重新开始';
    }
  }

  /// 继续游玩
  String _getContinuePlayingText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '繼續遊玩';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Continue Playing';
      case 'ja':
        return '続けて遊ぶ';
      case 'ko':
        return '계속하기';
      default:
        return '继续游玩';
    }
  }

  void _showMenuSheet() {
    final isDark = themeBrightnessNotifier.value == Brightness.dark;
    showCupertinoModalPopup(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(
          _getMenuTitle(),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: isDark
                ? AppTheme.primaryTextDark
                : AppTheme.primaryTextLight,
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              _showSubscriptionSheet();
            },
            child: Text(
              _getSubscriptionText(),
              style: TextStyle(
                color: isDark
                    ? AppTheme.primaryTextDark
                    : AppTheme.primaryTextLight,
              ),
            ),
          ),
          // 夜间模式切换
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              _toggleDarkMode();
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isDark
                      ? CupertinoIcons.sun_max_fill
                      : CupertinoIcons.moon_fill,
                  size: 18,
                  color: isDark
                      ? AppTheme.primaryTextDark
                      : AppTheme.primaryTextLight,
                ),
                const SizedBox(width: 8),
                Text(
                  isDark ? _getDayModeText() : _getNightModeText(),
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.primaryTextDark
                        : AppTheme.primaryTextLight,
                  ),
                ),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              _showConfirmRestartDialog();
            },
            child: Text(
              _getRestartText(),
              style: TextStyle(
                color: isDark
                    ? AppTheme.destructiveRedDark
                    : AppTheme.destructiveRedLight,
              ),
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(
            _getContinuePlayingText(),
            style: TextStyle(
              color: isDark
                  ? AppTheme.accentBlueDark
                  : AppTheme.accentBlueLight,
            ),
          ),
        ),
      ),
    );
  }

  void _toggleDarkMode() {
    final newBrightness = themeBrightnessNotifier.value == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    themeBrightnessNotifier.value = newBrightness;
    StorageService.saveIsDarkMode(newBrightness == Brightness.dark);
  }

  // ---- 订阅/充值相关本地化 ----

  String _getSubscriptionMessage() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '請選擇一個充值方案\n所有價格已含稅，將通過 iTunes 帳戶支付';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Choose a plan\nAll prices include tax, billed through your iTunes account';
      case 'ja':
        return 'プランを選択してください\nすべての価格は税込みです。iTunesアカウントから支払われます';
      case 'ko':
        return '요금제를 선택하세요\n모든 가격은 세금 포함이며 iTunes 계정으로 결제됩니다';
      default:
        return '选择一个充值方案\n所有价格已含税，将通过 iTunes 账户支付';
    }
  }

  String _getCaseText(int count) {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '$count 個案件';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return '$count Case${count > 1 ? 's' : ''}';
      case 'ja':
        return '$count 件';
      case 'ko':
        return '$count개';
      default:
        return '$count 个案件';
    }
  }

  String _getBestValueText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '超值推薦';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Best Value';
      case 'ja':
        return 'おすすめ';
      case 'ko':
        return '추천';
      default:
        return '超值推荐';
    }
  }

  String _getRestorePurchaseText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '恢復購買';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Restore Purchase';
      case 'ja':
        return '購入を復元';
      case 'ko':
        return '구매 복원';
      default:
        return '恢复购买';
    }
  }

  String _getCloseText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '關閉';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Close';
      case 'ja':
        return '閉じる';
      case 'ko':
        return '닫기';
      default:
        return '关闭';
    }
  }

  String _getRestartConfirmText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重新開始會清空現在所有進度，遊戲完全重新開始，請再次確認！';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'This will clear all progress and restart the game completely. Are you sure?';
      case 'ja':
        return 'すべての進行状況がクリアされ、ゲームが最初からやり直しになります。本当によろしいですか？';
      case 'ko':
        return '모든 진행 상황이 지워지고 게임이 완전히 다시 시작됩니다. 다시 확인해주세요!';
      default:
        return '重新开始会清空现在所有进度，游戏完全重新开始，请再次确认！';
    }
  }

  String _getConfirmRestartButtonText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '確認重新開始';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Confirm Restart';
      case 'ja':
        return '最初から始める';
      case 'ko':
        return '다시 시작 확인';
      default:
        return '确认重新开始';
    }
  }

  String _getCancelText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '放棄';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Cancel';
      case 'ja':
        return 'キャンセル';
      case 'ko':
        return '취소';
      default:
        return '放弃';
    }
  }

  void _showSubscriptionSheet() {
    final isDark = themeBrightnessNotifier.value == Brightness.dark;
    showCupertinoModalPopup(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(
          _getSubscriptionText(),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: isDark
                ? AppTheme.primaryTextDark
                : AppTheme.primaryTextLight,
          ),
        ),
        message: Text(
          _getSubscriptionMessage(),
          style: TextStyle(
            fontSize: 13,
            color: isDark
                ? AppTheme.secondaryTextDark
                : AppTheme.secondaryTextLight,
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _getCaseText(1),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: isDark
                            ? AppTheme.primaryTextDark
                            : AppTheme.primaryTextLight,
                      ),
                    ),
                    Text(
                      '≈ \$0.49 USD',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppTheme.secondaryTextDark
                            : AppTheme.secondaryTextLight,
                      ),
                    ),
                  ],
                ),
                Text(
                  '¥3.50',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppTheme.accentBlueDark
                        : AppTheme.accentBlueLight,
                  ),
                ),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.accentBlueDark
                                : AppTheme.accentBlueLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getBestValueText(),
                            style: TextStyle(
                              color: AppTheme.buttonText,
                              fontSize: 10,
                            ),
                          ),
                        ),
                        Text(
                          _getCaseText(10),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? AppTheme.primaryTextDark
                                : AppTheme.primaryTextLight,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      '≈ \$2.99 USD (每个仅 \$0.299)',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppTheme.secondaryTextDark
                            : AppTheme.secondaryTextLight,
                      ),
                    ),
                  ],
                ),
                Text(
                  '¥21.00',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppTheme.accentBlueDark
                        : AppTheme.accentBlueLight,
                  ),
                ),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Text(
              _getRestorePurchaseText(),
              style: TextStyle(
                color: isDark
                    ? AppTheme.primaryTextDark
                    : AppTheme.primaryTextLight,
              ),
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text(
            _getCloseText(),
            style: TextStyle(
              color: isDark
                  ? AppTheme.accentBlueDark
                  : AppTheme.accentBlueLight,
            ),
          ),
        ),
      ),
    );
  }

  void _showConfirmRestartDialog() {
    final isDark = themeBrightnessNotifier.value == Brightness.dark;
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(
          _getRestartText(),
          style: TextStyle(
            color: isDark
                ? AppTheme.primaryTextDark
                : AppTheme.primaryTextLight,
          ),
        ),
        content: Text(
          _getRestartConfirmText(),
          style: TextStyle(
            color: isDark
                ? AppTheme.secondaryTextDark
                : AppTheme.secondaryTextLight,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              StorageService.clearAll();
              setState(() {
                _homeContentKey++;
              });
            },
            child: Text(
              _getConfirmRestartButtonText(),
              style: TextStyle(
                color: isDark
                    ? AppTheme.destructiveRedDark
                    : AppTheme.destructiveRedLight,
              ),
            ),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Text(
              _getCancelText(),
              style: TextStyle(
                color: isDark
                    ? AppTheme.accentBlueDark
                    : AppTheme.accentBlueLight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeBrightnessNotifier.value == Brightness.dark;
    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: HomeContent(key: ValueKey(_homeContentKey)),
          ),
          // 右上角菜单按钮（设置过程中隐藏）
          ValueListenableBuilder<bool>(
            valueListenable: showMenuNotifier,
            builder: (context, showMenu, child) {
              if (!showMenu) return const SizedBox.shrink();
              return Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 16,
                child: GestureDetector(
                  onTap: _showMenuSheet,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppTheme.cardBackgroundDark
                          : AppTheme.cardBackgroundLight,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      CupertinoIcons.line_horizontal_3,
                      color: isDark
                          ? AppTheme.accentBlueDark
                          : AppTheme.accentBlueLight,
                      size: 18,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
