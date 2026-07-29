import 'package:flutter/cupertino.dart';
import 'package:ai_saga/widgets/character_text.dart';
import 'package:ai_saga/widgets/position_button.dart';
import 'package:ai_saga/widgets/text_input_panel.dart';
import 'package:ai_saga/widgets/initialization_page.dart';
import 'package:ai_saga/widgets/character_setup_page.dart';

import 'package:ai_saga/logic/storage_service.dart';

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

  /// 0=地区选择, 1=角色设定, 2=完成
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
      _setupStep = 0;
      showMenuNotifier.value = false;
    } else {
      _setupStep = 2;
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
      child: _setupStep < 2
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
                  // 第0页：地区选择
                  InitializationPage(
                    onComplete: () {
                      _pageController.animateToPage(
                        1,
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                  // 第1页：角色设定
                  CharacterSetupPage(
                    onComplete: () {
                      setState(() {
                        _setupStep = 2;
                        showMenuNotifier.value = true;
                      });
                    },
                    onBack: () {
                      _pageController.animateToPage(
                        0,
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ],
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
}
