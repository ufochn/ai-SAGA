import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 游戏初始化页面 - 语言选择（iOS风格）
class InitializationPage extends StatefulWidget {
  final VoidCallback onComplete;

  const InitializationPage({super.key, required this.onComplete});

  @override
  State<InitializationPage> createState() => _InitializationPageState();
}

class _InitializationPageState extends State<InitializationPage> {
  String _selectedLanguage = '';
  int _selectedIndex = 0;
  late final TextEditingController _controller;

  static const List<Map<String, String>> _languages = [
    {'code': 'en', 'name': 'English'},
    {'code': 'ja', 'name': '日本語'},
    {'code': 'es', 'name': 'Español'},
    {'code': 'fr', 'name': 'Français'},
    {'code': 'de', 'name': 'Deutsch'},
    {'code': 'pt', 'name': 'Português'},
    {'code': 'zh', 'name': '简体中文'},
    {'code': 'zh-TW', 'name': '繁體中文'},
    {'code': 'yue', 'name': '粵語'},
    {'code': 'ko', 'name': '한국어'},
  ];

  @override
  void initState() {
    super.initState();
    // 进入语言设置页时：若用户默认语言（已选或系统）在支持列表内，
    // 滚动选择器（齿轮）默认对准该语言；否则默认对准 English。
    final String defaultLang = StorageService.getDefaultLanguageForPicker();
    final int idx = _languages.indexWhere((l) => l['code'] == defaultLang);
    if (idx >= 0) {
      _selectedIndex = idx;
      _selectedLanguage = defaultLang;
    } else {
      _selectedIndex = 0;
      _selectedLanguage = '';
    }
    _controller = TextEditingController(text: _selectedLanguageName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _selectedLanguageName {
    if (_selectedLanguage.isEmpty) return '';
    return _languages.firstWhere(
      (l) => l['code'] == _selectedLanguage,
    )['name']!;
  }

  void _showLanguagePicker() {
    final isDark = AppTheme.isDark(context);
    // 使用临时索引跟踪滚轮位置，仅在点 Done 时通过 setState 提交
    int tempIndex = _selectedIndex;
    showCupertinoModalPopup(
      context: context,
      builder: (context) => Container(
        height: 280,
        color: isDark
            ? AppTheme.cardBackgroundDark
            : AppTheme.cardBackgroundLight,
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Done',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.accentBlueDark
                          : AppTheme.accentBlueLight,
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _selectedIndex = tempIndex;
                      _selectedLanguage = _languages[tempIndex]['code']!;
                      _controller.text = _selectedLanguageName;
                    });
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
            Expanded(
              child: CupertinoPicker(
                backgroundColor: isDark
                    ? AppTheme.cardBackgroundDark
                    : AppTheme.cardBackgroundLight,
                itemExtent: 40,
                scrollController: FixedExtentScrollController(
                  initialItem: _selectedIndex,
                ),
                onSelectedItemChanged: (index) {
                  tempIndex = index;
                },
                children: _languages.map((lang) {
                  return Center(
                    child: Text(
                      '${lang['name']}',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight:
                            _languages[_selectedIndex]['code'] == lang['code']
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: isDark
                            ? AppTheme.primaryTextDark
                            : AppTheme.primaryTextLight,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 根据已选语言返回按钮文字（下一步）
  String _getConfirmText() {
    switch (_selectedLanguage) {
      case 'zh-TW':
      case 'yue':
      case 'zh':
        return '下一步';
      case 'en':
        return 'Next';
      case 'es':
        return 'Siguiente';
      case 'fr':
        return 'Suivant';
      case 'de':
        return 'Weiter';
      case 'pt':
        return 'Próximo';
      case 'ja':
        return '次へ';
      case 'ko':
        return '다음';
      default:
        return '下一步';
    }
  }

  /// 根据当前语言返回页面标题
  String _getTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '選擇您的語言';
      case 'en':
        return 'Choose your language';
      case 'es':
        return 'Elige tu idioma';
      case 'fr':
        return 'Choisissez votre langue';
      case 'de':
        return 'Wählen Sie Ihre Sprache';
      case 'pt':
        return 'Escolha seu idioma';
      case 'ja':
        return '言語を選択';
      case 'ko':
        return '언어를 선택하세요';
      default:
        return '选择您的语言';
    }
  }

  /// 根据当前语言返回页面说明文字
  String _getSubtitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '遊戲內容將以您選擇的語言顯示。';
      case 'en':
        return 'Game content will be shown in the language you choose.';
      case 'es':
        return 'El contenido del juego se mostrará en el idioma que elijas.';
      case 'fr':
        return 'Le contenu du jeu sera affiché dans la langue de votre choix.';
      case 'de':
        return 'Der Spielinhalt wird in der von Ihnen gewählten Sprache angezeigt.';
      case 'pt':
        return 'O conteúdo do jogo será exibido no idioma que você escolher.';
      case 'ja':
        return 'ゲームの内容は選択した言語で表示されます。';
      case 'ko':
        return '게임 콘텐츠는 선택한 언어로 표시됩니다.';
      default:
        return '游戏内容将以您选择的语言显示。';
    }
  }

  void _onSubmit() {
    if (_selectedLanguage.isEmpty) return;
    SoundService.playConfirm();
    StorageService.saveLanguage(_selectedLanguage);
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: isDark
            ? AppTheme.pageBackgroundDark
            : AppTheme.pageBackgroundLight,
        border: null,
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final buttonTop = constraints.maxHeight * 0.75;
            return Stack(
              children: [
                Positioned.fill(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 20),
                        // 标题 + 副标题（固定高度，保证下方选择框位置一致）
                        SizedBox(
                          height: 124,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _getTitleText(),
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? AppTheme.primaryTextDark
                                      : AppTheme.primaryTextLight,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _getSubtitleText(),
                                style: TextStyle(
                                  fontSize: 16,
                                  color: isDark
                                      ? AppTheme.secondaryTextDark
                                      : AppTheme.secondaryTextLight,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                        // Language dropdown（高度与地点/时代输入框保持一致）
                        Container(
                          height: 50,
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.cardBackgroundDark
                                : AppTheme.cardBackgroundLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: CupertinoTextField(
                            controller: _controller,
                            readOnly: true,
                            onTap: _showLanguagePicker,
                            placeholder:
                                'Select Language / 言語選択 / 選擇語言 / 언어 선택',
                            placeholderStyle: TextStyle(
                              fontSize: 17,
                              color: isDark
                                  ? AppTheme.tertiaryTextDark
                                  : AppTheme.tertiaryTextLight,
                            ),
                            padding: const EdgeInsets.only(
                              left: 16,
                              right: 4,
                              top: 14,
                              bottom: 14,
                            ),
                            decoration: null,
                            style: TextStyle(
                              fontSize: 17,
                              color: isDark
                                  ? AppTheme.primaryTextDark
                                  : AppTheme.primaryTextLight,
                            ),
                            suffix: GestureDetector(
                              onTap: _showLanguagePicker,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Icon(
                                  CupertinoIcons.chevron_down,
                                  color: isDark
                                      ? AppTheme.secondaryTextDark
                                      : AppTheme.secondaryTextLight,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 确认按钮（固定于页面 3/4 高度位置）
                Positioned(
                  left: 16,
                  right: 16,
                  top: buttonTop,
                  child: SizedBox(
                    height: 48,
                    child: CupertinoButton.filled(
                      onPressed: _selectedLanguage.isNotEmpty
                          ? _onSubmit
                          : null,
                      borderRadius: BorderRadius.circular(12),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      color: isDark
                          ? AppTheme.buttonFillDark
                          : AppTheme.buttonFillLight,
                      disabledColor: isDark
                          ? const Color(0xFF2C2C2E)
                          : const Color(0xFFF2F2F7),
                      child: Text(
                        _selectedLanguage.isNotEmpty ? _getConfirmText() : '',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: _selectedLanguage.isNotEmpty
                              ? AppTheme.buttonText
                              : (isDark
                                    ? AppTheme.buttonDisabledTextDark
                                    : AppTheme.buttonDisabledTextLight),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
