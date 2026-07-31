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

  /// 根据已选语言返回确认按钮文字
  String _getConfirmText() {
    switch (_selectedLanguage) {
      case 'zh-TW':
      case 'yue':
        return '確認';
      case 'en':
        return 'Confirm';
      case 'es':
        return 'Confirmar';
      case 'fr':
        return 'Confirmer';
      case 'de':
        return 'Bestätigen';
      case 'pt':
        return 'Confirmar';
      case 'ja':
        return '確認';
      case 'ko':
        return '확인';
      case 'zh':
        return '确认';
      default:
        return 'Confirm';
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
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Language dropdown button
                        GestureDetector(
                          onTap: _showLanguagePicker,
                          child: Container(
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.cardBackgroundDark
                                  : AppTheme.cardBackgroundLight,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _selectedLanguage.isEmpty
                                        ? 'Select Language / 言語選択 / 選擇語言 / 언어 선택'
                                        : _selectedLanguageName,
                                    style: TextStyle(
                                      fontSize: 17,
                                      color: _selectedLanguage.isEmpty
                                          ? (isDark
                                                ? AppTheme.tertiaryTextDark
                                                : AppTheme.tertiaryTextLight)
                                          : (isDark
                                                ? AppTheme.primaryTextDark
                                                : AppTheme.primaryTextLight),
                                    ),
                                  ),
                                ),
                                Icon(
                                  CupertinoIcons.chevron_down,
                                  color: isDark
                                      ? AppTheme.secondaryTextDark
                                      : AppTheme.secondaryTextLight,
                                  size: 18,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Confirm button
                        SizedBox(
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
                              _selectedLanguage.isNotEmpty
                                  ? _getConfirmText()
                                  : '',
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
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
