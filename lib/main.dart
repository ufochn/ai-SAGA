import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:ai_saga/logic/account_service.dart';
import 'package:ai_saga/logic/home_content.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sync_service.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/security_service.dart';
import 'package:ai_saga/widgets/light_auth_page.dart';
import 'package:ai_saga/widgets/security_warning_page.dart';
import 'package:ai_saga/widgets/app_restart.dart';
import 'package:ai_saga/widgets/technical_disclaimer_dialog.dart';

/// 全局主题亮度通知器
final ValueNotifier<Brightness> themeBrightnessNotifier =
    ValueNotifier<Brightness>(
      StorageService.getIsDarkMode() ? Brightness.dark : Brightness.light,
    );

/// 【诊断】右上角菜单按钮上次渲染的流式状态（用于观察按钮是否被 done 恢复）
bool _lastMenuStreaming = false;

// ---- Web 端 CJK 本地字体（仅网页版生效，原生 iOS/Android/桌面不受影响）----
// Flutter Web 用 CanvasKit 渲染时，中/日/韩字形需异步下载 fallback 字体，
// 下载完成前显示占位符/豆腐块。这里在启动时从本站 /fonts/ 加载 4MB 常用子集
// （Noto CJK）并注册为回退字体，常用字即时渲染；生僻字仍由 CanvasKit 自动下载回退。
// 原生端 kIsWeb=false 完全跳过，不增肥、继续用系统字体。
const String _webCjkFontUrl = '/fonts/NotoSansCJK-Common.otf';
const String _webCjkFontFamily = 'NotoCJKWeb';

Future<void> _loadWebCjkFont() async {
  if (!kIsWeb) return; // 仅 Web 端加载
  try {
    final resp = await http.get(Uri.parse(_webCjkFontUrl));
    if (resp.statusCode != 200) return;
    final loader = FontLoader(_webCjkFontFamily)
      ..addFont(Future.value(ByteData.sublistView(resp.bodyBytes)));
    await loader.load();
  } catch (_) {
    // 字体加载失败不阻塞启动，退回浏览器默认回退字体
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 设备完整性检测：返回设备是否疑似被 root / 越狱；
  // 若疑似越狱，主界面显示"设备安全警告"页（英文提示 + Exit 按钮），
  // 由用户确认后关闭 App，而非静默退出。
  final compromised = await SecurityService.isDeviceCompromised();
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
  await _loadWebCjkFont(); // Web 端在渲染前加载 CJK 字体，避免占位符
  runApp(RestartWidget(child: MyApp(compromised: compromised)));
}

class MyApp extends StatelessWidget {
  final bool compromised;
  const MyApp({super.key, required this.compromised});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeBrightnessNotifier,
      builder: (context, _) {
        final isDark = themeBrightnessNotifier.value == Brightness.dark;
        return CupertinoApp(
          title: 'Ghost Tales AI',
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
                // Web 端回退到本地加载的 CJK 字体；原生端不设置，保持系统字体
                fontFamilyFallback: kIsWeb ? const [_webCjkFontFamily] : null,
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
          home: compromised
              ? const DeviceSecurityWarningPage()
              : const SplashScreen(),
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

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// 封面标题动画控制器：总时长 9s
  late final AnimationController _animationController;

  /// 标题透明度时序：
  /// 0-3s 淡入 → 3-7s 淡出 → 7-9s 空白(静止 2s)
  late final Animation<double> _titleOpacity;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    );
    _titleOpacity = TweenSequence<double>([
      // 淡入 3s：easeIn 曲线，先慢慢变亮、速度越来越快，第 3 秒才到最亮
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 3,
      ),
      // 淡出 4s：easeIn 曲线，先慢慢变暗、最后加速彻底透明（无中间静止）
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 4,
      ),
      // 空白静止 2s
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 2),
    ]).animate(_animationController);

    // 免责弹窗：每次启动在 Splash 标题出现前先弹（此刻标题保持透明）。
    // 用户点"知道了"后，才开始 9s 标题动画；动画走完后进入下一个页面。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAfterDisclaimer();
    });
  }

  /// 每次启动先弹「技术交流 · 非商用版」免责弹窗（当前语言），
  /// 确认关闭后才开始标题动画，保证标题在弹窗之后出现。
  Future<void> _startAfterDisclaimer() async {
    if (!mounted) return;
    await showTechnicalDisclaimer(context);
    if (!mounted) return;
    // 动画走完（9s）后：播放音效并直接进入下一个页面
    _animationController.forward().whenComplete(_goToNextPage);
  }

  /// 标题消失并静止 2s 后，直接进入下一个页面（无过渡动画）
  Future<void> _goToNextPage() async {
    if (!mounted) return;
    SoundService.playHorror();
    // 语言不再在启动时单独选择：StorageService.getLanguage() 按
    // 「已存语言 → 系统语言」回退；语言选择统一放在设定流程
    // （新用户从语言页开始设置，老用户用服务器金标准语言覆盖）。
    final authorized = await AccountService.isAuthorized();
    if (!mounted) return;
    final Widget nextPage = authorized
        ? const MyHomePage()
        : const LightAuthGate();
    Navigator.of(context).pushReplacement(
      // 下一个页面直接显现（不播放过渡动画）
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => nextPage,
        transitionDuration: Duration.zero,
      ),
    );
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
        return '鬼談錄 AI';
      case 'en':
        return 'Ghost Tales AI';
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Ghost Tales AI';
      case 'ja':
        return '怪談録 AI';
      case 'ko':
        return '귀신담록 AI';
      default:
        return '鬼谈录 AI';
    }
  }

  /// 把标题渲染成"主词 + AI 上标"：AI 缩小并抬到主词右上角，类似注册商标的 ™ 角标。
  ///
  /// 注意：**不要**用 `RichText` + `WidgetSpan` + `PlaceholderAlignment.baseline`
  /// 做上标——inline placeholder 的 baseline 对齐会在 RichText 布局时触发断言
  /// （红屏）。这里改用纯 `Stack` 把 "AI" 钉在主词右上角，无 inline placeholder，
  /// 无断言风险。
  Widget _buildTitle(String title) {
    final isDark = AppTheme.isDark(context);
    final color = isDark ? AppTheme.accentBlueDark : AppTheme.accentBlueLight;
    const double fontSize = 48;
    const String aiSuffix = ' AI';
    final bool hasAi = title.endsWith(aiSuffix);
    final String base = hasAi
        ? title.substring(0, title.length - aiSuffix.length)
        : title;

    final TextStyle style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      color: color,
      height: 1.0,
    );

    if (!hasAi) {
      return Text(base, textAlign: TextAlign.center, style: style);
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Text(base, textAlign: TextAlign.center, style: style),
        Positioned(
          top: 0,
          right: 0,
          child: Transform.translate(
            // 把 AI 往右上角再推一点（正右 + 略上），落在主词右上角
            offset: const Offset(fontSize * 0.5, -fontSize * 0.06),
            child: Text(
              'AI',
              style: TextStyle(
                fontSize: fontSize * 0.34,
                fontWeight: FontWeight.w600,
                color: color,
                height: 1.0,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final language = StorageService.getLanguage();
    final hasLanguage = language.isNotEmpty;

    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: Center(
        child: FadeTransition(
          // 标题按「淡入 3s → 淡出 4s → 空白 2s」播放（无中间静止）
          opacity: _titleOpacity,
          child: hasLanguage
              ? _buildTitle(_getLocalizedTitle(language))
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTitle('Ghost Tales AI'),
                    const SizedBox(height: 10),
                    _buildTitle('鬼談錄 AI'),
                    const SizedBox(height: 10),
                    _buildTitle('怪談録 AI'),
                    const SizedBox(height: 10),
                    _buildTitle('귀신담록 AI'),
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

  /// 菜单在生成期间被禁用时的提示文案
  String _getMenuLockedText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '正在生成中，選單暫不可用';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Generating… menu unavailable';
      case 'ja':
        return '生成中です。メニューはご利用いただけません';
      case 'ko':
        return '생성 중입니다. 메뉴를 사용할 수 없습니다';
      default:
        return '正在生成中，菜单暂不可用';
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

  /// 生成期间点击被禁用的菜单按钮时，显示一段短暂的提示（自动消失）
  void _showMenuLockedToast() {
    final isDark = themeBrightnessNotifier.value == Brightness.dark;
    final OverlayState overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 56,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.fieldBackgroundDark
                    : AppTheme.fieldBackgroundLight,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: CupertinoColors.black.withValues(
                      alpha: isDark ? 0.4 : 0.12,
                    ),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                _getMenuLockedText(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? AppTheme.secondaryTextDark
                      : AppTheme.secondaryTextLight,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (entry.mounted) entry.remove();
    });
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

  /// 正在清空数据（进度弹窗文案）
  String _getResettingText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '正在清空數據，請稍後…';
      case 'en':
        return 'Clearing data, please wait…';
      case 'es':
        return 'Borrando datos, espere…';
      case 'fr':
        return 'Suppression des données, veuillez patienter…';
      case 'de':
        return 'Daten werden gelöscht, bitte warten…';
      case 'pt':
        return 'Limpando dados, aguarde…';
      case 'ja':
        return 'データを消去しています。しばらくお待ちください…';
      case 'ko':
        return '데이터를 삭제하는 중입니다. 잠시만 기다려 주세요…';
      default:
        return '正在清空数据，请稍后…';
    }
  }

  /// 重置完成标题
  String _getResetDoneTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重設完成';
      case 'en':
        return 'Reset Complete';
      case 'es':
        return 'Restablecimiento Completado';
      case 'fr':
        return 'Réinitialisation terminée';
      case 'de':
        return 'Zurücksetzen abgeschlossen';
      case 'pt':
        return 'Redefinição Concluída';
      case 'ja':
        return 'リセット完了';
      case 'ko':
        return '초기화 완료';
      default:
        return '重置完成';
    }
  }

  /// 重置完成内容
  String _getResetDoneMessageText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '所有小說數據已清空，現在重新啟動 App。';
      case 'en':
        return 'All story data has been cleared. The app will restart now.';
      case 'es':
        return 'Se han borrado todos los datos de la historia. La app se reiniciará ahora.';
      case 'fr':
        return 'Toutes les données de l\'histoire ont été effacées. L\'application va redémarrer.';
      case 'de':
        return 'Alle Story-Daten wurden gelöscht. Die App wird jetzt neu gestartet.';
      case 'pt':
        return 'Todos os dados da história foram apagados. O app será reiniciado agora.';
      case 'ja':
        return 'すべての物語データを消去しました。アプリを再起動します。';
      case 'ko':
        return '모든 스토리 데이터가 삭제되었습니다. 앱을 다시 시작합니다.';
      default:
        return '所有小说数据已清空，现在重启 App。';
    }
  }

  /// "现在重启"按钮文字
  String _getRestartNowButtonText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重新啟動';
      case 'en':
        return 'Restart';
      case 'es':
        return 'Reiniciar';
      case 'fr':
        return 'Redémarrer';
      case 'de':
        return 'Neu starten';
      case 'pt':
        return 'Reiniciar';
      case 'ja':
        return '再起動';
      case 'ko':
        return '다시 시작';
      default:
        return '重启';
    }
  }

  /// 重置失败标题
  String _getResetFailedTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重設失敗';
      case 'en':
        return 'Reset Failed';
      case 'es':
        return 'Error al Restablecer';
      case 'fr':
        return 'Échec de la réinitialisation';
      case 'de':
        return 'Zurücksetzen fehlgeschlagen';
      case 'pt':
        return 'Falha na Redefinição';
      case 'ja':
        return 'リセット失敗';
      case 'ko':
        return '초기화 실패';
      default:
        return '重置失败';
    }
  }

  /// 重置失败内容
  String _getResetFailedMessageText(String detail) {
    final prefix = switch (StorageService.getLanguage()) {
      'zh-TW' || 'yue' => '無法清空數據，請檢查網絡後重試。',
      'en' => 'Failed to clear data. Please check your network and try again.',
      'es' =>
        'No se pudieron borrar los datos. Revisa tu red e inténtalo de nuevo.',
      'fr' =>
        'Échec de la suppression des données. Vérifiez le réseau et réessayez.',
      'de' =>
        'Daten konnten nicht gelöscht werden. Prüfen Sie das Netzwerk und versuchen Sie es erneut.',
      'pt' =>
        'Não foi possível apagar os dados. Verifique a rede e tente novamente.',
      'ja' => 'データを消去できませんでした。ネットワークを確認して再試行してください。',
      'ko' => '데이터를 삭제하지 못했습니다. 네트워크를 확인하고 다시 시도해 주세요.',
      _ => '无法清空数据，请检查网络后重试。',
    };
    return '$prefix\n$detail';
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
              _performRestart();
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

  /// "多客户端冲突"标题（本地化，仅退出）
  String _getMultiClientTitleText() {
    return StorageService.localizedText(
      zhCN: '检测到其他设备同时登入',
      zhTW: '偵測到其他裝置同時登入',
      en: 'Another Device Is Signed In',
      yue: '偵測到其他裝置同時登入',
      es: 'Otro dispositivo inició sesión',
      fr: 'Un autre appareil est connecté',
      de: 'Ein anderes Gerät ist angemeldet',
      pt: 'Outro dispositivo está conectado',
      ja: '別のデバイスがログインしています',
      ko: '다른 기기가 로그인되어 있습니다',
    );
  }

  /// "多客户端冲突"内容（本地化）
  String _getMultiClientMessageText() {
    return StorageService.localizedText(
      zhCN: '似乎有其他设备在同时登入，为保证小说文本完整，请过几分钟再次尝试登入。',
      zhTW: '似乎有其他裝置同時登入，為保證小說文本完整，請過幾分鐘再次嘗試登入。',
      en: 'It looks like another device is signed in at the same time. To keep your story text complete, please try signing in again in a few minutes.',
      yue: '似乎有其他裝置同時登入，為咗保證小說文本完整，請過幾分鐘再試吓登入。',
      es: 'Parece que otro dispositivo inició sesión al mismo tiempo. Para mantener el texto de tu historia completo, intenta iniciar sesión de nuevo en unos minutos.',
      fr: "Un autre appareil semble être connecté en même temps. Pour conserver le texte de votre histoire complet, réessayez de vous connecter dans quelques minutes.",
      de: 'Es scheint, dass ein anderes Gerät gleichzeitig angemeldet ist. Um Ihren Geschichtentext vollständig zu erhalten, versuchen Sie es in einigen Minuten erneut.',
      pt: 'Parece que outro dispositivo está conectado ao mesmo tempo. Para manter o texto da sua história completo, tente entrar novamente em alguns minutos.',
      ja: '同時に別のデバイスがログインしているようです。小説のテキストを完全に保つため、数分後にもう一度ログインしてください。',
      ko: '다른 기기가 동시에 로그인된 것 같습니다. 이야기 텍스트를 완전하게 유지하려면 몇 분 후 다시 로그인해 주세요.',
    );
  }

  /// "多客户端冲突"退出按钮（本地化）
  String _getMultiClientExitText() {
    return StorageService.localizedText(
      zhCN: '退出',
      zhTW: '退出',
      en: 'Exit',
      yue: '退出',
      es: 'Salir',
      fr: 'Quitter',
      de: 'Beenden',
      pt: 'Sair',
      ja: '終了',
      ko: '종료',
    );
  }

  /// 重新开始流程：先弹出"正在清空数据"进度弹窗 → 清空服务器正文 + 本地数据 →
  /// 完成后弹出"重置完成，重启"弹窗，用户确认后重启 App。
  Future<void> _performRestart() async {
    final isDark = themeBrightnessNotifier.value == Brightness.dark;
    // 1) 进度弹窗：旋转图标 + "正在清空数据，请稍后…"（不可关闭）
    showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => CupertinoAlertDialog(
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _getResettingText(),
                textAlign: TextAlign.left,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.secondaryTextDark
                      : AppTheme.secondaryTextLight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    try {
      // 2) 清空服务器小说正文（权威）→ 再清空本地数据
      await SyncService.resetStory();
      await StorageService.clearAll();
      if (!mounted) return;
      // 3) 关闭进度弹窗，弹出"重置完成，重启"弹窗
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await showCupertinoDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(
            _getResetDoneTitleText(),
            style: TextStyle(
              color: isDark
                  ? AppTheme.primaryTextDark
                  : AppTheme.primaryTextLight,
            ),
          ),
          content: Text(
            _getResetDoneMessageText(),
            style: TextStyle(
              color: isDark
                  ? AppTheme.secondaryTextDark
                  : AppTheme.secondaryTextLight,
            ),
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                RestartWidget.restartApp(dialogContext);
              },
              child: Text(
                _getRestartNowButtonText(),
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
    } on MultiClientConflictException {
      // 本设备口令已失效（被其它设备顶掉）：清库被拒 → 关进度弹窗，弹"多客户端仅退出"
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(_getMultiClientTitleText()),
          content: Text(_getMultiClientMessageText()),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                SecurityService.exitApp();
              },
              child: Text(_getMultiClientExitText()),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // 关闭进度弹窗，弹出失败提示
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(
            _getResetFailedTitleText(),
            style: TextStyle(
              color: isDark
                  ? AppTheme.destructiveRedDark
                  : AppTheme.destructiveRedLight,
            ),
          ),
          content: Text(
            _getResetFailedMessageText(e.toString()),
            style: TextStyle(
              color: isDark
                  ? AppTheme.secondaryTextDark
                  : AppTheme.secondaryTextLight,
            ),
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
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
          // 右上角菜单按钮（设置过程中隐藏；小说生成期间禁用并置灰，不使用锁图标以免歧义）
          ValueListenableBuilder<bool>(
            valueListenable: showMenuNotifier,
            builder: (context, showMenu, child) {
              if (!showMenu) return const SizedBox.shrink();
              // “正在同步”加载页（startupSyncNotifier=true）不显示右上角菜单按钮
              return ValueListenableBuilder<bool>(
                valueListenable: startupSyncNotifier,
                builder: (context, syncing, _) {
                  if (syncing) return const SizedBox.shrink();
                  return ValueListenableBuilder<bool>(
                    valueListenable: storyStreamingNotifier,
                    builder: (context, isStreaming, child) {
                  // 【诊断】记录菜单按钮流式状态变化（判断 done 是否恢复按钮）
                  if (_lastMenuStreaming != isStreaming) {
                    _lastMenuStreaming = isStreaming;
                    debugPrint('[menu] isStreaming -> $isStreaming');
                  }
                  return ValueListenableBuilder<double>(
                    valueListenable: menuRevealNotifier,
                    builder: (context, reveal, child) {
                      return Positioned(
                        top: MediaQuery.of(context).padding.top + 8,
                        right: 16,
                        child: Opacity(
                          // 进入世界黑屏期间随亮度一起淡入；正常时恒为 1
                          opacity: reveal,
                          child: GestureDetector(
                            // 生成期间禁止打开菜单：点击只弹短暂提示，说明当前状态
                            onTap: isStreaming
                                ? _showMenuLockedToast
                                : _showMenuSheet,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? (isStreaming
                                          ? AppTheme.fieldBackgroundDark
                                          : AppTheme.cardBackgroundDark)
                                    : (isStreaming
                                          ? AppTheme.fieldBackgroundLight
                                          : AppTheme.cardBackgroundLight),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Icon(
                                // 始终显示正常菜单图标；生成期间不可点击时仅置灰提示不可用
                                CupertinoIcons.line_horizontal_3,
                                color: isDark
                                    ? (isStreaming
                                          ? AppTheme.buttonDisabledTextDark
                                          : AppTheme.accentBlueDark)
                                    : (isStreaming
                                          ? AppTheme.buttonDisabledTextLight
                                          : AppTheme.accentBlueLight),
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
            },
          ),
        ],
      ),
    );
  }
}
