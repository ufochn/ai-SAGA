import 'package:flutter/cupertino.dart';
import 'package:ai_saga/widgets/character_text.dart';
import 'package:ai_saga/widgets/text_input_panel.dart';
import 'package:ai_saga/widgets/initialization_page.dart';
import 'package:ai_saga/widgets/location_setup_page.dart';
import 'package:ai_saga/widgets/era_setup_page.dart';
import 'package:ai_saga/widgets/player_setup_page.dart';
import 'package:ai_saga/widgets/character_setup_page.dart';

import 'package:ai_saga/logic/setup_draft.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/story_service.dart';
import 'package:ai_saga/widgets/setup_confirmation_page.dart';

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

/// 页面主体内容组件 - 综合文字、按钮和输入框的混合布局
class HomeContent extends StatefulWidget {
  const HomeContent({super.key});

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent>
    with SingleTickerProviderStateMixin {
  String _mainText = '';
  String _button1Content = '';
  String _button2Content = '';
  String _inputContent = '';
  final ScrollController _scrollController = ScrollController();
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

  /// 流式小说正文（随 chunk/reveal 累计）
  String _storyText = '';

  /// 当前段落在 [_storyText] 中的起始下标：打字机按段落内进度重新从最慢加速，
  /// 保证每次续写输入都从头以慢速开始输出。
  int _segmentStart = 0;

  /// 违规中止原因（非空时隐藏正文并显示该提示）
  String? _storyAbortReason;

  /// 生成轮次计数（续写时作为 user_input_counter）
  int _storyRound = 0;

  @override
  void initState() {
    super.initState();
    if (StorageService.hasMainText()) {
      _mainText = StorageService.getMainText();
    } else {
      const stream = CharacterStream(character: '正', count: 1000);
      _mainText = stream.generate();
      StorageService.saveMainText(_mainText);
    }
    _button1Content = StorageService.getButton1Content();
    _button2Content = StorageService.getButton2Content();
    _inputContent = StorageService.getInputContent();

    if (!StorageService.isInitialized()) {
      // 未最终确认前所有设置仅存于内存草稿；每次进入设置流程先清空草稿
      SetupDraft.instance.reset();
      // 语言已在轻授权前选择（新用户经 LanguageFirstGate）或已有历史数据：
      // 跳过语言页，从地点设定开始；若语言尚未选择，则仍从语言页开始。
      _setupStep = StorageService.getLanguage().isEmpty ? 0 : 1;
      showMenuNotifier.value = false;
    } else {
      // 已初始化（老用户）：直接进正式主页面，不经过确认页
      _setupStep = 6;
      showMenuNotifier.value = true;
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
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    _blackoutController.dispose();
    super.dispose();
  }

  /// 获取完整展示文本
  String get _fullText =>
      _mainText + _button1Content + _button2Content + _inputContent;

  void _onInput1Confirm(String text) => _continueStory(text);

  void _onInput2Confirm(String text) => _continueStory(text);

  void _onInputConfirm(String text) => _continueStory(text);

  /// 任一输入框确认后：把输入作为 user_input，连同用户设定请求续写生成，
  /// 新内容在屏幕上接力显示（追加到 _storyText，由打字机继续揭示）。
  Future<void> _continueStory(String userInput) async {
    if (!mounted || userInput.trim().isEmpty) return;
    // 新一段内容与旧内容相隔一行（只在首个 chunk 前加一次）
    bool sepAdded = false;
    setState(() {
      _generating = true;
      _segmentStart = _storyText.length; // 新段落起点（续写内容从此开始）
      _storyAbortReason = null;
    });
    await StoryService.generateStoryStream(
      location: SetupDraft.instance.location,
      era: SetupDraft.instance.era,
      playerName: SetupDraft.instance.playerName,
      playerGender: SetupDraft.instance.playerGender,
      partnerName: SetupDraft.instance.partnerName,
      partnerGender: SetupDraft.instance.partnerGender,
      partnerTraits: SetupDraft.instance.partnerTraits,
      language: StorageService.getLanguage(),
      userInput: userInput,
      userInputCounter: _storyRound,
      onChunk: (text) {
        if (!mounted) return;
        setState(() {
          if (!sepAdded && _storyText.isNotEmpty) {
            _storyText += '\n\n'; // 与上一段相隔一行
            sepAdded = true;
            _segmentStart = _storyText.length; // 新段落正文起点（分隔符之后）
          }
          _storyText += text;
          _mainText = _storyText;
          _generating = false;
        });
      },
      onReveal: (text, outputs) {
        if (!mounted) return;
        // 剩余部分不再一次性显示，而是由打字机以不断加速的方式接续打出
        setState(() {
          _storyText += text;
          _mainText = _storyText;
          _generating = false;
        });
      },
      onAbort: (reason) {
        if (!mounted) return;
        setState(() {
          _storyAbortReason = reason;
          _generating = false;
        });
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _generating = false;
        });
        _showGenerateError(message);
      },
      onDone: (outputs) async {
        _storyRound++;
        await StorageService.saveMainText(_storyText);
      },
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
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_storyText.isNotEmpty)
                          TypewriterText(
                            text: _storyText,
                            speedUpEvery: 20,
                            segmentStart: _segmentStart,
                            abortReason: _storyAbortReason,
                          )
                        else
                          CharacterText(text: _fullText),
                        if (_generating && _storyText.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            child: Row(
                              children: [
                                CupertinoActivityIndicator(radius: 10),
                                SizedBox(width: 8),
                                Text('正在续写…'),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        TextInputPanel(onConfirm: _onInput1Confirm),
                        const SizedBox(height: 12),
                        TextInputPanel(onConfirm: _onInput2Confirm),
                        const SizedBox(height: 12),
                        TextInputPanel(onConfirm: _onInputConfirm),
                        const SizedBox(height: 24),
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
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                              radius: 14,
                            ),
                            SizedBox(height: 12),
                            Text(
                              '正在生成你的世界…',
                              style: TextStyle(color: CupertinoColors.white),
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
  Future<void> _onSetupConfirmed() async {
    await SetupDraft.instance.commit();
    if (!mounted) return;

    setState(() {
      _generating = true;
      _storyText = '';
      _segmentStart = 0; // 首次生成从第 1 个字重新最慢加速
      _storyAbortReason = null;
      _blackoutActive = true;
      _blackoutController.value = 0; // 覆盖层完全不透明（全黑）
    });

    // 流式：服务器先审首段，通过后 chunk 开始打字；剩余全审后 reveal 一次性显示
    await StoryService.generateStoryStream(
      location: SetupDraft.instance.location,
      era: SetupDraft.instance.era,
      playerName: SetupDraft.instance.playerName,
      playerGender: SetupDraft.instance.playerGender,
      partnerName: SetupDraft.instance.partnerName,
      partnerGender: SetupDraft.instance.partnerGender,
      partnerTraits: SetupDraft.instance.partnerTraits,
      language: StorageService.getLanguage(),
      onChunk: (text) {
        if (!mounted) return;
        setState(() {
          _storyText += text;
          _mainText = _storyText;
          _generating = false;
          _setupStep = 6;
          showMenuNotifier.value = true;
          _blackoutActive = false;
          _blackoutController.value = 1;
        });
      },
      onReveal: (text, outputs) {
        if (!mounted) return;
        // 剩余部分不再一次性显示，由打字机以不断加速的方式接续打出
        setState(() {
          _storyText += text;
          _mainText = _storyText;
          _generating = false;
          _blackoutActive = false;
          _blackoutController.value = 1;
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
        });
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _generating = false;
          _blackoutActive = false;
        });
        _showGenerateError(message);
      },
      onDone: (outputs) async {
        _storyRound++;
        await StorageService.saveMainText(_storyText);
      },
    );
  }

  /// 生成失败弹窗：重试重新走一次生成，跳过则用默认文本直接进入主页面。
  Future<void> _showGenerateError(String detail) async {
    final retry = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('生成失败'),
        content: Text('无法生成小说内容：$detail\n\n是否重试？'),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('跳过'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重试'),
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
