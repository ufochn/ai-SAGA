import 'package:flutter/cupertino.dart';
import 'package:ai_saga/widgets/account_limit_warning.dart';
import 'package:ai_saga/widgets/app_restart.dart';
import 'package:ai_saga/widgets/character_text.dart';
import 'package:ai_saga/widgets/light_auth_page.dart';
import 'package:ai_saga/widgets/story_choice_card.dart';
import 'package:ai_saga/widgets/story_choice_marker.dart';
import 'package:ai_saga/widgets/text_input_panel.dart';
import 'package:ai_saga/widgets/initialization_page.dart';
import 'package:ai_saga/widgets/location_setup_page.dart';
import 'package:ai_saga/widgets/era_setup_page.dart';
import 'package:ai_saga/widgets/player_setup_page.dart';
import 'package:ai_saga/widgets/character_setup_page.dart';

import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/setup_draft.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/story_service.dart';
import 'package:ai_saga/logic/sync_service.dart';
import 'package:ai_saga/widgets/setup_confirmation_page.dart';

/// 上插更早内容时用于"无闪"补偿的滚动控制器。
///
/// 调用 [armCompensation] 后，下一次内容高度增长（例如把更早文本段前插到顶部）
/// 会在**同一帧的布局阶段**按实际新增高度同步修正滚动偏移（通过自定义
/// [ScrollPosition.correctForNewDimensions]），因此渲染出来的正文从一开始就处于
/// 正确位置——下方正文完全静止、上方像"长出"了更早内容，没有任何闪帧或跳动。
class _CompensatingScrollController extends ScrollController {
  bool _armCompensation = false;

  /// 下次布局中的内容高度增长需要按新增高度补偿滚动偏移。
  void armCompensation() {
    _armCompensation = true;
  }

  /// 布局阶段消费补偿标记；返回是否需要在本次高度增长时补偿偏移。
  bool consumeCompensation() {
    final bool armed = _armCompensation;
    _armCompensation = false;
    return armed;
  }

  /// 兜底：若本帧未发生布局（极端情况），清除标记，避免误补偿后续内容增长。
  void disarmCompensation() {
    _armCompensation = false;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _CompensatingScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      controller: this,
    );
  }
}

/// 布局阶段按新增高度补偿滚动偏移的 ScrollPosition。
///
/// 当内容在上方前插导致 [maxScrollExtent] 增大时，把当前滚动偏移同步加上
/// 新增高度，从而保持视野中的正文位置不动。补偿发生在 [applyContentDimensions]
/// 的布局过程中（早于绘制），因此对用户完全无感。
class _CompensatingScrollPosition extends ScrollPositionWithSingleContext {
  _CompensatingScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.controller,
  });

  final _CompensatingScrollController controller;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    if (controller.consumeCompensation() &&
        newPosition.maxScrollExtent > oldPosition.maxScrollExtent) {
      final double delta =
          newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
      correctPixels(pixels + delta);
      return false; // 偏移已修正，请求在同一帧内重新布局一次
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}

/// 用于控制菜单按钮显示/隐藏的通知器
final ValueNotifier<bool> showMenuNotifier = ValueNotifier<bool>(true);

/// 字符流生成器 - 用于生成重复的字符序列
class CharacterStream {
  final String character;
  final int count;

  const CharacterStream({required this.character, required this.count});

  /// 生成字符流字符串
  String generate() {
    return character * count;
  }
}

/// 正文中的用户选择节点（未来"时间树"返回功能的数据点）
class _ChoiceRecord {
  /// 用户选择的内容
  final String text;

  /// 该选择所在的文本段绝对下标（= _storyStartIndex + 本地数组下标，与服务器 seq 对齐）
  final int segmentIndex;

  /// 该选择在该文本段内的起始下标（续写正文从该位置开始）
  final int startOffset;

  const _ChoiceRecord({
    required this.text,
    required this.segmentIndex,
    required this.startOffset,
  });
}

/// 页面主体内容组件 - 综合文字、按钮和输入框的混合布局
class HomeContent extends StatefulWidget {
  const HomeContent({super.key});

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent>
    with SingleTickerProviderStateMixin {
  /// 尚无任何正文时显示的占位文本（本地生成，不持久化）
  String _emptyStoryText = '';
  final _CompensatingScrollController _scrollController =
      _CompensatingScrollController();
  late final PageController _pageController;

  /// 主角性别: 0=男, 1=女, null=未设定（用于传递给搭档页面决定默认性别）
  int? _playerGenderIndex;

  /// 0=语言选择, 1=地点设定, 2=年代设定, 3=主角设定, 4=搭档设定,
  /// 5=设置确认页（倒计时）, 6=正式主页面
  int _setupStep = 0;

  /// 最近一次确认的语言（用于检测语言变化，从而重置后续设置页）
  String _confirmedLanguage = '';

  /// 设置完成后进入正式主页前的黑屏过渡动画控制器
  late final AnimationController _blackoutController;

  /// 是否正在显示黑屏过渡（全黑 → 渐渐点亮）
  bool _blackoutActive = false;

  /// 是否正在调用服务器/Dify 生成小说（黑屏上显示加载提示）
  bool _generating = false;

  /// 流式小说正文：每次生成的内容单独存为数组的一个元素。
  final List<String> _storyTexts = [];

  /// _storyTexts[0] 对应的服务器绝对段下标（seq）；_storyTexts[i] 的绝对下标 =
  /// _storyStartIndex + i。冷启动只拉尾部（最后 3 段），故本地数组可能从非 0
  /// 下标开始；向上懒加载更早段时前插并减小该偏移，保证与服务器 seq 对齐。
  int _storyStartIndex = 0;

  /// 本次会话中由流式生成的新段起始下标（此前的为重启恢复的历史段，
  /// 直接完整显示、不打字机动画）
  int _sessionStreamStartIndex = 0;

  /// 从 _storyTexts 的这个下标开始渲染：重启恢复历史内容时初始只显示
  /// 最后一个元素，向上滚动到顶部后逐步把更早的元素平滑加载到上方
  int _visibleStartIndex = 0;

  /// 是否正在向上加载更早的文本段（防止重复触发）
  bool _loadingPrevious = false;

  /// 是否正在从服务器下载更早的文本段（屏幕顶部显示下载旋转动画）
  bool _downloadingEarlier = false;

  /// 上一次从服务器拉取更早内容的时刻（用于防止一次上滑连发多批拉取）
  DateTime _lastServerLoad = DateTime.fromMillisecondsSinceEpoch(0);

  /// 冷启动同步门禁：为 true 时正在从服务器拉取数据（暂不开放后续功能）
  bool _startupSyncing = false;

  /// 冷启动同步失败原因（非空时显示错误并提供重试）
  String? _startupSyncError;

  /// 违规中止原因（非空时隐藏正文并显示该提示）
  String? _storyAbortReason;

  /// 是否正在接收/生成正文（流式进行中）：期间隐藏正文下方的输入框
  bool _storyStreaming = false;

  /// 正文是否已由打字机彻底显示完成：完成后恢复显示下方输入框
  bool _storyTyped = true;

  /// 本次流式正文是否已完整接收完成（只有收到 done 才为 true）。
  /// 断流/出错未收到 done 时保持 false，禁止基于残缺文本续写。
  bool _storyReceivedCompletely = true;

  /// 用户选择节点：正文中"用户选择：xxx" + 时间树返回占位按钮
  final List<_ChoiceRecord> _choices = [];

  /// 本轮三个输入框的当前值（任一确认时随请求一并上传，作为本轮选择一/二/三快照）
  String _inputChoice1 = '';
  String _inputChoice2 = '';
  String _inputChoice3 = '';

  @override
  void initState() {
    super.initState();
    // 占位文本：本地生成，不持久化
    _emptyStoryText = const CharacterStream(
      character: '正',
      count: 1000,
    ).generate();

    // 恢复历史小说正文（本地只存已加载的尾部；绝对下标从存储恢复，与服务器对齐）
    final savedTexts = StorageService.getMainTextList();
    if (savedTexts.isNotEmpty) {
      _storyTexts.addAll(savedTexts);
      _storyStartIndex = StorageService.getMainTextStartIndex();
    }
    if (_storyTexts.isNotEmpty) {
      // 已有小说内容：启动时只显示最后一个元素，向上滑动逐步加载前文
      _sessionStreamStartIndex = _storyTexts.length;
      _visibleStartIndex = _storyTexts.length - 1;
    }
    _scrollController.addListener(_onScroll);

    if (!StorageService.isInitialized()) {
      // 未最终确认前所有设置仅存于内存草稿；每次进入设置流程先清空草稿
      SetupDraft.instance.reset();
      // 语言已在轻授权前选择（新用户经 LanguageFirstGate）或已有历史数据：
      // 跳过语言页，从地点设定开始；若语言尚未选择，则仍从语言页开始。
      _setupStep = StorageService.getLanguage().isEmpty ? 0 : 1;
      showMenuNotifier.value = false;
    } else {
      // 已初始化（老用户）：直接进正式主页面，不经过确认页；
      // 冷启动先同步服务器数据（数据库单方面刷新 App 数据），完成后才显示正文
      _setupStep = 6;
      showMenuNotifier.value = true;
      _startupSyncing = true;
      _performStartupSync();
    }
    // 记录当前已选语言，用于检测后续用户是否切换语言
    _confirmedLanguage = StorageService.getLanguage();

    _pageController = PageController(
      initialPage: _setupStep < 2 ? _setupStep : 0,
    );

    _blackoutController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
      // 历史内容不足一屏（无法上滑）时，自动向上加载更早的内容
      if (_scrollController.hasClients &&
          _scrollController.position.maxScrollExtent <= 0 &&
          _visibleStartIndex > 0) {
        _loadPreviousSegment();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    _blackoutController.dispose();
    super.dispose();
  }

  /// 滚动监听：向上滚动到顶部时，若仍有更早的内容则平滑加载到当前内容上方
  void _onScroll() {
    if (!_scrollController.hasClients || _loadingPrevious) return;
    // 已在最顶部且还有更早内容（内存未揭示完或服务器还有更早段）时才加载
    if (_visibleStartIndex <= 0 && _storyStartIndex <= 0) return;
    if (_scrollController.position.pixels <= 0) {
      // 防止一次上滑/上移动画触发连发多批拉取：短时间内不重复请求服务器
      if (DateTime.now().difference(_lastServerLoad).inMilliseconds < 800) {
        return;
      }
      _loadPreviousSegment();
    }
  }

  /// 把更早的一段文本加载到当前内容上方，并补偿滚动偏移，
  /// 使当前视野内容保持不动（"平滑"衔接不跳动）。
  Future<void> _loadPreviousSegment() async {
    if (_loadingPrevious) return;

    // 1) 内存中仍有更早的段：直接揭示一个（不请求服务器）
    if (_visibleStartIndex > 0) {
      _loadingPrevious = true;
      // 上插前先武装同帧补偿：布局阶段按实际新增高度同步修正滚动偏移，
      // 使当前视野内的正文保持静止（"下方静止、上方长出内容"，无闪帧）。
      _scrollController.armCompensation();
      setState(() {
        _visibleStartIndex--;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadingPrevious = false;
        // 兜底清除补偿标记：若本帧未发生布局（极少数情况），避免误补偿后续内容增长
        _scrollController.disarmCompensation();
        // 若内容仍不足以滚动，则继续加载更早的内容，直到填满一屏或到小说开头
        if (_scrollController.hasClients &&
            _scrollController.position.maxScrollExtent <= 0 &&
            (_visibleStartIndex > 0 || _storyStartIndex > 0)) {
          _loadPreviousSegment();
        }
      });
      return;
    }

    // 2) 内存已到顶部：从服务器取最近一批更早段前插（每次只取一批，快速返回）
    if (_storyStartIndex <= 0) return; // 已是小说开头
    _loadingPrevious = true;
    _lastServerLoad = DateTime.now(); // 记录本次拉取时刻（防一次上滑连发多批）
    setState(() {
      _downloadingEarlier = true; // 顶部预留空间显示下载旋转动画
    });
    try {
      final earlier = await SyncService.fetchPreviousSegments(_storyStartIndex);
      if (!mounted) return;
      if (earlier.segments.isEmpty) {
        _storyStartIndex = 0; // 没有更早的段了
        _loadingPrevious = false;
        setState(() {
          _downloadingEarlier = false;
        });
        return;
      }
      final addedCount = earlier.segments.length;
      // 上插更早内容：先在布局阶段（同一帧、渲染之前）按"新增高度"补偿滚动偏移。
      // 这样渲染出来的正文一开始就处于正确位置，下方正文完全静止、上方长出更早内容，
      // 彻底避免"先以错位渲染一帧、再 jumpTo 跳回"造成的闪烁。
      _scrollController.armCompensation();
      setState(() {
        _storyTexts.insertAll(0, earlier.segments);
        _storyStartIndex = earlier.startSeq;
        // 新段直接渲染（从 0 开始渲染全部已加载段），上方即刚拉取的更早内容
        _visibleStartIndex = 0;
        // 本会话流式段的本地下标随之后移
        _sessionStreamStartIndex += addedCount;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadingPrevious = false;
        // 兜底清除补偿标记：若本帧未发生布局（极少数情况），避免误补偿后续内容增长
        _scrollController.disarmCompensation();
        setState(() {
          _downloadingEarlier = false;
        });
      });
    } catch (_) {
      // 加载更早章节失败：静默，允许下次滚动重试
      _loadingPrevious = false;
      if (mounted) {
        setState(() {
          _downloadingEarlier = false;
        });
      }
    }
  }

  /// 冷启动同步门禁：上传公钥 → 服务器更新硬件公钥 → 拉取全部数据单方面刷新本地。
  /// 成功后用同步后的数据重建内存；失败显示错误并提供重试。
  Future<void> _performStartupSync() async {
    setState(() {
      _startupSyncing = true;
      _startupSyncError = null;
    });
    try {
      final snap = await SyncService.syncAll();
      if (!mounted) return;
      setState(() {
        // 服务器数据已写入本地存储，据此重建内存中的小说数组（只含尾部）
        _storyTexts
          ..clear()
          ..addAll(snap.segments);
        _storyStartIndex = snap.startSeq;
        if (_storyTexts.isNotEmpty) {
          _sessionStreamStartIndex = _storyTexts.length;
          _visibleStartIndex = _storyTexts.length - 1;
        }
        _startupSyncing = false;
        _startupSyncError = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (!mounted) return;
      if (e is HardwareAccountLimitException) {
        // 同硬件 24h 内切换账号过多：弹出英文警告，用户确认后退出 App
        setState(() {
          _startupSyncing = false;
        });
        await showAccountLimitWarning(context);
        return;
      }
      if (e is AuthNotAuthorizedException) {
        // 登录令牌/授权过期（如老用户 7 天未使用）：
        // 引导重新做一次平台授权，拿到新 id_token 后继续同步
        await _promptReAuthAndResync();
        return;
      }
      setState(() {
        _startupSyncing = false;
        _startupSyncError = e.toString();
      });
    }
  }

  /// 令牌/授权过期时，推一个轻授权页引导用户一键重新授权，
  /// 成功后重试同步（数据不丢、无需重走设置）。
  Future<void> _promptReAuthAndResync() async {
    if (!mounted) return;
    setState(() {
      _startupSyncing = false;
    });
    final reauthed = await _promptReAuth();
    if (!mounted) return;
    if (reauthed) {
      _performStartupSync();
    } else {
      setState(() {
        _startupSyncError = '登录未完成，无法同步。请重新登录后重试。';
      });
    }
  }

  /// 推轻授权页引导一键重新授权；返回是否已重新授权。
  Future<bool> _promptReAuth() async {
    if (!mounted) return false;
    final needRetry = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => const LightAuthPage(
          onComplete: _dummyAuthComplete,
          popOnComplete: true,
        ),
      ),
    );
    return needRetry ?? false;
  }

  /// "登录未完成/需要重新登录"提示（本地化）
  String _getReauthRequiredText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '登录未完成，無法繼續。請重新登入後再試。';
      case 'en':
        return 'Sign-in incomplete. Please sign in again and retry.';
      default:
        return '登录未完成，无法继续。请重新登录后重试。';
    }
  }

  /// 占位回调（LightAuthPage 授权完成后由 push 返回值触发重试）。
  static void _dummyAuthComplete() {}

  /// 是否显示正文下方的三个输入框：
  /// - 已有正文且生成/接收中：保持可见，但“继续”按钮置灰禁用（不消失）；
  /// - 正文彻底显示完成（收到 done）或违规中止：可见、按钮可用；
  /// - 尚无正文（首次生成前）：隐藏。
  /// 断流/出错时保持隐藏，避免基于未传完的残缺文本续写。
  bool get _storyInputsVisible =>
      _storyTexts.isNotEmpty &&
      ((_storyTyped &&
              (_storyReceivedCompletely || _storyAbortReason != null)) ||
          _storyStreaming);

  /// 顶部“上拉加载更早内容”空白区高度：约屏幕的 1/4，旋转图标居中。
  double get _earlierPullHeight {
    final h = MediaQuery.of(context).size.height;
    return (h / 4).clamp(80.0, 280.0);
  }

  void _onInput1Confirm(String text) => _continueStory(text);

  void _onInput2Confirm(String text) => _continueStory(text);

  void _onInputConfirm(String text) => _continueStory(text);

  /// 任一输入框确认后：把输入作为 user_input，连同用户设定请求续写生成，
  /// 新内容在屏幕上接力显示（作为 _storyTexts 数组的新元素，由打字机继续揭示）。
  Future<void> _continueStory(String userInput, {int retryDepth = 0}) async {
    if (!mounted || userInput.trim().isEmpty) return;
    // 记录本次续写开始前的段数：断流出错时据此丢弃未传完的段落
    final int preStreamLen = _storyTexts.length;
    // 新一段内容是否已作为数组新元素创建（每次续写独占一个数组元素）
    bool segmentStarted = false;
    // 本次续写是否收到过非空正文（LLM 返回空白时用于弹窗警告）
    bool hadContent = false;
    setState(() {
      _generating = true;
      _storyAbortReason = null;
      _storyStreaming = true; // 接收正文中：隐藏下方输入框
      _storyTyped = false;
      _storyReceivedCompletely = false; // 本次正文尚未完整接收
      // 记录用户选择节点（时间树返回功能的占位数据）；重新授权重试时避免重复记录
      final alreadyRecorded =
          _choices.isNotEmpty &&
          _choices.last.text == userInput.trim() &&
          _choices.last.segmentIndex == _storyStartIndex + _storyTexts.length;
      if (!alreadyRecorded) {
        _choices.add(
          _ChoiceRecord(
            text: userInput.trim(),
            // 新一段将被追加到末尾，其绝对下标 = _storyStartIndex + 当前数组长度
            segmentIndex: _storyStartIndex + _storyTexts.length,
            startOffset: 0,
          ),
        );
      }
    });
    try {
      await StoryService.generateStoryStream(
        userInput: userInput,
        choice1: _inputChoice1,
        choice2: _inputChoice2,
        choice3: _inputChoice3,
        onDeviceConflict: _onDeviceConflict,
        onStalled: _onStreamStalled,
        onChunk: (text) {
          if (!mounted) return;
          if (text.trim().isNotEmpty) hadContent = true;
          setState(() {
            if (!segmentStarted) {
              // 新一段内容：单独存入数组新元素（每段自带卡片与间距，不再加空行前缀）
              _storyTexts.add(text);
              segmentStarted = true;
            } else {
              _storyTexts[_storyTexts.length - 1] += text;
            }
            _generating = false;
            _storyTyped = false; // 文本仍在增长：尚未彻底显示完成
          });
        },
        onReveal: (text, outputs) {
          if (!mounted) return;
          if (text.trim().isNotEmpty) hadContent = true;
          // 剩余部分不再一次性显示，而是由打字机以不断加速的方式接续打出
          setState(() {
            if (!segmentStarted) {
              // 新一段内容：单独存入数组新元素（每段自带卡片与间距，不再加空行前缀）
              _storyTexts.add(text);
              segmentStarted = true;
            } else {
              _storyTexts[_storyTexts.length - 1] += text;
            }
            _generating = false;
            _storyTyped = false; // 文本仍在增长：尚未彻底显示完成
          });
        },
        onAbort: (reason) {
          if (!mounted) return;
          setState(() {
            _storyAbortReason = reason;
            _generating = false;
            _storyStreaming = false;
            _storyTyped = true; // 正文被中止：恢复显示输入框以便继续
          });
        },
        onError: (message, {code}) {
          if (!mounted) return;
          setState(() {
            // 流未完整结束（未收到 done）：丢弃本次未传完的段落，
            // 避免基于残缺文本续写/误判；_storyReceivedCompletely 保持 false，
            // 输入框保持隐藏（除非违规中止）。
            if (_storyTexts.length > preStreamLen) {
              _storyTexts.removeRange(preStreamLen, _storyTexts.length);
            }
            _generating = false;
            _storyStreaming = false;
            _storyTyped = true;
          });
          // 服务器未返回有效正文（如额度用尽）：按当前语言提示检查额度
          _showGenerateError(
            code == 'empty_output' ? _getQuotaWarningText() : message,
          );
        },
        onDone: (outputs) async {
          if (!mounted) return;
          if (!hadContent) {
            // 本次未收到任何有效正文（如 LLM 额度用尽返回空白）：丢弃空段落并弹窗警告
            setState(() {
              if (_storyTexts.length > preStreamLen) {
                _storyTexts.removeRange(preStreamLen, _storyTexts.length);
              }
              _generating = false;
              _storyStreaming = false;
              _storyTyped = true;
              _storyReceivedCompletely = true;
            });
            _showGenerateError(_getQuotaWarningText());
            return;
          }
          setState(() {
            _storyStreaming = false; // 正文已全部接收完成
            _storyReceivedCompletely = true; // 已完整接收：放行继续续写
          });
          await StorageService.saveMainTextList(List.of(_storyTexts));
          await StorageService.saveMainTextStartIndex(_storyStartIndex);
        },
      );
    } on HardwareAccountLimitException {
      // 同硬件 24h 内切换账号过多：弹出英文警告，用户确认后退出 App
      if (!mounted) return;
      setState(() {
        _generating = false;
        _storyStreaming = false;
        _storyTyped = true;
      });
      await showAccountLimitWarning(context);
    } on AuthNotAuthorizedException {
      // 登录令牌/授权过期：引导重新授权后重试本次续写（不重复记录选择节点）
      if (!mounted || retryDepth >= 2) {
        setState(() {
          _generating = false;
          _storyStreaming = false;
          _storyTyped = true;
        });
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      final reauthed = await _promptReAuth();
      if (!reauthed || !mounted) {
        setState(() {
          _generating = false;
          _storyStreaming = false;
          _storyTyped = true;
        });
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      // 已重新授权：重试
      await _continueStory(userInput, retryDepth: retryDepth + 1);
      return;
    } catch (e) {
      // 其它注册/鉴权异常（如 IP 限流"注册过于频繁"）：展示具体原因
      if (!mounted) return;
      setState(() {
        _generating = false;
        _storyStreaming = false;
        _storyTyped = true;
      });
      _showGenerateError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 构建正文区：按数组顺序逐段渲染故事文本（打字机揭示），
  /// 并在每段内正确的位置插入用户选择节点
  List<Widget> _buildStoryBody() {
    // 违规中止：隐藏正文，仅显示中止提示
    if (_storyAbortReason != null && _storyTexts.isNotEmpty) {
      final isDark = AppTheme.isDark(context);
      return [
        Padding(
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
              _storyAbortReason!,
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.systemRed,
                height: 1.5,
              ),
            ),
          ),
        ),
      ];
    }
    // 尚无正文：显示默认文本
    if (_storyTexts.isEmpty) {
      return [CharacterText(text: _emptyStoryText)];
    }

    final List<Widget> children = [];
    // 只渲染 [ _visibleStartIndex, _storyTexts.length ) 范围内的文本段，
    // 更早的历史段等用户向上滚动到顶部时才逐个加载
    for (
      int segIndex = _visibleStartIndex;
      segIndex < _storyTexts.length;
      segIndex++
    ) {
      final segment = _storyTexts[segIndex];
      // 本次会话流式生成的新段用打字机揭示；重启恢复的历史段直接完整显示
      final useTypewriter = segIndex >= _sessionStreamStartIndex;
      // 该段内从段首到下一个选择标记之间的文本
      int cursor = 0;
      for (int i = 0; i < _choices.length; i++) {
        final choice = _choices[i];
        // 仅处理落在当前段内的选择节点（用绝对下标比较）
        if (choice.segmentIndex != _storyStartIndex + segIndex) continue;
        final offset = choice.startOffset;
        if (offset > cursor) {
          children.add(
            useTypewriter
                ? _buildStorySegment(
                    segment.substring(cursor, offset),
                    isLast: false,
                  )
                : CharacterText(text: segment.substring(cursor, offset)),
          );
        }
        children.add(
          StoryChoiceMarker(prefix: _getChoicePrefixText(), text: choice.text),
        );
        cursor = offset;
      }
      if (cursor < segment.length) {
        children.add(
          useTypewriter
              ? _buildStorySegment(
                  segment.substring(cursor),
                  isLast: segIndex == _storyTexts.length - 1,
                )
              : CharacterText(text: segment.substring(cursor)),
        );
      }
      // 历史段落（非最新一段）下方：三个输入框 + 三个"从这里重新开始"按钮，
      // 三个按钮用于实现"时间树"功能（当前为占位）。
      // 最新一段下方不插入卡片，其下方的输入框由页面底部的三个（"按照上面
      // 输入指引继续故事选择"）承载。
      if (segIndex < _storyTexts.length - 1) {
        children.add(
          StoryChoiceCard(
            buttonText: _getRestartHereButtonText(),
            inputPlaceholder: _getInputPlaceholder(),
            enabled: _storyTyped,
            onPressed: _onRestartHerePressed,
          ),
        );
      }
    }
    return children;
  }

  /// 构建单个故事文本段（打字机揭示；仅最后一段触发 onTypingDone）
  Widget _buildStorySegment(String text, {required bool isLast}) {
    return TypewriterText(
      text: text,
      speedUpEvery: 20,
      segmentStart: 0,
      onTypingDone: isLast
          ? () {
              if (!mounted) return;
              setState(() {
                // 打字机彻底显示完成：恢复显示下方输入框
                _storyTyped = true;
              });
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: const Cubic(0.22, 1.0, 0.36, 1.0),
          switchOutCurve: const Cubic(0.22, 1.0, 0.36, 1.0),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: _setupStep < 5
              ? KeyedSubtree(
                  key: const ValueKey('setup_pages'),
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (page) {
                      setState(() {
                        _setupStep = page;
                        showMenuNotifier.value = false;
                      });
                    },
                    children: [
                      // 第0页：语言选择
                      InitializationPage(
                        onComplete: () {
                          final newLanguage = StorageService.getLanguage();
                          // 语言发生变化时，清空全部设置草稿，使后续各设置页均按从未设置过处理
                          if (newLanguage != _confirmedLanguage) {
                            SetupDraft.instance.reset();
                          }
                          _confirmedLanguage = newLanguage;
                          _pageController.animateToPage(
                            1,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                      // 第1页：地点设定
                      LocationSetupPage(
                        languageKey: StorageService.getLanguage(),
                        onComplete: () {
                          _pageController.animateToPage(
                            2,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                        onBack: () {
                          _pageController.animateToPage(
                            0,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                      // 第2页：年代设定
                      EraSetupPage(
                        languageKey: StorageService.getLanguage(),
                        onComplete: () {
                          _pageController.animateToPage(
                            3,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                        onBack: () {
                          _pageController.animateToPage(
                            1,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                      // 第3页：主角设定（性别 + 姓名）
                      PlayerSetupPage(
                        languageKey: StorageService.getLanguage(),
                        onComplete: () {
                          final genderStr = SetupDraft.instance.playerGender;
                          setState(() {
                            _playerGenderIndex = genderStr == '女' ? 1 : 0;
                          });
                          _pageController.animateToPage(
                            4,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                        onBack: () {
                          _pageController.animateToPage(
                            2,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                      // 第4页：搭档设定（性别 + 姓名 + 特质）
                      CharacterSetupPage(
                        playerGenderIndex: _playerGenderIndex,
                        languageKey: StorageService.getLanguage(),
                        onComplete: () {
                          setState(() {
                            // 审核通过 → 进入设置确认页（step 5）
                            _setupStep = 5;
                            showMenuNotifier.value = false;
                          });
                        },
                        onBack: () {
                          _pageController.animateToPage(
                            3,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    ],
                  ),
                )
              : _setupStep == 5
              ? KeyedSubtree(
                  key: const ValueKey('setup_confirmation'),
                  child: SetupConfirmationPage(
                    onEdit: _onEditSetting,
                    onConfirmed: _onSetupConfirmed,
                    onBack: () => _onEditSetting(4),
                  ),
                )
              : KeyedSubtree(
                  key: const ValueKey('main_content'),
                  child: _startupSyncing
                      ? _buildSyncLoading()
                      : _startupSyncError != null
                      ? _buildSyncError()
                      : SingleChildScrollView(
                          controller: _scrollController,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 顶部预留空白区（约 1/4 屏）：仅当服务器还有更早内容
                              // （_storyStartIndex>0）时才提供“上拉加载更早内容”的区域，
                              // 图标居中；已到小说开头（_storyStartIndex==0，如新用户首篇）不显示。
                              if (_storyStartIndex > 0)
                                SizedBox(
                                  height: _earlierPullHeight,
                                  child: _downloadingEarlier
                                      ? const Center(
                                          child: CupertinoActivityIndicator(
                                            radius: 14,
                                          ),
                                        )
                                      : null,
                                ),
                              ..._buildStoryBody(),
                                    // 输入框隐藏时保留其占位空间，避免正文文字位置跳动
                                    Visibility(
                                      visible: _storyInputsVisible,
                                      maintainSize: true,
                                      maintainAnimation: true,
                                      maintainState: true,
                                      maintainInteractivity: false,
                                      child: Column(
                                        children: [
                                          const SizedBox(height: 12),
                                          TextInputPanel(
                                            placeholder:
                                                _getFirstInputPlaceholder(),
                                            confirmText:
                                                _getLatestContinueButtonText(),
                                            buttonBelow: true,
                                            disabled: _storyStreaming,
                                            onConfirm: _onInput1Confirm,
                                            onChanged: (v) =>
                                                _inputChoice1 = v,
                                          ),
                                          const SizedBox(height: 12),
                                          TextInputPanel(
                                            placeholder:
                                                _getInputPlaceholder(),
                                            confirmText:
                                                _getLatestContinueButtonText(),
                                            buttonBelow: true,
                                            disabled: _storyStreaming,
                                            onConfirm: _onInput2Confirm,
                                            onChanged: (v) =>
                                                _inputChoice2 = v,
                                          ),
                                          const SizedBox(height: 12),
                                          TextInputPanel(
                                            placeholder:
                                                _getInputPlaceholder(),
                                            confirmText:
                                                _getLatestContinueButtonText(),
                                            buttonBelow: true,
                                            disabled: _storyStreaming,
                                            onConfirm: _onInputConfirm,
                                            onChanged: (v) =>
                                                _inputChoice3 = v,
                                          ),
                                          const SizedBox(height: 24),
                                        ],
                                      ),
                                    ),
                                    // “正在生成/续写”提示：置于按钮下方
                                    if (_generating && _storyTexts.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          left: 16,
                                          right: 16,
                                          top: 8,
                                          bottom: 12,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            const CupertinoActivityIndicator(
                                              radius: 10,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(_getTypingIndicatorText()),
                                          ],
                                        ),
                                      ),
                            ],
                          ),
                        ),
                ),
        ),
        // 设置完成后的黑屏过渡：全黑 → 渐渐点亮；生成中显示加载提示
        if (_blackoutActive)
          Positioned.fill(
            child: FadeTransition(
              opacity: Tween<double>(
                begin: 1.0,
                end: 0.0,
              ).animate(_blackoutController),
              child: ColoredBox(
                color: CupertinoColors.black,
                child: _generating
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                              radius: 14,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _getGeneratingWorldText(),
                              style: const TextStyle(
                                color: CupertinoColors.white,
                              ),
                            ),
                          ],
                        ),
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  /// 设置确认页"编辑"快捷按钮：跳回对应设置页。
  void _onEditSetting(int index) {
    setState(() {
      _setupStep = index;
      showMenuNotifier.value = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  /// 设置确认页倒计时结束：将草稿统一写入持久化存储，把用户设定发送到服务器，
  /// 由网关转发 Dify 生成小说正文；成功后进入正式主页面显示生成文本。
  /// 全黑过渡期间若仍在生成，则显示加载提示。
  Future<void> _onSetupConfirmed({int retryDepth = 0}) async {
    await SetupDraft.instance.commit();
    if (!mounted) return;

    setState(() {
      _generating = true;
      _storyTexts.clear();
      _storyStartIndex = 0; // 全新生成：绝对下标从 0 开始（服务器同步清空旧段）
      _storyAbortReason = null;
      // 重新生成：从数组开头展示，新内容均为本会话流式生成
      _visibleStartIndex = 0;
      _sessionStreamStartIndex = 0;
      _blackoutActive = true;
      _blackoutController.value = 0; // 覆盖层完全不透明（全黑）
      _storyStreaming = true; // 接收正文中：隐藏下方输入框
      _storyTyped = false;
      _storyReceivedCompletely = false; // 本次正文尚未完整接收
    });
    // 记录本次生成开始前的段数（已清空为 0）：断流出错时据此丢弃未传完的内容
    final int preStreamLen = _storyTexts.length;
    // 本次生成是否收到过非空正文（LLM 返回空白时用于弹窗警告）
    bool hadContent = false;

    // 流式：服务器先审首段，通过后 chunk 开始打字；剩余全审后 reveal 一次性显示
    try {
      // 设定不再单独上传服务器：仅在第一轮生成时随请求一并发送，随小说正文落库
      await StoryService.generateStoryStream(
        location: SetupDraft.instance.location,
        era: SetupDraft.instance.era,
        playerName: SetupDraft.instance.playerName,
        playerGender: SetupDraft.instance.playerGender,
        partnerName: SetupDraft.instance.partnerName,
        partnerGender: SetupDraft.instance.partnerGender,
        partnerTraits: SetupDraft.instance.partnerTraits,
        language: StorageService.getLanguage(),
        onDeviceConflict: _onDeviceConflict,
        onStalled: _onStreamStalled,
        onChunk: (text) {
          if (!mounted) return;
          if (text.trim().isNotEmpty) hadContent = true;
          setState(() {
            if (_storyTexts.isEmpty) {
              // 首次生成：正文存入数组下标 0
              _storyTexts.add(text);
            } else {
              _storyTexts[_storyTexts.length - 1] += text;
            }
            _generating = false;
            _setupStep = 6;
            showMenuNotifier.value = true;
            _blackoutActive = false;
            _blackoutController.value = 1;
            _storyTyped = false; // 文本仍在增长：尚未彻底显示完成
          });
        },
        onReveal: (text, outputs) {
          if (!mounted) return;
          if (text.trim().isNotEmpty) hadContent = true;
          // 剩余部分不再一次性显示，由打字机以不断加速的方式接续打出
          setState(() {
            if (_storyTexts.isEmpty) {
              _storyTexts.add(text);
            } else {
              _storyTexts[_storyTexts.length - 1] += text;
            }
            _generating = false;
            _blackoutActive = false;
            _blackoutController.value = 1;
            _storyTyped = false; // 文本仍在增长：尚未彻底显示完成
          });
        },
        onAbort: (reason) {
          if (!mounted) return;
          setState(() {
            _storyAbortReason = reason;
            _generating = false;
            _setupStep = 6;
            showMenuNotifier.value = true;
            _blackoutActive = false;
            _blackoutController.value = 1;
            _storyStreaming = false;
            _storyTyped = true; // 正文被中止：恢复显示输入框以便继续
          });
        },
        onError: (message, {code}) {
          if (!mounted) return;
          setState(() {
            // 流未完整结束（未收到 done）：丢弃本次未传完的内容，
            // 避免半截文本进入主页面/被误判为完整正文
            if (_storyTexts.length > preStreamLen) {
              _storyTexts.removeRange(preStreamLen, _storyTexts.length);
            }
            _generating = false;
            _blackoutActive = false;
            _storyStreaming = false;
            _storyTyped = true;
          });
          // 服务器未返回有效正文（如额度用尽）：按当前语言提示检查额度
          _showGenerateError(
            code == 'empty_output' ? _getQuotaWarningText() : message,
          );
        },
        onDone: (outputs) async {
          if (!mounted) return;
          if (!hadContent) {
            // 本次未收到任何有效正文（如 LLM 额度用尽返回空白）：结束加载状态并弹窗警告
            setState(() {
              if (_storyTexts.length > preStreamLen) {
                _storyTexts.removeRange(preStreamLen, _storyTexts.length);
              }
              _generating = false;
              _storyStreaming = false;
              _storyTyped = true;
            });
            _showGenerateError(_getQuotaWarningText());
            return;
          }
          setState(() {
            _storyStreaming = false; // 正文已全部接收完成
            _storyReceivedCompletely = true; // 已完整接收：放行继续续写
          });
          await StorageService.saveMainTextList(List.of(_storyTexts));
          await StorageService.saveMainTextStartIndex(_storyStartIndex);
        },
      );
    } on HardwareAccountLimitException {
      // 同硬件 24h 内切换账号过多：弹出英文警告，用户确认后退出 App
      if (!mounted) return;
      setState(() {
        _generating = false;
        _blackoutActive = false;
        _storyStreaming = false;
        _storyTyped = true;
      });
      await showAccountLimitWarning(context);
    } on AuthNotAuthorizedException {
      // 登录令牌/授权过期：引导重新授权后重试本次生成
      if (!mounted || retryDepth >= 2) {
        setState(() {
          _generating = false;
          _blackoutActive = false;
          _storyStreaming = false;
          _storyTyped = true;
        });
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      final reauthed = await _promptReAuth();
      if (!reauthed || !mounted) {
        setState(() {
          _generating = false;
          _blackoutActive = false;
          _storyStreaming = false;
          _storyTyped = true;
        });
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      // 已重新授权：重试
      await _onSetupConfirmed(retryDepth: retryDepth + 1);
      return;
    } catch (e) {
      // 其它注册/鉴权异常（如 IP 限流"注册过于频繁"）：展示具体原因
      if (!mounted) return;
      setState(() {
        _generating = false;
        _blackoutActive = false;
        _storyStreaming = false;
        _storyTyped = true;
      });
      _showGenerateError(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  // ---- 正文页面本地化：根据用户所选语言返回对应的界面文字 ----

  /// 第一个输入框的占位提示：以主角本人身份输入接下来的行动
  String _getFirstInputPlaceholder() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '您作為這本小說的主角本人，接下來想做什麼？您可以隨意輸入。';
      case 'yue':
        return '你係呢本小說嘅主角本人，跟住想做啲乜？你可以隨便輸入。';
      case 'en':
        return 'As the protagonist of this novel, what do you want to do next? You can type anything.';
      case 'es':
        return 'Como protagonista de esta novela, ¿qué quieres hacer a continuación? Puedes escribir lo que quieras.';
      case 'fr':
        return 'En tant que protagoniste de ce roman, que voulez-vous faire ensuite ? Vous pouvez saisir librement.';
      case 'de':
        return 'Als Protagonist dieses Romans: Was möchtest du als Nächstes tun? Du kannst frei eingeben.';
      case 'pt':
        return 'Como protagonista deste romance, o que você quer fazer a seguir? Você pode digitar o que quiser.';
      case 'ja':
        return 'この小説の主人公であるあなたは、次に何をしたいですか？自由に入力してください。';
      case 'ko':
        return '이 소설의 주인공인 당신은 다음에 무엇을 하고 싶나요? 자유롭게 입력하세요.';
      default:
        return '您作为这本小说的主角本人，想接下来做什么，您可以随意输入。';
    }
  }

  /// 其余输入框的占位提示
  String _getInputPlaceholder() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '輸入文字...';
      case 'en':
        return 'Type something...';
      case 'es':
        return 'Escribe algo...';
      case 'fr':
        return 'Saisissez du texte...';
      case 'de':
        return 'Text eingeben...';
      case 'pt':
        return 'Digite algo...';
      case 'ja':
        return '文字を入力...';
      case 'ko':
        return '문자 입력...';
      default:
        return '输入文字...';
    }
  }

  /// 正在续写提示
  String _getTypingIndicatorText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '正在續寫…';
      case 'en':
        return 'Continuing…';
      case 'es':
      case 'pt':
        return 'Continuando…';
      case 'fr':
        return 'Suite en cours…';
      case 'de':
        return 'Wird fortgesetzt…';
      case 'ja':
        return '続きを書いています…';
      case 'ko':
        return '이어서 작성 중…';
      default:
        return '正在续写…';
    }
  }

  /// 黑屏过渡中"正在生成"提示
  String _getGeneratingWorldText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '正在生成你的世界…';
      case 'yue':
        return '正在生成你嘅世界…';
      case 'en':
        return 'Creating your world…';
      case 'es':
        return 'Creando tu mundo…';
      case 'fr':
        return 'Création de votre monde…';
      case 'de':
        return 'Deine Welt wird erschaffen…';
      case 'pt':
        return 'Criando seu mundo…';
      case 'ja':
        return 'あなたの世界を生成中…';
      case 'ko':
        return '당신의 세계를 생성 중…';
      default:
        return '正在生成你的世界…';
    }
  }

  /// 生成失败弹窗标题
  String _getErrorTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '生成失敗';
      case 'en':
        return 'Generation Failed';
      case 'es':
        return 'Error de Generación';
      case 'fr':
        return 'Échec de la Génération';
      case 'de':
        return 'Generierung fehlgeschlagen';
      case 'pt':
        return 'Falha na Geração';
      case 'ja':
        return '生成に失敗しました';
      case 'ko':
        return '생성 실패';
      default:
        return '生成失败';
    }
  }

  /// 生成失败弹窗内容
  String _getErrorMessageText(String detail) {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '無法生成小說內容：$detail\n\n是否重試？';
      case 'yue':
        return '無法生成小說內容：$detail\n\n係咪重試？';
      case 'en':
        return 'Unable to generate the story: $detail\n\nRetry?';
      case 'es':
        return 'No se pudo generar la historia: $detail\n\n¿Reintentar?';
      case 'fr':
        return "Impossible de générer l'histoire : $detail\n\nRéessayer ?";
      case 'de':
        return 'Die Geschichte konnte nicht erstellt werden: $detail\n\nErneut versuchen?';
      case 'pt':
        return 'Não foi possível gerar a história: $detail\n\nTentar novamente?';
      case 'ja':
        return '物語を生成できませんでした：$detail\n\n再試行しますか？';
      case 'ko':
        return '이야기를 생성할 수 없습니다: $detail\n\n다시 시도하시겠습니까?';
      default:
        return '无法生成小说内容：$detail\n\n是否重试？';
    }
  }

  /// 服务器返回空白正文时的额度警告（本地化，不出现 LLM 字样）
  String _getQuotaWarningText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '伺服器未回傳有效的小說正文，請檢查額度是否已用盡，或稍後重試';
      case 'en':
        return 'The server did not return valid story content. Please check whether your quota is exhausted, or try again later.';
      case 'es':
        return 'El servidor no devolvió contenido de la historia válido. Verifique si su cuota se agotó, o inténtelo de nuevo más tarde.';
      case 'fr':
        return "Le serveur n'a pas renvoyé de contenu d'histoire valide. Vérifiez si votre quota est épuisé, ou réessayez plus tard.";
      case 'de':
        return 'Der Server hat keinen gültigen Story-Inhalt zurückgegeben. Bitte prüfen Sie, ob Ihr Kontingent aufgebraucht ist, oder versuchen Sie es später erneut.';
      case 'pt':
        return 'O servidor não retornou conteúdo de história válido. Verifique se sua cota foi esgotada ou tente novamente mais tarde.';
      case 'ja':
        return 'サーバーが有効な小説本文を返しませんでした。割り当てが尽きていないか確認して、後でもう一度お試しください。';
      case 'ko':
        return '서버가 유효한 소설 본문을 반환하지 않았습니다. 할당량이 소진되었는지 확인하고 나중에 다시 시도해 주세요.';
      default:
        return '服务器未返回有效的小说正文，请检查额度是否已用尽，或稍后重试';
    }
  }

  /// 生成失败弹窗"跳过"按钮
  String _getSkipText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '跳過';
      case 'en':
        return 'Skip';
      case 'es':
        return 'Omitir';
      case 'fr':
        return 'Passer';
      case 'de':
        return 'Überspringen';
      case 'pt':
        return 'Pular';
      case 'ja':
        return 'スキップ';
      case 'ko':
        return '건너뛰기';
      default:
        return '跳过';
    }
  }

  /// 生成失败弹窗"重试"按钮
  String _getRetryText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重試';
      case 'en':
        return 'Retry';
      case 'es':
        return 'Reintentar';
      case 'fr':
        return 'Réessayer';
      case 'de':
        return 'Erneut versuchen';
      case 'pt':
        return 'Tentar Novamente';
      case 'ja':
        return '再試行';
      case 'ko':
        return '다시 시도';
      default:
        return '重试';
    }
  }

  /// "用户选择："前缀（本地化）
  String _getChoicePrefixText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '用戶選擇：';
      case 'yue':
        return '你揀咗：';
      case 'en':
        return 'Your choice: ';
      case 'es':
        return 'Tu elección: ';
      case 'fr':
        return 'Votre choix : ';
      case 'de':
        return 'Deine Wahl: ';
      case 'pt':
        return 'Sua escolha: ';
      case 'ja':
        return 'あなたの選択：';
      case 'ko':
        return '당신의 선택: ';
      default:
        return '用户选择：';
    }
  }

  /// 最新的三个输入框对应按钮文字：按照上面输入指引继续故事选择（本地化）
  String _getLatestContinueButtonText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '按照上面輸入指引繼續故事選擇';
      case 'yue':
        return '跟住上面嘅輸入指引繼續故事選擇';
      case 'en':
        return 'Continue the story following the guidance above';
      case 'es':
        return 'Continúa la historia siguiendo las indicaciones de arriba';
      case 'fr':
        return 'Continuez l\'histoire selon les consignes ci-dessus';
      case 'de':
        return 'Setze die Geschichte gemäß den obigen Anweisungen fort';
      case 'pt':
        return 'Continue a história seguindo as orientações acima';
      case 'ja':
        return '上記の入力ガイドに従って物語を続ける';
      case 'ko':
        return '위 입력 안내에 따라 이야기를 계속하기';
      default:
        return '按照上面输入指引继续故事选择';
    }
  }

  /// 历史段落选择卡片按钮文字：从这里重新开始（本地化）
  String _getRestartHereButtonText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '從這裡重新開始';
      case 'yue':
        return '由呢度重新開始';
      case 'en':
        return 'Restart from here';
      case 'es':
        return 'Reiniciar desde aquí';
      case 'fr':
        return 'Recommencer à partir d\'ici';
      case 'de':
        return 'Von hier neu starten';
      case 'pt':
        return 'Recomeçar daqui';
      case 'ja':
        return 'ここからやり直す';
      case 'ko':
        return '여기서부터 다시 시작하기';
      default:
        return '从这里重新开始';
    }
  }

  /// 历史段落"从这里重新开始"占位：未来在此实现"返回该时间点/重开"功能
  void _onRestartHerePressed() {
    // TODO: 时间树返回功能（当前为占位，点击暂不跳转）
  }

  /// 服务器判定本机已不是活跃设备（检测到多设备同时登入）：
  /// 弹出警告，用户同意后重启本 App，以重新登记活跃设备并同步小说。
  Future<void> _onDeviceConflict() async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        title: Text(_getDeviceConflictTitleText()),
        content: Text(_getDeviceConflictMessageText()),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_getDeviceConflictConfirmText()),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // 用户同意：优雅重启本 App（重建整棵树 → 重新走同步门禁 →
    // 重新激活本设备并拉取最新小说，本设备成为活跃设备）
    RestartWidget.restartApp(context);
  }

  /// "多设备同时登入"警告标题（本地化）
  String _getDeviceConflictTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '偵測到多裝置同時登入';
      case 'en':
        return 'Multiple Devices Detected';
      default:
        return '检测到多设备同时登入';
    }
  }

  /// "多设备同时登入"警告内容（本地化）
  String _getDeviceConflictMessageText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '您似乎有兩個以上的裝置在同時登入本 App。為保持小說同步，本 App 需要重新啟動。';
      case 'yue':
        return '你似乎有兩個以上嘅裝置同時登入呢個 App。為咗保持小說同步，呢個 App 需要重新啟動。';
      case 'en':
        return 'It looks like this App is signed in on more than one device at the same time. To keep your story in sync, this App needs to restart.';
      default:
        return '您似乎有两个以上的设备在同时登入本 App。为保持小说同步，本 App 需要重新启动。';
    }
  }

  /// "多设备同时登入"警告确认按钮文字（本地化）
  String _getDeviceConflictConfirmText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '同意';
      case 'en':
        return 'OK';
      default:
        return '同意';
    }
  }

  /// 冷启动同步进行中的加载界面
  Widget _buildSyncLoading() {
    return SizedBox.expand(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 14),
            const SizedBox(height: 12),
            Text(_getSyncingText(), style: const TextStyle(fontSize: 15)),
          ],
        ),
      ),
    );
  }

  /// 冷启动同步失败的错误界面（提供重试）
  Widget _buildSyncError() {
    return SizedBox.expand(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _getSyncErrorMessageText(_startupSyncError ?? ''),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1.4),
              ),
              const SizedBox(height: 16),
              CupertinoButton.filled(
                onPressed: _performStartupSync,
                child: Text(_getRetryText()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "正在同步"提示文字（本地化）
  String _getSyncingText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '正在同步…';
      case 'en':
        return 'Syncing…';
      default:
        return '正在同步…';
    }
  }

  /// 同步失败提示文字（本地化）
  String _getSyncErrorMessageText(String detail) {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '同步失敗，暫時無法開始。請檢查網路後重試。\n($detail)';
      case 'en':
        return 'Sync failed. Please check your network and try again.\n($detail)';
      default:
        return '同步失败，暂时无法开始。请检查网络后重试。\n($detail)';
    }
  }

  /// 流式卡死（30 秒未收到任何数据且未完成）：网络可能有问题，
  /// 为保证小说文本完整，弹出警告并强制用户重启本 App，重启后重新拉取完整数据。
  Future<void> _onStreamStalled() async {
    if (!mounted) return;
    setState(() {
      _generating = false;
      _storyStreaming = false;
      _storyTyped = true;
      // _storyReceivedCompletely 保持 false：禁止基于残缺文本续写
    });
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        title: Text(_getStallTitleText()),
        content: Text(_getStallMessageText()),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_getStallRestartText()),
          ),
        ],
      ),
    );
    if (!mounted) return;
    RestartWidget.restartApp(context);
  }

  /// "网络异常"警告标题（本地化）
  String _getStallTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '網路異常';
      case 'en':
        return 'Network Issue';
      default:
        return '网络异常';
    }
  }

  /// "网络异常"警告内容（本地化）
  String _getStallMessageText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '為保證小說文本完整，請檢查網路後重新啟動本 App。';
      case 'yue':
        return '為咗保證小說文本完整，請檢查網路後重新啟動呢個 App。';
      case 'en':
        return 'To keep your story text complete, please check your network and restart this App.';
      default:
        return '为保证小说文本完整，请检查网络后重新启动本 App。';
    }
  }

  /// "网络异常"警告重启按钮文字（本地化）
  String _getStallRestartText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重新啟動';
      case 'en':
        return 'Restart';
      default:
        return '重启';
    }
  }

  /// 生成失败弹窗：重试重新走一次生成，跳过则用默认文本直接进入主页面。
  Future<void> _showGenerateError(String detail) async {
    final retry = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(_getErrorTitleText()),
        content: Text(_getErrorMessageText(detail)),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_getSkipText()),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_getRetryText()),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (retry == true) {
      await _onSetupConfirmed();
      return;
    }
    // 跳过：用当前默认文本直接进入正式主页面
    setState(() {
      _setupStep = 6;
      showMenuNotifier.value = true;
      _blackoutActive = true;
      _blackoutController.value = 0;
    });
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    await _blackoutController.forward();
    if (!mounted) return;
    setState(() {
      _blackoutActive = false;
    });
  }
}
