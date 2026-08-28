import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart' show SystemChrome, SystemUiOverlayStyle;
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

/// 包裹子组件并在其尺寸变化（含首次布局）时回调报告当前尺寸。
///
/// 与 `SizeChangedLayoutNotifier` 不同：直接通过回调回传尺寸，无需 GlobalKey。
/// 它**恒定**包裹每个打字机段落（不随"是否最新段"增删），因此段落交接时不会
/// 改变打字机所在位置的组件类型，不会重建/打断打字机状态，避免打字机从错误
/// 位置重新开始打字；同时打字机逐字长高时能实时上报高度，用于同步缩小预留空白。
class _SizeReporting extends SingleChildRenderObjectWidget {
  const _SizeReporting({required this.onSizeChanged, required super.child});

  final ValueChanged<Size> onSizeChanged;

  @override
  _RenderSizeReporting createRenderObject(BuildContext context) {
    return _RenderSizeReporting(onSizeChanged);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReporting renderObject,
  ) {
    renderObject.onSizeChanged = onSizeChanged;
  }
}

class _RenderSizeReporting extends RenderProxyBox {
  _RenderSizeReporting(this.onSizeChanged);

  ValueChanged<Size> onSizeChanged;
  Size? _lastSize;

  @override
  void performLayout() {
    super.performLayout();
    if (_lastSize != size) {
      _lastSize = size;
      onSizeChanged(size);
    }
  }
}

/// 用于控制菜单按钮显示/隐藏的通知器
final ValueNotifier<bool> showMenuNotifier = ValueNotifier<bool>(true);

/// 是否正在生成小说正文（流式进行中）的通知器。
/// 用于让右上角菜单按钮在生成期间禁用并给出视觉提示，生成完成后恢复可点击。
final ValueNotifier<bool> storyStreamingNotifier = ValueNotifier<bool>(false);

/// 【进入世界动画】右上角菜单按钮的不透明度（0=黑屏期间隐藏，1=正常）。
/// 新用户首次生成时，菜单按钮随"渐亮"阶段与屏幕一起淡入，不破坏全黑沉浸。
final ValueNotifier<double> menuRevealNotifier = ValueNotifier<double>(1.0);

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
  final _CompensatingScrollController _scrollController =
      _CompensatingScrollController();
  late final PageController _pageController;

  /// 0=语言选择, 1=地点设定, 2=年代设定, 3=主角设定,
  /// 4=设置确认页, 5=正式主页面
  int _setupStep = 0;

  /// 最近一次确认的语言（用于检测语言变化，从而重置后续设置页）
  String _confirmedLanguage = '';

  /// 设置完成后进入正式主页前的黑屏过渡动画控制器
  late final AnimationController _blackoutController;

  /// 是否正在显示"进入你的世界"过渡动画（4s 渐黑 → 6s 文字渐显渐隐 → 1s 全黑 → 4s 渐亮）
  bool _blackoutActive = false;

  /// 进入世界动画第 6 秒（已全黑）把 `_setupStep` 切到正式主页面：此刻黑屏稳定完全不透明，
  /// AnimatedSwitcher 对设置确认页的交叉淡出被黑屏盖住（设置页不闪回）。
  Timer? _transitionStepTimer;

  /// 进入世界动画期间是否已把系统栏设为深色，以及进入前按日/夜间模式记录，用于恢复
  bool _blackoutBarsDark = false;
  bool _blackoutBarsApplied = false;

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

  /// 是否正在接收/生成正文（流式进行中）
  bool _storyStreaming = false;

  /// 正文是否已由打字机彻底显示完成：完成后恢复显示下方输入框
  bool _storyTyped = true;

  /// 用户选择节点：正文中"用户选择：xxx" + 时间树返回占位按钮
  final List<_ChoiceRecord> _choices = [];

  /// 每段对应的三个选项（choice_1/2/3）：键为绝对下标（= 服务器 seq），
  /// 由启动同步 / 上拉加载时与正文一起从服务器拉取，显示在对应段落的按钮/输入框中。
  final Map<int, List<String>> _segmentChoices = {};

  /// 每段对应的脚本序号（"脚本id-章节"，如 "2-5"）：键为绝对下标（= 服务器 seq），
  /// 由启动同步 / 上拉加载时从服务器拉取，用于判断某段是否为一个脚本的最后一章。
  final Map<int, String> _segmentScriptIds = {};

  /// 本轮三个输入框的当前值（任一确认时随请求一并上传，作为本轮选择一/二/三快照）
  String _inputChoice1 = '';
  String _inputChoice2 = '';
  String _inputChoice3 = '';

  /// 第 2、3 个输入框的外部控制器：收到服务器推荐选择（choice_2/3，LLM② 推荐的两项行动）后预填。
  /// 第 1 个输入框是用户自由输入：无控制器、不预填，仅显示自由输入提示占位。
  final TextEditingController _choice2Ctrl = TextEditingController();
  final TextEditingController _choice3Ctrl = TextEditingController();

  /// 是否已收到本轮的推荐选择（choice_1/2/3）：没收到就不显示输入框
  bool _hasRecommendedActions = false;

  /// 是否已把"下方输入区"激活显示过：一旦激活（首轮收到推荐后 / 老用户启动预填后），
  /// 后续生成期间保持可见（仅灰化禁用），不再随流式阶段消失。
  bool _storyInputsShown = false;

  /// 本轮生成开始前的正文段数：生成期间若正文段数未超过它，说明新内容尚未到达，
  /// 用于在末尾显示"半屏空白 + 生成提示"占位。
  int _generationStartLen = 0;

  /// 当前流式新段（打字机正在打、仍在增长）的实测高度：用于把"生成区预留空白"
  /// 同步缩小，使"新正文增长 ↔ 预留空白缩小"的总高度保持不变，
  /// 彻底消除开始打字时的一次显示跳动。
  final ValueNotifier<double> _streamedSegmentHeight = ValueNotifier<double>(0);

  /// 生成区"正在生成"提示行的实测高度：开始打字后提示行消失，其高度并入预留
  /// 空白，使提示消失的同时总高度保持不变（不会因此再产生一次跳动）。
  final GlobalKey _streamingPromptKey = GlobalKey();
  double _streamingPromptHeight = 0;

  /// 续写起点段"时间树"卡片的实测高度：开始打字时该卡片在正文中正常出现，其高度
  /// 并入预留空白，使卡片出现的同时总高度保持不变（不会引起跳动，正文中也不留空白）。
  final GlobalKey _cardMeasureKey = GlobalKey();
  double _cardMeasureHeight = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    // 新/老用户判定以服务器为准：所有用户冷启动都先到服务器验证身份。
    // - 服务器上存有小说正文（story_segments 有记录）→ 老用户
    //   （含安卓/苹果老用户换新设备：账号稳定，仍能识别出有历史正文）；
    // - 服务器上没有存储任何小说正文 → 新用户，从头（语言页）重新开始设置。
    // 先进入主内容分支显示"同步/验证中"页面，同步完成后按服务器数据决定去向。
    _setupStep = 5;
    showMenuNotifier.value = true;
    _startupSyncing = true;
    _performStartupSync();
    // 记录当前已选语言，用于检测后续用户是否切换语言
    _confirmedLanguage = StorageService.getLanguage();

    _pageController = PageController(
      initialPage: _setupStep < 2 ? _setupStep : 0,
    );

    _blackoutController = AnimationController(
      vsync: this,
      // 进入世界动画总时长：4s 渐黑 + 6s 文字渐显渐隐 + 1s 全黑 + 4s 渐亮 = 15s
      duration: const Duration(milliseconds: 15000),
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
    _blackoutController.removeListener(_onBlackoutTick);
    _blackoutController.dispose();
    _transitionStepTimer?.cancel();
    _restoreSystemBars();
    _choice2Ctrl.dispose();
    _choice3Ctrl.dispose();
    _streamedSegmentHeight.dispose();
    super.dispose();
  }

  /// 滚动监听：向上滚动到顶部时，若仍有更早的内容则平滑加载到当前内容上方
  void _onScroll() {
    if (!_scrollController.hasClients || _loadingPrevious) return;
    // 已在最顶部且还有更早内容（内存未揭示完或服务器还有更早段）时才加载
    if (_visibleStartIndex <= 0 && _storyStartIndex <= 0) return;
    final double pixels = _scrollController.position.pixels;
    // 内存中还有更早段：用户一上滑（进入顶部预留区、还没到顶）就一次性揭示全部，
    // 让更早内容立即出现，避免"上滑→空等→到顶才出内容"的卡顿感。
    if (_visibleStartIndex > 0) {
      if (pixels < _earlierPullHeight) {
        _loadPreviousSegment();
      }
      return;
    }
    // 内存已揭示完：需上滑到最顶部（预留区顶部）才从服务器拉取更早内容
    if (pixels <= 0) {
      // 防止一次上滑/上移动画触发连发多批拉取：短时间内不重复请求服务器
      if (DateTime.now().difference(_lastServerLoad).inMilliseconds < 800) {
        return;
      }
      _loadPreviousSegment();
    }
  }

  /// 把更早的文本段加载到当前内容上方，并补偿滚动偏移，
  /// 使当前视野内容保持不动（"平滑"衔接不跳动）。
  Future<void> _loadPreviousSegment() async {
    if (_loadingPrevious) return;

    // 1) 内存中仍有更早的段：一次性全部揭示（不请求服务器）。
    //    与服务器批量拉取后"整批渲染"一致，避免一段一段揭示造成
    //    "上滑到顶 → 停一下 → 再上滑"的卡顿感。
    if (_visibleStartIndex > 0) {
      _loadingPrevious = true;
      // 上插前先武装同帧补偿：布局阶段按实际新增高度同步修正滚动偏移，
      // 使当前视野内的正文保持静止（"下方静止、上方长出内容"，无闪帧）。
      _scrollController.armCompensation();
      setState(() {
        _visibleStartIndex = 0; // 一次性揭示全部内存中的更早段
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
        // 记录新加载段对应的三个选项（与正文一起从服务器拉取，显示在对应按钮中）
        for (int i = 0; i < earlier.segments.length; i++) {
          _segmentChoices[earlier.startSeq + i] = (i < earlier.choices.length
              ? earlier.choices[i]
              : const <String>[]);
          _segmentScriptIds[earlier.startSeq + i] =
              (i < earlier.scriptIds.length ? earlier.scriptIds[i] : '');
        }
        // 恢复这批更早段的"用户本轮实际选择"节点（前插，保持按段序升序；未选择为空）
        final newChoices = <_ChoiceRecord>[];
        for (int i = 0; i < earlier.segments.length; i++) {
          final uc = i < earlier.userChoices.length
              ? earlier.userChoices[i]
              : '';
          if (uc.trim().isNotEmpty) {
            newChoices.add(
              _ChoiceRecord(
                text: uc,
                segmentIndex: earlier.startSeq + i,
                startOffset: 0,
              ),
            );
          }
        }
        _choices.insertAll(0, newChoices);
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
      // 服务器是否有小说正文 = 是否老用户（服务器权威判定）
      final isOldUser = snap.segments.isNotEmpty;
      // 老用户（含安卓/苹果换新设备）：用服务器上的金标准语言覆盖本地默认语言，并永久存储
      if (isOldUser && snap.language.isNotEmpty) {
        await StorageService.saveLanguage(snap.language);
      }
      setState(() {
        if (isOldUser) {
          // 老用户（服务器存有小说正文）：用服务器数据重建正文，进入主内容
          _storyTexts
            ..clear()
            ..addAll(snap.segments);
          _storyStartIndex = snap.startSeq;
          // 记录每段对应的三个选项（与正文一起从服务器拉取，显示在对应按钮中）
          _segmentChoices.clear();
          _segmentScriptIds.clear();
          for (int i = 0; i < snap.segments.length; i++) {
            _segmentChoices[_storyStartIndex + i] = (i < snap.choices.length
                ? snap.choices[i]
                : const <String>[]);
            _segmentScriptIds[_storyStartIndex + i] = (i < snap.scriptIds.length
                ? snap.scriptIds[i]
                : '');
          }
          // 恢复每段对应的"用户本轮实际选择"节点（跨重启持久；未选择为空）
          _choices.clear();
          for (int i = 0; i < snap.segments.length; i++) {
            final uc = i < snap.userChoices.length ? snap.userChoices[i] : '';
            if (uc.trim().isNotEmpty) {
              _choices.add(
                _ChoiceRecord(
                  text: uc,
                  segmentIndex: _storyStartIndex + i,
                  startOffset: 0,
                ),
              );
            }
          }
          if (_storyTexts.isNotEmpty) {
            _sessionStreamStartIndex = _storyTexts.length;
            _visibleStartIndex = _storyTexts.length - 1;
          }
          // 用最新一段的推荐选择（choice_2/3）预填第 2、3 个输入框；
          // 第 1 个输入框保持空白（自由输入，不预填）
          if (snap.choices.isNotEmpty) {
            final lastChoices = snap.choices.last;
            final c2 = lastChoices.length > 1 ? lastChoices[1] : '';
            final c3 = lastChoices.length > 2 ? lastChoices[2] : '';
            _choice2Ctrl.text = c2;
            _inputChoice2 = c2;
            _choice3Ctrl.text = c3;
            _inputChoice3 = c3;
          }
          // 推荐选择已就绪：标记为已有并激活输入区，最新段输入框可显示
          _hasRecommendedActions = true;
          _storyInputsShown = true;
          _setupStep = 5;
        } else {
          // 新用户（服务器没有任何小说正文）：从语言页重新开始设置
          SetupDraft.instance.reset();
          _storyInputsShown = false; // 尚无输入区：等首轮生成后再激活
          _setupStep = 0;
          showMenuNotifier.value = false;
        }
        _startupSyncing = false;
        _startupSyncError = null;
      });
      if (isOldUser) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            // 重启回到正文页：让最后一段文本的首行顶到屏幕最上方。
            // 有"上拉加载更早"空白区（_storyStartIndex>0）时跳过该空白区，
            // 否则回到顶部；内容不足一屏时 maxScrollExtent 为 0，落在 0 即可。
            final double target = _storyStartIndex > 0
                ? _earlierPullHeight
                : 0.0;
            final double max = _scrollController.position.maxScrollExtent;
            _scrollController.jumpTo(target > max ? max : target);
          }
        });
      }
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
        _startupSyncError = _localizeNetworkError(e);
      });
      await _showStartupSyncErrorDialog();
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
      await _showStartupSyncErrorDialog();
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
      case 'es':
        return 'Inicio de sesión incompleto. Inicie sesión de nuevo e inténtelo de nuevo.';
      case 'fr':
        return 'Connexion incomplète. Veuillez vous reconnecter et réessayer.';
      case 'de':
        return 'Anmeldung unvollständig. Bitte melden Sie sich erneut an und versuchen Sie es noch einmal.';
      case 'pt':
        return 'Login incompleto. Faça login novamente e tente de novo.';
      case 'ja':
        return 'ログインが完了していません。もう一度ログインしてお試しください。';
      case 'ko':
        return '로그인이 완료되지 않았습니다. 다시 로그인하여 시도해 주세요.';
      default:
        return '登录未完成，无法继续。请重新登录后重试。';
    }
  }

  /// 把常见的网络异常（Socket/Client/Timeout）转成当前语言的提示，
  /// 避免弹窗里出现"葡语标题 + 英文异常"这类语言混用。
  String _localizeNetworkError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('TimeoutException')) {
      return StorageService.localizedText(
        zhCN: '无法连接服务器，请检查网络后重试',
        zhTW: '無法連接伺服器，請檢查網路後重試',
        en: 'Unable to connect to the server. Please check your network and try again.',
        yue: '無法連接伺服器，請檢查網路後再試',
        es: 'No se pudo conectar con el servidor. Compruebe su red e inténtelo de nuevo.',
        fr: 'Impossible de se connecter au serveur. Vérifiez votre réseau et réessayez.',
        de: 'Keine Verbindung zum Server möglich. Bitte prüfen Sie Ihr Netzwerk und versuchen Sie es erneut.',
        pt: 'Não foi possível conectar ao servidor. Verifique sua rede e tente novamente.',
        ja: 'サーバーに接続できません。ネットワークを確認して、もう一度お試しください。',
        ko: '서버에 연결할 수 없습니다. 네트워크를 확인하고 다시 시도해 주세요.',
      );
    }
    return e.toString();
  }

  /// 占位回调（LightAuthPage 授权完成后由 push 返回值触发重试）。
  static void _dummyAuthComplete() {}

  /// 是否显示正文下方的三个输入框：
  /// - 已有正文且输入区已激活（_storyInputsShown）：保持可见；
  /// - 生成/接收中：保持可见，但输入框与按钮置灰禁用（不消失、不可输入/点击）；
  /// - 正文彻底显示完成（收到 done）或违规中止：可见、可输入；
  /// - 尚无正文（首次生成前）或输入区尚未激活：隐藏。
  bool get _storyInputsVisible =>
      _storyTexts.isNotEmpty &&
      _storyInputsShown &&
      // 新一段生成中/打字未完成：先不显示其输入框。
      // 注意 _storyTyped 会在"首段450字打完、reveal 后半段还没来"时短暂为 true，
      // 所以必须同时要求 _storyStreaming 已结束（收到 done）才显示，避免闪烁。
      (_storyTexts.length <= _generationStartLen ||
          (_storyTyped && !_storyStreaming));

  /// 顶部“上拉加载更早内容”空白区高度：约屏幕的 1/4，旋转图标居中。
  double get _earlierPullHeight {
    final h = MediaQuery.of(context).size.height;
    return (h / 4).clamp(80.0, 280.0);
  }

  void _onInput1Confirm(String text) => _continueStory(text);

  void _onInput2Confirm(String text) => _continueStory(text);

  void _onInputConfirm(String text) => _continueStory(text);

  /// 收到服务器返回的后续变量后，把两个推荐选择（choice_2/3，LLM② 推荐的两项行动）
  /// 分别填入第 2、3 个输入框（覆盖上一轮的旧推荐）；LLM 未返回正常值时由服务器
  /// 兜底行动填入。第 1 个输入框保持空白，仅显示"自由输入"提示，由用户自行输入。
  /// 收到任一推荐即标记 _hasRecommendedActions。
  void _applyRecommendedActions(Map<String, dynamic> outputs) {
    final choice1 = outputs['choice_1'] as String? ?? '';
    final choice2 = outputs['choice_2'] as String? ?? '';
    final choice3 = outputs['choice_3'] as String? ?? '';
    final got = choice2.isNotEmpty || choice3.isNotEmpty;
    if (!mounted) return;
    setState(() {
      if (got) {
        _hasRecommendedActions = true;
        _storyInputsShown = true; // 收到推荐即激活输入区（此后生成期间保持可见灰化）
      }
      if (choice2.isNotEmpty && choice2 != _inputChoice2) {
        _choice2Ctrl.text = choice2;
        _inputChoice2 = choice2;
      }
      if (choice3.isNotEmpty && choice3 != _inputChoice3) {
        _choice3Ctrl.text = choice3;
        _inputChoice3 = choice3;
      }
      // 保存最新一段的 choice_1/2/3 快照（与服务器保存一致），
      // 使该段成为历史段后其输入框能显示"生成那一刻"的推荐/选项文本。
      if (_storyTexts.isNotEmpty) {
        final int lastAbs = _storyStartIndex + _storyTexts.length - 1;
        _segmentChoices[lastAbs] = [choice1, choice2, choice3];
      }
    });
  }

  /// 任一输入框确认后：把输入作为 user_input，连同用户设定请求续写生成，
  /// 新内容在屏幕上接力显示（作为 _storyTexts 数组的新元素，由打字机继续揭示）。
  Future<void> _continueStory(
    String userInput, {
    int retryDepth = 0,
    int? rewriteFrom,
    String? choice1,
    String? choice2,
    String? choice3,
  }) async {
    if (!mounted || userInput.trim().isEmpty) return;
    // 记录本次续写开始前的段数：断流出错时据此丢弃未传完的段落
    final int preStreamLen = _storyTexts.length;
    // 新一段内容是否已作为数组新元素创建（每次续写独占一个数组元素）
    bool segmentStarted = false;
    // 本次续写是否收到过非空正文（LLM 返回空白时用于弹窗警告）
    bool hadContent = false;
    setState(() {
      _storyStreaming = true;
      storyStreamingNotifier.value = true;
      _storyTyped = false;
      _hasRecommendedActions = false; // 本轮尚未收到推荐选择前不显示输入框
      _generationStartLen = _storyTexts.length; // 记录本轮生成前的段数（用于"新内容未到达"占位）
      _streamedSegmentHeight.value = 0; // 新一段流式正文从 0 高度开始重新测量
      _streamingPromptHeight = 0; // 提示行高度重新测量（开始打字后并入预留空白）
      _cardMeasureHeight = 0; // 续写起点段卡片高度重新测量（打字开始后并入预留空白）
      // 记录用户选择节点：属于"用户操作的那段"（普通续写=最新段；时间树=被重写段）。
      // 每次点击"继续"都用本次输入覆盖该段的旧选择（时间树重写同样覆盖段 k）。
      final int choiceSegAbs = _storyStartIndex + _storyTexts.length - 1;
      _choices.removeWhere((c) => c.segmentIndex == choiceSegAbs);
      _choices.add(
        _ChoiceRecord(
          text: userInput.trim(),
          segmentIndex: choiceSegAbs,
          startOffset: 0,
        ),
      );
      // 保存本轮三个输入框当前值到该段（与服务器 choice_1/2/3 覆盖一致），
      // 使该段成为历史段后其输入框显示"用户选择那一瞬间"的文本。
      // 注意：时间树"从这里重写"时 choice1/2/3 参数携带的是被重写段的正确选项
      // （由 StoryChoiceCard 传入），而全局 _inputChoice1/2/3 仍保留着删除前
      // 最新段的选项——必须优先用参数，否则会把最新段的选项错误覆盖到重写点
      // （只影响 App 内存显示；服务器端存的是正确值，重启后回读才正确）。
      _segmentChoices[choiceSegAbs] = [
        choice1 ?? _inputChoice1,
        choice2 ?? _inputChoice2,
        choice3 ?? _inputChoice3,
      ];
      // 时间树"从这里重写"：被重写段现在是"最新一段"，其选项改由页面底部三个输入框
      // 显示。把全局输入框同步为该段选项，避免残留删除前最新段的选项。
      if (rewriteFrom != null) {
        _inputChoice1 = choice1 ?? '';
        _inputChoice2 = choice2 ?? '';
        _inputChoice3 = choice3 ?? '';
        _choice2Ctrl.text = _inputChoice2;
        _choice3Ctrl.text = _inputChoice3;
      }
    });
    // 点击继续后：平滑下移半屏，为即将生成的新内容预留空白区（顶部提示 + 空白）。
    // 用 animateTo 平滑滚动（不用 jumpTo 的瞬间跳转），让上方正文与输入按钮平滑上拉、
    // 下方空白区域逐渐打开，避免"屏幕一下子跳上去"的跳跃感。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final double half = MediaQuery.of(context).size.height / 2;
      final double max = _scrollController.position.maxScrollExtent;
      final double target = (_scrollController.offset + half).clamp(0.0, max);
      if ((target - _scrollController.offset).abs() < 1.0) return;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    });
    try {
      await StoryService.generateStoryStream(
        userInput: userInput,
        // 时间树"从这里重新开始"时传入被重写段的三个输入值；否则用最新输入框的值
        choice1: choice1 ?? _inputChoice1,
        choice2: choice2 ?? _inputChoice2,
        choice3: choice3 ?? _inputChoice3,
        rewriteFrom: rewriteFrom,
        onDeviceConflict: _onDeviceConflict,
        onStalled: _onStreamStalled,
        // 【调试】服务器调 Dify 前先把 payload 发回 App 弹窗，确认后才放行
        onDebugPayload: (payload, requestId) {
          _showDebugPayloadDialog(payload, requestId);
        },
        onChunk: (text) {
          if (!mounted) return;
          if (text.trim().isNotEmpty) hadContent = true;
          setState(() {
            if (!segmentStarted) {
              // 新一段内容：单独存入数组新元素（每段自带卡片与间距，不再加空行前缀）
              _storyTexts.add(text);
              segmentStarted = true;
              // 新段从 0 高度重新测量（尺寸上报组件会在其首次布局后自动上报实际
              // 高度，使底部预留空白立即按新段高度同步缩小，消除打字开始时的跳动）
              _streamedSegmentHeight.value = 0;
            } else {
              _storyTexts[_storyTexts.length - 1] += text;
            }
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
              // 新段从 0 高度重新测量（尺寸上报组件会在其首次布局后自动上报实际
              // 高度，使底部预留空白立即按新段高度同步缩小，消除打字开始时的跳动）
              _streamedSegmentHeight.value = 0;
            } else {
              _storyTexts[_storyTexts.length - 1] += text;
            }
            _storyTyped = false; // 文本仍在增长：尚未彻底显示完成
          });
          _applyRecommendedActions(outputs);
        },
        onAbort: (_) {
          if (!mounted) return;
          // 违规中止：弹窗期间保持当前流式布局（用户选择 + 残缺段 + 预留空白）在
          // 弹窗背后原样冻结，不在弹窗前改动任何布局状态；弹窗关闭后再删掉本次
          // 可能已由打字机打出的残缺段落、恢复等待输入状态，避免弹窗背后的页面跳动
          // （在弹窗前删段/切"生成区"分支会让按钮弹出、选择文本与按钮错位）。
          _showViolationDialog().then((_) {
            if (!mounted) return;
            setState(() {
              if (_storyTexts.length > preStreamLen) {
                _storyTexts.removeRange(preStreamLen, _storyTexts.length);
              }
              _storyTyped = true;
              _storyStreaming = false; // 弹窗关闭后恢复等待输入状态
              storyStreamingNotifier.value = false;
            });
          });
        },
        onError: (message, {code}) {
          if (!mounted) return;
          // 流失败：不在此处改动任何正文布局状态——弹窗（重启 App）前保持当前流式
          // 布局（用户选择 + 按钮 + 预留空白）在弹窗背后原样冻结。若在弹窗前删除
          // 残缺段落/切换"生成区"分支，会让输入按钮突然弹出、用户选择文本与按钮
          // 错位、按钮贴到屏幕下沿，弹窗瞬间页面剧烈跳动；弹窗关闭后 App 重启，
          // 由启动同步重新拉取并对齐（残缺段落自然丢弃）。
          _showGenerateError(
            code == 'empty_output' ? _getQuotaWarningText() : message,
          );
        },
        onDone: (outputs) async {
          if (!mounted) return;
          // 【诊断】done 到达（续写轮）——判断"收到 done 但按钮未恢复"
          debugPrint(
            '[home] onDone #1 hadContent=$hadContent '
            'hasActions=$_hasRecommendedActions',
          );
          if (!hadContent) {
            // 本次未收到任何有效正文（如 LLM 额度用尽返回空白）：不在弹窗前改动
            // 布局状态——保持当前流式布局在弹窗背后原样冻结（见 onError 说明），
            // 弹窗关闭后 App 重启，由启动同步重新拉取并对齐（空段落自然丢弃）。
            _showGenerateError(_getQuotaWarningText());
            return;
          }
          setState(() {
            _storyStreaming = false; // 正文已全部接收完成
            storyStreamingNotifier.value = false;
          });
          _applyRecommendedActions(outputs);
          if (!_hasRecommendedActions) {
            // 没收到可选项：用和正文一样的网络警告并提示重启（重启后重拉可取回已落库的可选项）
            await _onStreamStalled();
            return;
          }
          // 【调试】弹窗打印数据库最新一条落库内容，确认后继续
          await _showLatestDbRowDebugDialog();
        },
      );
    } on HardwareAccountLimitException {
      // 同硬件 24h 内切换账号过多：弹出英文警告，用户确认后退出 App
      if (!mounted) return;
      setState(() {
        // 保持 _storyStreaming=true：弹窗期间正文布局不变，弹窗确认后退出 App
        _storyTyped = true;
      });
      await showAccountLimitWarning(context);
    } on AuthNotAuthorizedException {
      // 登录令牌/授权过期：引导重新授权后重试本次续写（不重复记录选择节点）
      if (!mounted || retryDepth >= 2) {
        setState(() {
          // 保持 _storyStreaming=true：弹窗期间正文布局不变
          _storyTyped = true;
        });
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      final reauthed = await _promptReAuth();
      if (!reauthed || !mounted) {
        setState(() {
          // 保持 _storyStreaming=true：弹窗期间正文布局不变
          _storyTyped = true;
        });
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      // 已重新授权：重试
      await _continueStory(
        userInput,
        retryDepth: retryDepth + 1,
        rewriteFrom: rewriteFrom,
        choice1: choice1,
        choice2: choice2,
        choice3: choice3,
      );
      return;
    } catch (e) {
      // 其它注册/鉴权异常（如 IP 限流"注册过于频繁"）：展示具体原因
      if (!mounted) return;
      setState(() {
        // 保持 _storyStreaming=true：弹窗期间正文布局不变，弹窗关闭后重启重置状态
        _storyTyped = true;
      });
      _showGenerateError(
        _localizeNetworkError(e).replaceFirst('Exception: ', ''),
      );
    }
  }

  /// 该段是否为一个脚本的"最后一章"（脚本切换点）：
  /// - 下一段存在且属于不同脚本 → 本段是其所在脚本的最后一章；
  /// - 没有下一段（整本最后一段）→ 仅当本段是"空章节"（章节号 > 20）才视为最后一章。
  bool _isScriptLast(int absSeq) {
    String _scriptOf(String s) {
      final i = s.indexOf('-');
      return i < 0 ? s : s.substring(0, i);
    }

    final cur = _segmentScriptIds[absSeq];
    if (cur == null || cur.isEmpty) return false;
    final next = _segmentScriptIds[absSeq + 1];
    if (next != null && next.isNotEmpty) {
      return _scriptOf(next) != _scriptOf(cur);
    }
    final parts = cur.split('-');
    if (parts.length == 2) {
      final chapter = int.tryParse(parts[1]) ?? 0;
      return chapter > 20;
    }
    return false;
  }

  /// 构建正文区：按数组顺序逐段渲染故事文本（打字机揭示），
  /// 逐段渲染故事正文；每段统一按"段文本 → 该段输入框按钮（历史段卡片）→
  /// 该段之后用户所做的选择标记"排列，位置与"点击按钮生成新文本时占位区顶部"
  /// 一致（即下一段正文之前），保证各段生成位置统一。
  List<Widget> _buildStoryBody() {
    // 违规中止改由 onAbort 弹"内容违规，请重新输入提示词"对话框处理；
    // 正文区直接渲染已有正文（本次残缺段已被删除），输入框恢复等待用户输入。
    final List<Widget> children = [];
    final bool streaming = _storyStreaming;
    // 本次流式是否已创建出"正在打字的流式新段"（位于数组末尾）
    final bool hasStreamingSegment =
        streaming && _storyTexts.length > _generationStartLen;
    // 只渲染 [ _visibleStartIndex, _storyTexts.length ) 范围内的文本段，
    // 更早的历史段等用户向上滚动到顶部时才逐个加载
    // 脚本最后一章的段落文本已并入下一段（连续文本框），跳过下一段的独立文本渲染
    bool skipText = false;
    for (
      int segIndex = _visibleStartIndex;
      segIndex < _storyTexts.length;
      segIndex++
    ) {
      final segment = _storyTexts[segIndex];
      final bool isLast = segIndex == _storyTexts.length - 1;
      // 流式新段（数组末尾、尚未定稿的正在生成段）：其卡片与选择标记都交给
      // 底部"生成区"承接，正文内不渲染，避免打字开始时突然增删造成跳动。
      final bool isStreamingSegment =
          hasStreamingSegment && segIndex == _storyTexts.length - 1;
      // 本次会话流式生成的新段用打字机揭示；重启恢复的历史段直接完整显示
      final useTypewriter = segIndex >= _sessionStreamStartIndex;
      final int segAbs = _storyStartIndex + segIndex;
      // 该段是否"脚本最后一章"：仅历史段（非本会话打字机段）才判定。
      // 此类段落不显示选项卡片，并把本段与下一段文本合并到一个连续文本框显示。
      final bool scriptLast =
          !isStreamingSegment && !useTypewriter && _isScriptLast(segAbs);
      // 1) 段文本：脚本最后一章时把下一段文本一并拼入同一文本框（连续显示，不分段）
      String displayText = segment;
      bool mergedNext = false;
      if (!skipText && scriptLast && segIndex + 1 < _storyTexts.length) {
        displayText = '$segment\n\n${_storyTexts[segIndex + 1]}';
        mergedNext = true;
      }
      if (!skipText) {
        children.add(
          useTypewriter
              ? _buildStorySegment(
                  displayText,
                  isLast: isLast,
                  segIndex: segIndex,
                )
              : CharacterText(text: displayText),
        );
      }
      skipText = mergedNext; // 下一段文本已并入本段，跳过其独立渲染
      // 2) 历史段落（非最新一段）下方：三个输入框 + "从这里重新开始"按钮（时间树）。
      //    与原始逻辑一致：最新一段下方不插入卡片，其下方的输入框由页面底部的三个承载。
      //    流式新段（数组末尾）即"最新一段"，故自动不渲染卡片；打字开始时它出现
      //    造成的高度变化由底部"生成区"的预留空白吸收，正文中不会留下空白。
      //    脚本最后一章：无配套选项，也不渲染卡片。
      final bool renderCard =
          !isStreamingSegment &&
          segIndex < _storyTexts.length - 1 &&
          !scriptLast;
      if (renderCard) {
        children.add(
          StoryChoiceCard(
            // 绝对下标 = 服务器 seq：让本段按钮 ↔ 文本 ↔ 数据库行一一对应
            segmentIndex: segAbs,
            // 显示本段对应的三个选项（choice_1/2/3，即用户选择那一瞬间保存的文本）
            initialValues: _segmentChoices[segAbs] ?? const <String>[],
            buttonText: _getRestartHereButtonText(),
            inputPlaceholder: _getInputPlaceholder(),
            // 三个输入框的占位提示与正文底部一致（第 1 个=自由输入，第 2/3 个=推荐行动）
            placeholders: [
              _getFirstInputPlaceholder(),
              _getRecommendedActionPlaceholder(),
              _getRecommendedActionPlaceholder(),
            ],
            // 历史按钮只在"流结束且整段打字完成"后可操作；
            // 首段450字打完时 _storyTyped 会短暂为 true，须同时要求 !_storyStreaming 避免闪烁
            enabled: _storyTyped && !_storyStreaming,
            onPressed: _onRestartHerePressed,
          ),
        );
      }
      // 3) 该段的选择标记（用户在该段输入框选择，属于该段）：
      //    统一显示在本段文本 + 输入框按钮（历史段卡片）下方，与最终布局一致。
      //    流式新段的选择不在此显示；等待期（新段未到）最新一段的选择改由底部
      //    "生成区"在输入框与按钮下方显示（原始布局位置），此处不重复。
      //    脚本最后一章：不显示提示与选择标记。
      final bool skipChoice =
          isStreamingSegment ||
          scriptLast ||
          (_storyStreaming &&
              _storyTexts.length <= _generationStartLen &&
              segIndex == _storyTexts.length - 1);
      if (!skipChoice) {
        for (int i = 0; i < _choices.length; i++) {
          if (_choices[i].segmentIndex == segAbs) {
            // 在输入框/按钮卡片与"用户选择"文本之间恒留一行空行（与生成等待期的
            // 间距一致），避免打字开始时空行突然消失造成屏幕跳动。
            children.add(const SizedBox(height: 24));
            children.add(
              StoryChoiceMarker(
                prefix: _getChoicePrefixText(),
                text: _choices[i].text,
              ),
            );
            break;
          }
        }
      }
    }
    return children;
  }

  /// 流式生成期的底部"生成区"（位于输入区下方）：
  /// - 新内容未到达时：显示"正在生成新内容"提示 + 半屏预留空白，并离屏测量
  ///   提示行与续写起点段卡片的高度（供打字开始后并入预留空白）；
  /// - 收到正文后（开始打字）：提示行消失、续写起点段卡片在正文中出现，两者的
  ///   高度都并入预留空白，预留空白再随流式新段实测高度同步缩小（新段每长高
  ///   1px、空白就减 1px），使底部总高度在打字过程中保持不变，彻底消除开始打字
  ///   时的一次显示跳动，正文中也不留下任何空白。
  Widget _buildStreamingArea() {
    final double half = MediaQuery.of(context).size.height / 2;
    final bool hasNewSegment = _storyTexts.length > _generationStartLen;
    if (!hasNewSegment) {
      // 续写起点段（segK）的绝对下标（用于离屏渲染其卡片以测量高度）
      final int cardAbs = _storyStartIndex + _generationStartLen - 1;
      // 新内容尚未到达：测量提示行高度与续写起点段卡片高度
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final double ph = _streamingPromptKey.currentContext?.size?.height ?? 0;
        final double ch = _cardMeasureKey.currentContext?.size?.height ?? 0;
        final bool phChanged =
            ph > 0 && (ph - _streamingPromptHeight).abs() > 0.5;
        final bool chChanged = ch > 0 && (ch - _cardMeasureHeight).abs() > 0.5;
        if (phChanged || chChanged) {
          setState(() {
            if (phChanged) _streamingPromptHeight = ph;
            if (chChanged) _cardMeasureHeight = ch;
          });
        }
      });
      final String? currentChoice = _choices.isEmpty
          ? null
          : _choices.last.text;
      final bool hasChoice =
          currentChoice != null && currentChoice.trim().isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 本轮用户选择：显示在（底部）输入框与按钮下方，等待新内容时保持原位；
          // 顶部间距与正文中"卡片 → 用户选择"之间的一行空行保持一致。
          if (hasChoice)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: StoryChoiceMarker(
                prefix: _getChoicePrefixText(),
                text: currentChoice,
              ),
            ),
          Padding(
            key: _streamingPromptKey,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CupertinoActivityIndicator(radius: 10),
                const SizedBox(width: 8),
                Text(_getGeneratingNewContentText()),
              ],
            ),
          ),
          SizedBox(height: half),
          // 离屏渲染续写起点段的卡片以测量其高度（不占布局空间、不显示）
          Offstage(
            offstage: true,
            child: StoryChoiceCard(
              key: _cardMeasureKey,
              segmentIndex: cardAbs,
              initialValues: _segmentChoices[cardAbs] ?? const <String>[],
              buttonText: _getRestartHereButtonText(),
              inputPlaceholder: _getInputPlaceholder(),
              enabled: false,
            ),
          ),
        ],
      );
    }
    // 新内容已开始打字：提示行消失、续写起点段卡片出现，两者高度并入预留空白，
    // 空白随新段高度缩小 → 总高度保持恒定、无跳动。
    final double reserve = _streamingPromptHeight + half - _cardMeasureHeight;
    return ValueListenableBuilder<double>(
      valueListenable: _streamedSegmentHeight,
      builder: (context, segH, _) {
        final double blank = (reserve - segH).clamp(0.0, double.infinity);
        return SizedBox(height: blank);
      },
    );
  }

  /// 构建单个故事文本段（打字机揭示；仅最后一段触发 onTypingDone）。
  /// 每个打字机段落都**恒定**包一层 [_SizeReporting]：打字机逐字长高时实时上报
  /// 高度（用于把底部预留空白同步缩小，总高度不变、无跳动）；由于恒定包裹，
  /// 段落交接（新段出现、旧段变为历史段）不会改变该位置的组件类型，打字机状态
  /// 得以保留，不会从错误位置重新开始打字。
  Widget _buildStorySegment(
    String text, {
    required bool isLast,
    required int segIndex,
  }) {
    final Widget typewriter = TypewriterText(
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
    return _SizeReporting(
      onSizeChanged: (size) => _onSegmentSizeChanged(segIndex, size.height),
      child: typewriter,
    );
  }

  /// 报告某段落的实测高度：仅当它是"正在打字的流式新段"（数组末尾那段）时，
  /// 用其高度更新底部预留空白；非流式段的尺寸变化一律忽略。
  void _onSegmentSizeChanged(int segIndex, double height) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_storyStreaming || _storyTexts.length <= _generationStartLen) return;
      if (segIndex != _storyTexts.length - 1) return;
      if ((height - _streamedSegmentHeight.value).abs() > 0.5) {
        _streamedSegmentHeight.value = height;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 占满整屏的透明占位：Stack 的尺寸等于其最大的非定位子组件，
        // 若正文内容较矮，AnimatedSwitcher 会收缩、导致 Positioned.fill 的黑屏
        // 覆盖层只盖住上半屏。放一个整屏占位可强制本 Stack 恒为整屏，
        // 保证"进入你的世界"黑屏过渡期间始终覆盖整屏。
        const SizedBox.expand(),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: const Cubic(0.22, 1.0, 0.36, 1.0),
          switchOutCurve: const Cubic(0.22, 1.0, 0.36, 1.0),
          // 顶部对齐：避免切换时新页面（如设置确认页）先被垂直居中、旧页淡出后
          // 再回弹到顶部，造成"先偏下、再上移一行"的跳动。
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              alignment: Alignment.topCenter,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: (Widget child, Animation<double> animation) {
            // 设置页之间（含 主角设定 → 设置总览）用"左拉"滑动切换，
            // 与 PageView 内各页的左右滑动一致，取代原来的淡入淡出（弹出）效果。
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1.0, 0.0), // 新页面从右侧滑入（视觉上整页左移）
                end: Offset.zero,
              ).animate(animation),
              child: child,
            );
          },
          child: _setupStep < 4
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
                      // 第3页：主角设定（姓名 + 特质）
                      PlayerSetupPage(
                        languageKey: StorageService.getLanguage(),
                        onComplete: () {
                          setState(() {
                            // 主角设定完成 → 进入设置确认页（step 4）
                            _setupStep = 4;
                            showMenuNotifier.value = false;
                          });
                        },
                        onBack: () {
                          _pageController.animateToPage(
                            2,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    ],
                  ),
                )
              : _setupStep == 4
              ? KeyedSubtree(
                  key: const ValueKey('setup_confirmation'),
                  child: SetupConfirmationPage(
                    onEdit: _onEditSetting,
                    onConfirmed: _onSetupConfirmed,
                    onBack: () => _onEditSetting(3),
                  ),
                )
              : KeyedSubtree(
                  key: const ValueKey('main_content'),
                  child: (_startupSyncing || _startupSyncError != null)
                      ? _buildSyncLoading()
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
                                      placeholder: _getFirstInputPlaceholder(),
                                      confirmText:
                                          _getLatestContinueButtonText(),
                                      buttonBelow: true,
                                      disabled: _storyStreaming,
                                      onConfirm: _onInput1Confirm,
                                      onChanged: (v) => _inputChoice1 = v,
                                    ),
                                    const SizedBox(height: 12),
                                    TextInputPanel(
                                      placeholder:
                                          _getRecommendedActionPlaceholder(),
                                      confirmText:
                                          _getLatestContinueButtonText(),
                                      buttonBelow: true,
                                      disabled: _storyStreaming,
                                      controller: _choice2Ctrl,
                                      onConfirm: _onInput2Confirm,
                                      onChanged: (v) => _inputChoice2 = v,
                                    ),
                                    const SizedBox(height: 12),
                                    TextInputPanel(
                                      placeholder:
                                          _getRecommendedActionPlaceholder(),
                                      confirmText:
                                          _getLatestContinueButtonText(),
                                      buttonBelow: true,
                                      disabled: _storyStreaming,
                                      controller: _choice3Ctrl,
                                      onConfirm: _onInputConfirm,
                                      onChanged: (v) => _inputChoice3 = v,
                                    ),
                                    const SizedBox(height: 24),
                                  ],
                                ),
                              ),
                              // 新内容生成中：在输入区下方显示"正在生成新内容"提示 +
                              // 逐步缩小的预留空白（见 _buildStreamingArea），
                              // 使打字开始时总高度保持不变、无显示跳动。
                              if (_storyStreaming && _generationStartLen > 0)
                                _buildStreamingArea(),
                            ],
                          ),
                        ),
                ),
        ),
        // "进入你的世界"动画覆盖层：4s 渐黑 → 6s 文字渐显渐隐 → 1s 全黑 → 4s 渐亮。
        // 不显示任何等待旋转圈/加载提示，纯黑 + 提示文字。
        if (_blackoutActive)
          Positioned(
            // 覆盖到整屏（含状态栏/安全区）：黑屏过渡期间不露出系统栏/边缘亮条
            left: -MediaQuery.of(context).padding.left,
            top: -MediaQuery.of(context).padding.top,
            right: -MediaQuery.of(context).padding.right,
            bottom: 0,
            child: AnimatedBuilder(
              animation: _blackoutController,
              builder: (context, _) {
                final double v = _blackoutController.value; // 0..1，共 15s
                // 黑屏不透明度：0-4/15（4s）渐入全黑；4/15-11/15（7s）保持全黑；
                // 11/15-1（4s）渐亮。
                // 注意：transform 入参必须 clamp 到 [0,1]——动画末尾 v=1 或 t=1 时，
                // 除减法的浮点精度会算出 1.0000000000000002 / -2.2e-16 这类越界值，
                // Curves.easeInOut.transform 会断言失败，在 debug 模式整屏闪红。
                final double blackOpacity;
                if (v <= 4 / 15) {
                  blackOpacity = Curves.easeInOut.transform(
                    (v / (4 / 15)).clamp(0.0, 1.0),
                  );
                } else if (v <= 11 / 15) {
                  blackOpacity = 1.0;
                } else {
                  blackOpacity =
                      1 -
                      Curves.easeInOut.transform(
                        ((v - 11 / 15) / (4 / 15)).clamp(0.0, 1.0),
                      );
                }
                // 提示文字不透明度：仅 4/15-2/3（6s）内先渐显、再渐隐。
                double textOpacity = 0.0;
                if (v >= 4 / 15 && v <= 2 / 3) {
                  final double t = (v - 4 / 15) / (2 / 5);
                  if (t < 0.3) {
                    textOpacity = Curves.easeInOut.transform(
                      (t / 0.3).clamp(0.0, 1.0),
                    );
                  } else if (t <= 0.7) {
                    textOpacity = 1.0;
                  } else {
                    textOpacity = Curves.easeInOut.transform(
                      (1 - (t - 0.7) / 0.3).clamp(0.0, 1.0),
                    );
                  }
                }
                return Opacity(
                  opacity: blackOpacity,
                  child: ColoredBox(
                    color: CupertinoColors.black,
                    child: Center(
                      child: Opacity(
                        opacity: textOpacity,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            _getEnteringWorldText(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 18,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
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
  /// 由网关转发 Dify 生成小说正文；同时启动"进入你的世界"动画
  /// （4s 渐黑 → 6s 文字渐显渐隐 → 1s 全黑 → 4s 渐亮），期间 LLM 照常生成，
  /// 动画结束后显示正式主页面中的生成文本。
  Future<void> _onSetupConfirmed({int retryDepth = 0}) async {
    if (!mounted) return;
    // 重新生成时中止上一次可能残留的"进入你的世界"动画（取消切页计时、停止黑屏动画）
    _abortBlackoutTransition();

    setState(() {
      _storyTexts.clear();
      _generationStartLen = _storyTexts.length; // 全新生成：0
      _storyStartIndex = 0; // 全新生成：绝对下标从 0 开始（服务器同步清空旧段）
      // 重新生成：从数组开头展示，新内容均为本会话流式生成
      _visibleStartIndex = 0;
      _sessionStreamStartIndex = 0;
      _blackoutActive = true;
      _blackoutController.value = 0; // 动画起点：覆盖层透明（下方设置确认页可见）
      _storyStreaming = true;
      storyStreamingNotifier.value = true;
      _storyTyped = false;
      _hasRecommendedActions = false; // 本轮尚未收到推荐选择前不显示输入框
      _storyInputsShown = false; // 全新生成：输入区先隐藏，待首轮收到推荐后再激活
      _streamedSegmentHeight.value = 0; // 新正文从 0 高度开始测量
    });
    // 启动"进入你的世界"动画：4s 渐黑 → 6s 文字渐显渐隐 → 1s 全黑 → 4s 渐亮。
    // 期间 LLM 照常生成（onChunk 等只负责正文数据与打字机，不干预黑屏动画）。
    // 动画期间把系统状态栏/导航栏设为深色，避免纯黑背景下系统栏露出亮条。
    _applyBlackoutSystemBars();
    // 黑屏期间隐藏右上角菜单按钮，随"渐亮"阶段与屏幕一起淡入（不破坏全黑沉浸）
    menuRevealNotifier.value = 0.0;
    _blackoutController.addListener(_onBlackoutTick);
    _blackoutController.forward().whenComplete(() {
      if (!mounted) return;
      _blackoutController.removeListener(_onBlackoutTick);
      menuRevealNotifier.value = 1.0;
      _restoreSystemBars();
      setState(() {
        _blackoutActive = false;
      });
    });
    // 第 6 秒（已全黑）切入正式主页面：此刻黑屏已稳定完全不透明，AnimatedSwitcher
    // 对设置确认页的交叉淡出被盖住（设置页不闪回），随后渐亮直接露出正文。
    _transitionStepTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      setState(() {
        _setupStep = 5;
        showMenuNotifier.value = true;
      });
    });
    // 清理"漏网之鱼"：重置/设备切换后，另一设备的延迟写入可能在服务器残留旧正文。
    // 首次生成前静默清空服务器小说正文，确保新故事从 seq 0 干净开始。
    // 失败时静默忽略（残留最多导致起始下标不为 0，不阻塞生成流程）。
    try {
      await SyncService.resetStory();
    } catch (_) {
      // 静默失败：不阻塞生成
    }
    // 记录本次生成开始前的段数（已清空为 0）：断流出错时据此丢弃未传完的内容
    final int preStreamLen = _storyTexts.length;
    // 本次生成是否收到过非空正文（LLM 返回空白时用于弹窗警告）
    bool hadContent = false;

    // 流式：服务器每满 400 字增量审核，通过后 chunk 开始打字、后续 reveal 逐段追加
    try {
      // 设定不再单独上传服务器：仅在第一轮生成时随请求一并发送，随小说正文落库
      await StoryService.generateStoryStream(
        location: SetupDraft.instance.location,
        era: SetupDraft.instance.era,
        playerName: SetupDraft.instance.playerName,
        playerTraits: SetupDraft.instance.playerTraits,
        language: StorageService.getLanguage(),
        onDeviceConflict: _onDeviceConflict,
        onStalled: _onStreamStalled,
        // 【调试】服务器调 Dify 前先把 payload 发回 App 弹窗，确认后才放行
        onDebugPayload: (payload, requestId) {
          _showDebugPayloadDialog(payload, requestId);
        },
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
            // 只负责正文数据与打字机状态：页面切换与黑屏动画由"进入世界"动画统一驱动
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
            _storyTyped = false; // 文本仍在增长：尚未彻底显示完成
          });
          _applyRecommendedActions(outputs);
        },
        onAbort: (_) {
          if (!mounted) return;
          // 违规中止：删掉本次可能已由打字机打出的残缺段落，恢复等待输入状态，
          // 再弹"内容违规，请重新输入提示词"对话框（唯一"重新输入"按钮）
          setState(() {
            if (_storyTexts.length > preStreamLen) {
              _storyTexts.removeRange(preStreamLen, _storyTexts.length);
            }
            _setupStep = 5;
            showMenuNotifier.value = true;
            _storyStreaming = false;
            storyStreamingNotifier.value = false;
            _storyTyped = true;
          });
          _abortBlackoutTransition();
          _showViolationDialog();
        },
        onError: (message, {code}) {
          if (!mounted) return;
          setState(() {
            // 流未完整结束（未收到 done）：丢弃本次未传完的内容，
            // 避免半截文本进入主页面/被误判为完整正文
            if (_storyTexts.length > preStreamLen) {
              _storyTexts.removeRange(preStreamLen, _storyTexts.length);
            }
            _storyStreaming = false;
            storyStreamingNotifier.value = false;
            _storyTyped = true;
          });
          _abortBlackoutTransition();
          // 服务器未返回有效正文（如额度用尽）：按当前语言提示检查额度
          _showGenerateError(
            code == 'empty_output' ? _getQuotaWarningText() : message,
          );
        },
        onDone: (outputs) async {
          if (!mounted) return;
          // 【诊断】done 到达（首次生成）——判断"收到 done 但按钮未恢复"
          debugPrint(
            '[home] onDone #2 hadContent=$hadContent '
            'hasActions=$_hasRecommendedActions',
          );
          if (!hadContent) {
            // 本次未收到任何有效正文（如 LLM 额度用尽返回空白）：结束加载状态并弹窗警告
            setState(() {
              if (_storyTexts.length > preStreamLen) {
                _storyTexts.removeRange(preStreamLen, _storyTexts.length);
              }
              _storyStreaming = false;
              storyStreamingNotifier.value = false;
              _storyTyped = true;
            });
            _abortBlackoutTransition();
            _showGenerateError(_getQuotaWarningText());
            return;
          }
          setState(() {
            _storyStreaming = false; // 正文已全部接收完成
            storyStreamingNotifier.value = false;
          });
          _applyRecommendedActions(outputs);
          if (!_hasRecommendedActions) {
            // 没收到可选项：用和正文一样的网络警告并提示重启（重启后重拉可取回已落库的可选项）
            await _onStreamStalled();
            return;
          }
          // 【调试】弹窗打印数据库最新一条落库内容，确认后继续
          await _showLatestDbRowDebugDialog();
        },
      );
    } on HardwareAccountLimitException {
      // 同硬件 24h 内切换账号过多：弹出英文警告，用户确认后退出 App
      if (!mounted) return;
      setState(() {
        _storyStreaming = false;
        storyStreamingNotifier.value = false;
        _storyTyped = true;
      });
      _abortBlackoutTransition();
      await showAccountLimitWarning(context);
    } on AuthNotAuthorizedException {
      // 登录令牌/授权过期：引导重新授权后重试本次生成
      if (!mounted || retryDepth >= 2) {
        setState(() {
          _storyStreaming = false;
          storyStreamingNotifier.value = false;
          _storyTyped = true;
        });
        _abortBlackoutTransition();
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      final reauthed = await _promptReAuth();
      if (!reauthed || !mounted) {
        setState(() {
          _storyStreaming = false;
          storyStreamingNotifier.value = false;
          _storyTyped = true;
        });
        _abortBlackoutTransition();
        _showGenerateError(_getReauthRequiredText());
        return;
      }
      // 已重新授权：中止当前动画后重试（重新走完整进入世界动画）
      _abortBlackoutTransition();
      await _onSetupConfirmed(retryDepth: retryDepth + 1);
      return;
    } catch (e) {
      // 其它注册/鉴权异常（如 IP 限流"注册过于频繁"）：展示具体原因
      if (!mounted) return;
      setState(() {
        _storyStreaming = false;
        storyStreamingNotifier.value = false;
        _storyTyped = true;
      });
      _abortBlackoutTransition();
      _showGenerateError(
        _localizeNetworkError(e).replaceFirst('Exception: ', ''),
      );
    }
  }

  /// 黑屏动画每帧回调：在"渐亮"阶段（最后 4s，v 从 11/15 → 1）把右上角菜单按钮
  /// 的不透明度同步到内容亮度，随屏幕一起淡入。
  void _onBlackoutTick() {
    final double v = _blackoutController.value;
    final double t = ((v - 11 / 15) / (4 / 15)).clamp(0.0, 1.0);
    menuRevealNotifier.value = Curves.easeInOut.transform(t).clamp(0.0, 1.0);
  }

  /// 中止"进入你的世界"动画（出错/违规/卡死时立即结束黑屏，不再等完整 15s 走完）。
  /// 取消切页计时、停止黑屏动画、恢复系统栏样式，并移除黑屏覆盖层。
  void _abortBlackoutTransition() {
    _transitionStepTimer?.cancel();
    _transitionStepTimer = null;
    _blackoutController.removeListener(_onBlackoutTick);
    menuRevealNotifier.value = 1.0;
    if (_blackoutController.isAnimating) {
      _blackoutController.stop();
    }
    _restoreSystemBars();
    if (!mounted) return;
    setState(() {
      _blackoutActive = false;
    });
  }

  /// 进入世界动画期间把系统状态栏/导航栏设为深色（黑底浅图标），
  /// 避免纯黑背景下系统栏露出亮条；结束/中止时用 [_restoreSystemBars] 恢复。
  void _applyBlackoutSystemBars() {
    _blackoutBarsDark =
        CupertinoTheme.of(context).brightness == Brightness.dark;
    _blackoutBarsApplied = true;
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: CupertinoColors.black,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: CupertinoColors.black,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: CupertinoColors.black,
      ),
    );
  }

  /// 恢复进入动画前的系统栏样式（按记录的日/夜间模式）。
  void _restoreSystemBars() {
    if (!_blackoutBarsApplied) return;
    _blackoutBarsApplied = false;
    SystemChrome.setSystemUIOverlayStyle(
      _blackoutBarsDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    );
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

  /// 第 2/3 个输入框（LLM 推荐的两项行动）的占位提示：
  /// 正常流程里这两个框会被预填推荐/兜底行动，占位基本看不到；
  /// 当某个框为空时，用这行提示说明"这是可修改的推荐行动"。
  String _getRecommendedActionPlaceholder() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '推薦行動（可修改）';
      case 'en':
        return 'Recommended action (editable)';
      case 'es':
        return 'Acción recomendada (editable)';
      case 'fr':
        return 'Action recommandée (modifiable)';
      case 'de':
        return 'Empfohlene Aktion (bearbeitbar)';
      case 'pt':
        return 'Ação recomendada (editável)';
      case 'ja':
        return '推奨アクション（編集可）';
      case 'ko':
        return '추천 행동 (수정 가능)';
      default:
        return '推荐行动（可修改）';
    }
  }

  /// 新内容生成中提示（位于预留空白区顶部）
  String _getGeneratingNewContentText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '正在生成新內容…';
      case 'en':
        return 'Generating new content…';
      case 'es':
        return 'Generando nuevo contenido…';
      case 'fr':
        return 'Génération de nouveau contenu…';
      case 'de':
        return 'Neuer Inhalt wird generiert…';
      case 'pt':
        return 'Gerando novo conteúdo…';
      case 'ja':
        return '新しい内容を生成中…';
      case 'ko':
        return '새 콘텐츠를 생성하는 중…';
      default:
        return '正在生成新内容…';
    }
  }

  /// 全黑时显示的"即将进入你创造的世界"提示文字
  String _getEnteringWorldText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '即將進入您自己創造的、充滿了鬼命案以及愛的世界';
      case 'yue':
        return '即將進入您自己創造嘅、充滿咗鬼兇案同埋愛嘅世界';
      case 'en':
        return 'You are about to enter the world you created — a world of ghost murders and love';
      case 'es':
        return 'Estás a punto de entrar en el mundo que creaste, lleno de asesinatos fantasmales y amor';
      case 'fr':
        return "Vous êtes sur le point d'entrer dans le monde que vous avez créé, rempli de meurtres de fantômes et d'amour";
      case 'de':
        return 'Du bist dabei, die Welt zu betreten, die du erschaffen hast – voller Geistermorde und Liebe';
      case 'pt':
        return 'Você está prestes a entrar no mundo que criou, cheio de assassinatos fantasmagóricos e amor';
      case 'ja':
        return 'あなたが創り上げた、鬼の殺人事件と愛に満ちた世界へまもなく入ります';
      case 'ko':
        return '당신이 창조한 귀신 살인 사건과 사랑으로 가득한 세계로 곧 들어갑니다';
      default:
        return '即将进入您自己创造的、充满了鬼杀人事件以及爱的世界';
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

  /// 最新的三个输入框对应按钮文字：按照上面指引继续故事（本地化）
  String _getLatestContinueButtonText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '按照上面指引繼續故事';
      case 'yue':
        return '跟住上面嘅指引繼續故事';
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
        return '上記のガイドに従って物語を続ける';
      case 'ko':
        return '위 안내에 따라 이야기를 계속하기';
      default:
        return '按照上面指引继续故事';
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

  /// 历史段落"从这里重新开始"：用客户语言弹出确认窗口，警告从该段重写会永久废弃之后内容。
  /// 用户确认后：先截断该段之后的内容（显示/本地），再走与标准生成完全一致的流程，
  /// 从该时间点续写（服务器在生成时同步截断数据库）。
  Future<void> _onRestartHerePressed(
    int segmentIndex,
    String userInput,
    List<String> choices,
  ) async {
    if (!mounted) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        content: Text(_getRestartMessageText()),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(_getRestartCancelText()),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_getRestartConfirmText()),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    // 1) 输入框为空白时禁止继续：不允许在无用户指引的情况下
    //    仅凭时间树生成新小说内容（按钮在空白时已禁用，此处为兜底防御；
    //    必须在截断之前判断，避免空白输入破坏已有故事内容）
    if (userInput.trim().isEmpty) return;
    // 2) 先截断本段之后的内容：文本显示页 + App 本地存储
    await _truncateStoryFrom(segmentIndex);
    if (!mounted) return;
    // 3) 走标准生成流程从该时间点续写（服务器端同步截断数据库并续写）
    final input = userInput;
    // 把被重写段三个输入框当前值（用户可能已编辑）覆盖保存到服务器该段，并从此处续写
    await _continueStory(
      input,
      rewriteFrom: segmentIndex,
      choice1: choices.isNotEmpty ? choices[0] : '',
      choice2: choices.length > 1 ? choices[1] : '',
      choice3: choices.length > 2 ? choices[2] : '',
    );
  }

  /// 时间树"从这里重写"：截断该段之后的所有内容（内存数组 + 本地存储），
  /// 保留 0..segmentIndex（含该段）；服务器端在生成时同步截断数据库。
  Future<void> _truncateStoryFrom(int segmentIndex) async {
    final keepLocal = segmentIndex - _storyStartIndex; // 该段在本地数组中的下标
    if (keepLocal < 0 || keepLocal >= _storyTexts.length) return;
    setState(() {
      _storyTexts.removeRange(keepLocal + 1, _storyTexts.length);
      // 清除该段之后的选择节点与分段选项；
      // 段 segmentIndex 本身的选择保留，由后续 _continueStory 用本次输入覆盖（时间树=方案B）
      _choices.removeWhere((c) => c.segmentIndex > segmentIndex);
      _segmentChoices.removeWhere((k, _) => k > segmentIndex);
      _segmentScriptIds.removeWhere((k, _) => k > segmentIndex);
      _visibleStartIndex = _storyTexts.length - 1;
      _sessionStreamStartIndex = _storyTexts.length; // 之后的新段均为会话流式段（打字机）
    });
  }

  /// "从这里重新续写"确认弹窗内容（本地化）
  String _getRestartMessageText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '小說將從這一段重新續寫，其後已生成的內容將永久廢棄。確定要重寫嗎？';
      case 'yue':
        return '小說會由呢段重新續寫，之後已經生成嘅內容會永久作廢。係咪確定要重寫？';
      case 'en':
        return 'The story will be rewritten from this point, and all content generated after it will be permanently discarded. Continue?';
      case 'es':
        return 'La historia se reescribirá desde este punto y todo el contenido generado después se descartará permanentemente. ¿Continuar?';
      case 'fr':
        return 'L\'histoire sera réécrite à partir de ce point et tout le contenu généré ensuite sera définitivement supprimé. Continuer ?';
      case 'de':
        return 'Die Geschichte wird von diesem Punkt an neu geschrieben; der gesamte danach erzeugte Inhalt wird dauerhaft verworfen. Fortfahren?';
      case 'pt':
        return 'A história será reescrita a partir deste ponto e todo o conteúdo gerado depois será descartado permanentemente. Continuar?';
      case 'ja':
        return 'この地点から物語を書き直し、以降に生成された内容は永久に破棄されます。続行しますか？';
      case 'ko':
        return '이 지점부터 이야기를 다시 쓰면 이후 생성된 내용은 영구히 폐기됩니다. 계속할까요?';
      default:
        return '小说将从这段重新续写，其后面已经生成的内容将永久废弃。确定要重写吗？';
    }
  }

  /// "确认重写"按钮文字（本地化）
  String _getRestartConfirmText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '確認重寫';
      case 'yue':
        return '確認重寫';
      case 'en':
        return 'Rewrite';
      case 'es':
        return 'Reescribir';
      case 'fr':
        return 'Réécrire';
      case 'de':
        return 'Neu schreiben';
      case 'pt':
        return 'Reescrever';
      case 'ja':
        return '書き直す';
      case 'ko':
        return '다시 쓰기';
      default:
        return '确认重写';
    }
  }

  /// "放弃"按钮文字（本地化）
  String _getRestartCancelText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '放棄';
      case 'yue':
        return '放棄';
      case 'en':
        return 'Cancel';
      case 'es':
        return 'Cancelar';
      case 'fr':
        return 'Annuler';
      case 'de':
        return 'Abbrechen';
      case 'pt':
        return 'Cancelar';
      case 'ja':
        return 'やめる';
      case 'ko':
        return '취소';
      default:
        return '放弃';
    }
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
      case 'es':
        return 'Se detectaron varios dispositivos';
      case 'fr':
        return 'Plusieurs appareils détectés';
      case 'de':
        return 'Mehrere Geräte erkannt';
      case 'pt':
        return 'Vários dispositivos detectados';
      case 'ja':
        return '複数のデバイスを検出しました';
      case 'ko':
        return '여러 기기가 감지되었습니다';
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
      case 'es':
        return 'Parece que esta App inició sesión en más de un dispositivo al mismo tiempo. Para mantener sincronizada tu historia, esta App debe reiniciarse.';
      case 'fr':
        return 'Il semble que cette app soit connectée sur plus d\'un appareil en même temps. Pour garder votre histoire synchronisée, cette app doit redémarrer.';
      case 'de':
        return 'Diese App scheint gleichzeitig auf mehr als einem Gerät angemeldet zu sein. Um Ihre Geschichte synchron zu halten, muss diese App neu gestartet werden.';
      case 'pt':
        return 'Parece que este app está conectado em mais de um dispositivo ao mesmo tempo. Para manter sua história sincronizada, este app precisa ser reiniciado.';
      case 'ja':
        return 'このアプリが複数のデバイスで同時にログインしているようです。小説の同期を保つため、このアプリを再起動する必要があります。';
      case 'ko':
        return '이 앱이 여러 기기에서 동시에 로그인된 것 같습니다. 이야기 동기화를 유지하려면 이 앱을 다시 시작해야 합니다.';
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
      case 'es':
        return 'OK';
      case 'fr':
        return 'OK';
      case 'de':
        return 'OK';
      case 'pt':
        return 'OK';
      case 'ja':
        return 'OK';
      case 'ko':
        return '확인';
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

  /// 冷启动同步失败：底层保持加载页，弹出"重启 App"弹窗。
  /// 点击"重启 App"后重新启动，启动同步会再次从服务器拉取并对齐。
  Future<void> _showStartupSyncErrorDialog() async {
    if (!mounted || _startupSyncError == null) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        content: Text(_getSyncErrorMessageText(_startupSyncError ?? '')),
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

  /// "正在同步"提示文字（本地化）
  String _getSyncingText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '正在同步…';
      case 'en':
        return 'Syncing…';
      case 'es':
        return 'Sincronizando…';
      case 'fr':
        return 'Synchronisation…';
      case 'de':
        return 'Wird synchronisiert…';
      case 'pt':
        return 'Sincronizando…';
      case 'ja':
        return '同期中…';
      case 'ko':
        return '동기화 중…';
      default:
        return '正在同步…';
    }
  }

  /// 同步失败提示文字（本地化）
  String _getSyncErrorMessageText(String detail) {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '同步失敗，暫時無法開始。請檢查網路後重試。\n($detail)';
      case 'yue':
        return '同步失敗，暫時無法開始。請檢查網路後重試。\n($detail)';
      case 'en':
        return 'Sync failed. Please check your network and try again.\n($detail)';
      case 'es':
        return 'Error de sincronización. No se puede continuar por ahora. Compruebe su red e inténtelo de nuevo.\n($detail)';
      case 'fr':
        return 'Échec de la synchronisation. Impossible de continuer pour le moment. Vérifiez votre réseau et réessayez.\n($detail)';
      case 'de':
        return 'Synchronisierung fehlgeschlagen. Der Start ist vorübergehend nicht möglich. Bitte prüfen Sie Ihr Netzwerk und versuchen Sie es erneut.\n($detail)';
      case 'pt':
        return 'Falha na sincronização. Não foi possível começar por enquanto. Verifique sua rede e tente novamente.\n($detail)';
      case 'ja':
        return '同期に失敗しました。しばらく開始できません。ネットワークを確認して、もう一度お試しください。\n($detail)';
      case 'ko':
        return '동기화에 실패했습니다. 지금은 시작할 수 없습니다. 네트워크를 확인하고 다시 시도해 주세요.\n($detail)';
      default:
        return '同步失败，暂时无法开始。请检查网络后重试。\n($detail)';
    }
  }

  /// 流式卡死（40 秒未收到任何数据且未完成）：网络可能有问题，
  /// 为保证小说文本完整，弹出警告并强制用户重启本 App，重启后重新拉取完整数据。
  Future<void> _onStreamStalled() async {
    if (!mounted) return;
    _abortBlackoutTransition();
    // 不在弹窗前把 _storyStreaming 置 false：否则会移除下方"生成区"（用户选择 +
    // 提示 + 半屏预留空白），内容高度骤减、滚动位置被钳到底部，弹窗瞬间页面剧烈
    // 跳动、按钮贴到屏幕下沿。保持当前流式布局在弹窗背后原样冻结，弹窗关闭后由
    // App 重启重置状态。
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
      case 'es':
        return 'Problema de red';
      case 'fr':
        return 'Problème de réseau';
      case 'de':
        return 'Netzwerkproblem';
      case 'pt':
        return 'Problema de rede';
      case 'ja':
        return 'ネットワークエラー';
      case 'ko':
        return '네트워크 문제';
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
      case 'es':
        return 'Para mantener el texto de tu historia completo, comprueba tu red y reinicia esta App.';
      case 'fr':
        return 'Pour conserver le texte de votre histoire complet, vérifiez votre réseau et redémarrez cette app.';
      case 'de':
        return 'Um Ihren Geschichtentext vollständig zu erhalten, prüfen Sie Ihr Netzwerk und starten Sie diese App neu.';
      case 'pt':
        return 'Para manter o texto da sua história completo, verifique sua rede e reinicie este app.';
      case 'ja':
        return '小説のテキストを完全に保つため、ネットワークを確認してこのアプリを再起動してください。';
      case 'ko':
        return '이야기 텍스트를 완전하게 유지하려면 네트워크를 확인하고 이 앱을 다시 시작하세요.';
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

  /// 违规弹窗内容：提示当前生成内容疑似违规，需重新输入提示词（本地化）
  String _getViolationMessageText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '目前生成內容疑似違規，請重新輸入提示詞。';
      case 'yue':
        return '而家生成內容疑似違規，請重新輸入提示詞。';
      case 'en':
        return 'The generated content may violate our guidelines. Please re-enter your prompt.';
      case 'es':
        return 'El contenido generado podría infringir las normas. Vuelva a introducir su indicación.';
      case 'fr':
        return 'Le contenu généré semble enfreindre nos règles. Veuillez ressaisir votre consigne.';
      case 'de':
        return 'Der generierte Inhalt verstößt möglicherweise gegen unsere Richtlinien. Bitte geben Sie Ihre Eingabe erneut ein.';
      case 'pt':
        return 'O conteúdo gerado pode violar nossas diretrizes. Insira novamente sua instrução.';
      case 'ja':
        return '生成された内容がガイドラインに違反している可能性があります。プロンプトを再入力してください。';
      case 'ko':
        return '생성된 콘텐츠가 가이드라인을 위반했을 수 있습니다. 프롬프트를 다시 입력하세요.';
      default:
        return '当前生成内容疑似违规，请重新输入提示词。';
    }
  }

  /// 违规弹窗唯一按钮"重新输入"（本地化）
  String _getReenterText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '重新輸入';
      case 'en':
        return 'Re-enter';
      case 'es':
        return 'Volver a introducir';
      case 'fr':
        return 'Ressaisir';
      case 'de':
        return 'Erneut eingeben';
      case 'pt':
        return 'Inserir novamente';
      case 'ja':
        return '再入力';
      case 'ko':
        return '다시 입력';
      default:
        return '重新输入';
    }
  }

  /// 违规弹窗：无标题，提示当前生成内容疑似违规，需重新输入提示词；
  /// 只有一个"重新输入"按钮。点击后残缺段落已在 onAbort 中删除，
  /// 页面已恢复为等待输入状态，此处仅关闭弹窗。
  Future<void> _showViolationDialog() async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        content: Text(_getViolationMessageText()),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_getReenterText()),
          ),
        ],
      ),
    );
  }

  /// 【调试】弹窗打印数据库（story_segments）最新一条生成条目的全部字段。
  ///
  /// 每次生成完成（正文 + 推荐按钮均已就绪）后调用：从服务器拉取最新一行，
  /// 以只读文本弹窗展示所有字段，用户点"确认"后按原逻辑继续运行。
  ///
  /// 重要：App 根组件是 CupertinoApp，必须使用 Cupertino 弹窗。若用 Material 的
  /// showDialog/AlertDialog/TextButton/SelectableText，会因缺少 MaterialLocalizations
  /// 与 Material Theme 导致弹窗内容构建失败——只剩一个不可见遮罩挡住所有输入，
  /// 表现为"窗口失去焦点/锁死、看不到弹窗也无法点击"（本次已修复）。
  Future<void> _showLatestDbRowDebugDialog() async {
    if (!mounted) return;
    final Map<String, dynamic>? row = await StoryService.fetchLatestStoryRow();
    if (!mounted) return;
    final String body = row == null
        ? '(无法获取数据库最新条目，请确认服务器已部署 /api/story/latest 调试端点)'
        : _formatDebugRow(row);
    // 调试内容用"只读 CupertinoTextField"承载：与 App 内其它输入框同款控件，
    // 在 macOS 上原生支持鼠标框选 + 右键"拷贝"。该控件只出现在本调试弹窗内，
    // 其它弹窗仍是纯 Text（不可选中复制），互不影响。
    final TextEditingController ctrl = TextEditingController(text: body);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('调试 · 数据库最新生成条目'),
        content: SizedBox(
          width: 460,
          height: 400,
          child: CupertinoTextField(
            controller: ctrl,
            readOnly: true, // 只读：可选中/复制，不可编辑
            maxLines: null,
            minLines: null,
            expands: true, // 填满 460x400 区域，超高内容内部滚动
            keyboardType: TextInputType.multiline,
            padding: const EdgeInsets.all(12),
            decoration: null, // 无边框/背景，观感接近纯文本
            cursorColor: const Color(0x00000000), // 隐藏光标，更像普通文本
            style: const TextStyle(fontSize: 13),
            enableInteractiveSelection: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    ctrl.dispose();
  }

  /// 把数据库一行的全部字段格式化为可读文本（保留服务器返回的列顺序）。
  String _formatDebugRow(Map<String, dynamic> row) {
    final buf = StringBuffer();
    row.forEach((key, value) {
      final s = value is String ? value : (value?.toString() ?? '');
      buf.writeln('[$key]');
      if (key == 'content') buf.writeln('(length=${s.length})');
      buf.writeln(s.isEmpty ? '（空）' : s);
      buf.writeln('----------------');
    });
    return buf.toString();
  }

  /// 【调试】生成前确认弹窗：展示服务器即将发送给 Dify 的 payload JSON。
  ///
  /// 点击任一生成按钮后，服务器在真正调 Dify 之前先通过 SSE 事件 debug_payload
  /// 把 payload 发回 App。这里用只读文本弹窗展示（可选中/复制），
  /// 用户点"确认发送"后调用 [StoryService.confirmPayload] 通知服务器放行本次生成。
  Future<void> _showDebugPayloadDialog(
    Map<String, dynamic> payload,
    String requestId,
  ) async {
    if (!mounted) return;
    String body;
    try {
      body = const JsonEncoder.withIndent('  ').convert(payload);
    } catch (_) {
      body = payload.toString();
    }
    final TextEditingController ctrl = TextEditingController(text: body);
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('调试 · 待发送给 Dify 的 payload（确认后发送）'),
        content: SizedBox(
          width: 460,
          height: 420,
          child: CupertinoTextField(
            controller: ctrl,
            readOnly: true, // 只读：可选中/复制，不可编辑
            maxLines: null,
            minLines: null,
            expands: true, // 填满 460x420 区域，超高内容内部滚动
            keyboardType: TextInputType.multiline,
            padding: const EdgeInsets.all(12),
            decoration: null,
            cursorColor: const Color(0x00000000),
            style: const TextStyle(fontSize: 12),
            enableInteractiveSelection: true,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () async {
              // 通知服务器放行本次生成（服务器收到后才真正调 Dify）
              await StoryService.confirmPayload(requestId);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('确认发送'),
          ),
        ],
      ),
    );
    ctrl.dispose();
  }

  /// 生成失败弹窗：仅提供"重启 App"按钮。
  /// 出错后不再提供"跳过/重试"（避免本地与服务器段数不一致时少显示一段、
  /// 或基于错位状态续写）；重启后启动同步会重新拉取服务器已落库的段落并对齐。
  Future<void> _showGenerateError(String detail) async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CupertinoAlertDialog(
        title: Text(_getErrorTitleText()),
        content: Text(_getErrorMessageText(detail)),
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
}
