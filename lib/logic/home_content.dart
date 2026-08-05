import 'package:flutter/cupertino.dart';
import 'package:ai_saga/widgets/character_text.dart';
import 'package:ai_saga/widgets/position_button.dart';
import 'package:ai_saga/widgets/text_input_panel.dart';
import 'package:ai_saga/widgets/initialization_page.dart';
import 'package:ai_saga/widgets/location_setup_page.dart';
import 'package:ai_saga/widgets/era_setup_page.dart';
import 'package:ai_saga/widgets/player_setup_page.dart';
import 'package:ai_saga/widgets/character_setup_page.dart';

import 'package:ai_saga/logic/storage_service.dart';
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

class _HomeContentState extends State<HomeContent> {
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
      // 语言已在轻授权前选择（新用户经 LanguageFirstGate）或已有历史数据：
      // 跳过语言页，从地点设定开始；若语言尚未选择，则仍从语言页开始。
      _setupStep = StorageService.getLanguage().isEmpty ? 0 : 1;
      showMenuNotifier.value = false;
    } else {
      // 已初始化（老用户）：直接进正式主页面，不经过确认页
      _setupStep = 6;
      showMenuNotifier.value = true;
    }

    _pageController = PageController(
      initialPage: _setupStep < 2 ? _setupStep : 0,
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
    super.dispose();
  }

  /// 获取完整展示文本
  String get _fullText =>
      _mainText + _button1Content + _button2Content + _inputContent;

  void _onButton1Pressed() {
    setState(() {
      _button1Content += '按钮1';
    });
    StorageService.saveButton1Content(_button1Content);
  }

  void _onButton2Pressed() {
    setState(() {
      _button2Content += '按钮2';
    });
    StorageService.saveButton2Content(_button2Content);
  }

  void _onInputConfirm(String text) {
    setState(() {
      _inputContent += text;
    });
    StorageService.saveInputContent(_inputContent);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
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
                      _pageController.animateToPage(
                        1,
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                  // 第1页：地点设定
                  LocationSetupPage(
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
                    onComplete: () {
                      final genderStr = StorageService.getPlayerGender();
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
              ),
            )
          : KeyedSubtree(
              key: const ValueKey('main_content'),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CharacterText(text: _fullText),
                    const SizedBox(height: 12),
                    PositionButton(label: '按钮', onPressed: _onButton1Pressed),
                    const SizedBox(height: 12),
                    PositionButton(label: '按钮', onPressed: _onButton2Pressed),
                    const SizedBox(height: 12),
                    TextInputPanel(onConfirm: _onInputConfirm),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
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

  /// 设置确认页倒计时结束：进入正式主页面。
  void _onSetupConfirmed() {
    setState(() {
      _setupStep = 6;
      showMenuNotifier.value = true;
    });
  }
}
