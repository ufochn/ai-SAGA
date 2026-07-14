import 'package:flutter/material.dart';
import 'package:flutter_application_1/widgets/character_text.dart';
import 'package:flutter_application_1/widgets/position_button.dart';
import 'package:flutter_application_1/widgets/text_input_panel.dart';
import 'package:flutter_application_1/widgets/initialization_page.dart';

import 'package:flutter_application_1/logic/storage_service.dart';

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
/// 固定布局格式：文字 → 按钮1 → 按钮2 → 输入框(含附属按钮)
/// 输入框限制了最大高度，保证下方按钮始终在屏幕内
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
  bool _showInitialization = false;

  @override
  void initState() {
    super.initState();
    // 从存储恢复各项内容
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

    // 如果主文本为空且未初始化，显示初始化页面
    if (_mainText.isEmpty && !StorageService.isInitialized()) {
      _showInitialization = true;
    }

    // 首次加载完成后滚动到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
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
    if (_showInitialization) {
      return InitializationPage(
        onComplete: () {
          setState(() {
            _showInitialization = false;
          });
        },
      );
    }

    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 文字
          CharacterText(text: _fullText),
          // 与按钮1之间的空行间距
          const SizedBox(height: 20),
          // 按钮1 - 在文本末尾添加"按钮1"
          PositionButton(label: '按钮', onPressed: _onButton1Pressed),
          // 与按钮2之间的空行间距
          const SizedBox(height: 20),
          // 按钮2 - 在文本末尾添加"按钮2"
          PositionButton(label: '按钮', onPressed: _onButton2Pressed),
          // 与输入框之间的空行间距
          const SizedBox(height: 20),
          // 输入框和确定输入按钮（输入框最大5行，不会无限撑高）
          TextInputPanel(onConfirm: _onInputConfirm),
        ],
      ),
    );
  }
}
