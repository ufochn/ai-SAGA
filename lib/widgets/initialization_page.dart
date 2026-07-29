import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 游戏初始化页面 - 地区选择（iOS风格）
class InitializationPage extends StatefulWidget {
  final VoidCallback onComplete;

  const InitializationPage({super.key, required this.onComplete});

  @override
  State<InitializationPage> createState() => _InitializationPageState();
}

class _InitializationPageState extends State<InitializationPage> {
  String _selectedRegion = '';

  static const List<Map<String, String>> _regions = [
    {'value': 'taiwan', 'label': '台灣'},
    {'value': 'hongkong', 'label': '香港'},
    {'value': 'singapore', 'label': 'Singapore'},
    {'value': 'japan', 'label': '日本'},
    {'value': 'korea', 'label': '한국'},
    {'value': 'usa', 'label': 'United States'},
  ];

  void _onSubmit() {
    if (_selectedRegion.isEmpty) return;
    SoundService.playConfirm();
    StorageService.saveRegion(_selectedRegion);
    StorageService.setInitialized();
    widget.onComplete();
  }

  /// 根据所选地区返回对应语言的确认按钮文字
  String _getConfirmButtonText() {
    switch (_selectedRegion) {
      case 'taiwan':
        return '確認選擇';
      case 'hongkong':
        return '確認選擇';
      case 'singapore':
        return 'Confirm';
      case 'japan':
        return '確認';
      case 'korea':
        return '확인';
      case 'usa':
        return 'Confirm';
      default:
        return 'Confirm / 確認 / 확인 / 確認選擇';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Text(
                'Please select your region',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppTheme.primaryTextDark
                      : AppTheme.primaryTextLight,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '地域を選択してください',
                style: TextStyle(
                  fontSize: 18,
                  color: isDark
                      ? AppTheme.secondaryTextDark
                      : AppTheme.secondaryTextLight,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                '지역을 선택하세요',
                style: TextStyle(
                  fontSize: 18,
                  color: isDark
                      ? AppTheme.secondaryTextDark
                      : AppTheme.secondaryTextLight,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                '請選擇地區',
                style: TextStyle(
                  fontSize: 18,
                  color: isDark
                      ? AppTheme.secondaryTextDark
                      : AppTheme.secondaryTextLight,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              // iOS风格分组列表
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.cardBackgroundDark
                      : AppTheme.cardBackgroundLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: List.generate(_regions.length, (index) {
                    final region = _regions[index];
                    final isSelected = _selectedRegion == region['value'];
                    final isLast = index == _regions.length - 1;
                    return Column(
                      children: [
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedRegion = region['value']!;
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    region['label']!,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: isDark
                                          ? AppTheme.primaryTextDark
                                          : AppTheme.primaryTextLight,
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Icon(
                                    CupertinoIcons.check_mark_circled_solid,
                                    color: isDark
                                        ? AppTheme.accentBlueDark
                                        : AppTheme.accentBlueLight,
                                    size: 22,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (!isLast)
                          Container(
                            height: 0.5,
                            margin: const EdgeInsets.only(left: 16),
                            color: isDark
                                ? AppTheme.separatorDark
                                : AppTheme.separatorLight,
                          ),
                      ],
                    );
                  }),
                ),
              ),
              const SizedBox(height: 24),
              // iOS风格确认按钮
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  onPressed: _selectedRegion.isNotEmpty ? _onSubmit : null,
                  borderRadius: BorderRadius.circular(12),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  color: isDark
                      ? AppTheme.buttonFillDark
                      : AppTheme.buttonFillLight,
                  disabledColor: isDark
                      ? const Color(0xFF2C2C2E)
                      : const Color(0xFFF2F2F7),
                  child: Text(
                    _getConfirmButtonText(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _selectedRegion.isNotEmpty
                          ? AppTheme.buttonText
                          : (isDark
                                ? AppTheme.buttonDisabledTextDark
                                : AppTheme.buttonDisabledTextLight),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}
