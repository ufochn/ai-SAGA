import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 设置确认页。
///
/// 主角/搭档设定审核通过后进入本页：列出全部设置项，每项带"编辑"快捷按钮
/// 跳回对应设置页；底部"确定"按钮触发"进入全新世界"提示 + 5 秒倒计时，
/// 倒计时结束回调 [onConfirmed] 进入正式主页面。
class SetupConfirmationPage extends StatefulWidget {
  /// 各设置的"编辑"跳转回调：index 对应 0=语言,1=地点,2=年代,3=主角,4=搭档
  final void Function(int index) onEdit;
  final VoidCallback onConfirmed;

  const SetupConfirmationPage({
    super.key,
    required this.onEdit,
    required this.onConfirmed,
  });

  @override
  State<SetupConfirmationPage> createState() => _SetupConfirmationPageState();
}

class _SetupConfirmationPageState extends State<SetupConfirmationPage> {
  /// 确定后是否进入倒计时状态
  bool _counting = false;
  int _countdown = 5;
  Timer? _timer;

  String get _language => StorageService.getLanguage();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _languageName(String code) {
    switch (code) {
      case 'en':
        return 'English';
      case 'ja':
        return '日本語';
      case 'es':
        return 'Español';
      case 'fr':
        return 'Français';
      case 'de':
        return 'Deutsch';
      case 'pt':
        return 'Português';
      case 'zh-TW':
        return '繁體中文';
      case 'yue':
        return '粵語';
      case 'ko':
        return '한국어';
      case 'zh':
        return '简体中文';
      default:
        return code.isEmpty ? '—' : code;
    }
  }

  String _genderText(String gender) {
    switch (gender) {
      case '男':
        return '男';
      case '女':
        return '女';
      default:
        return gender.isEmpty ? '—' : gender;
    }
  }

  void _startCountdown() {
    setState(() {
      _counting = true;
      _countdown = 5;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        widget.onConfirmed();
      } else {
        setState(() {
          _countdown--;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);

    final items = <({String label, String value, int index})>[
      (label: '语言', value: _languageName(_language), index: 0),
      (label: '地点', value: StorageService.getLocation(), index: 1),
      (label: '年代', value: StorageService.getEra(), index: 2),
      (
        label: '主角',
        value:
            '${_genderText(StorageService.getPlayerGender())} · ${StorageService.getPlayerName()}',
        index: 3,
      ),
      (
        label: '搭档',
        value:
            '${_genderText(StorageService.getPartnerGender())} · ${StorageService.getPartnerName()}'
            '${StorageService.getPartnerTraits().isNotEmpty ? '（${StorageService.getPartnerTraits()}）' : ''}',
        index: 4,
      ),
    ];

    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Icon(
                      CupertinoIcons.checkmark_seal_fill,
                      size: 56,
                      color: isDark
                          ? AppTheme.accentBlueDark
                          : AppTheme.accentBlueLight,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _counting ? '准备就绪' : '确认你的设定',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppTheme.primaryTextDark
                            : AppTheme.primaryTextLight,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _counting ? '现在开始进入全新的世界，请期待' : '以下是你本次冒险的设定，可点击"编辑"随时修改',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: isDark
                            ? AppTheme.secondaryTextDark
                            : AppTheme.secondaryTextLight,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (!_counting) ...[
                      for (final item in items)
                        _buildItemCard(
                          isDark,
                          label: item.label,
                          value: item.value,
                          onEdit: () => widget.onEdit(item.index),
                        ),
                    ] else ...[
                      _buildCountdown(isDark),
                    ],
                  ],
                ),
              ),
            ),
            if (!_counting)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: CupertinoButton.filled(
                  onPressed: _startCountdown,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: const Text(
                    '确定',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemCard(
    bool isDark, {
    required String label,
    required String value,
    required VoidCallback onEdit,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.cardBackgroundDark
            : AppTheme.cardBackgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? AppTheme.secondaryTextDark
                    : AppTheme.secondaryTextLight,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 15,
                color: isDark
                    ? AppTheme.primaryTextDark
                    : AppTheme.primaryTextLight,
              ),
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onEdit,
            child: Text(
              '编辑',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
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

  Widget _buildCountdown(bool isDark) {
    return Column(
      children: [
        const SizedBox(height: 40),
        Container(
          width: 120,
          height: 120,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isDark
                  ? AppTheme.accentBlueDark
                  : AppTheme.accentBlueLight,
              width: 3,
            ),
          ),
          child: Text(
            '$_countdown',
            style: TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w700,
              color: isDark
                  ? AppTheme.accentBlueDark
                  : AppTheme.accentBlueLight,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '正在进入全新的世界…',
          style: TextStyle(
            fontSize: 16,
            color: isDark
                ? AppTheme.secondaryTextDark
                : AppTheme.secondaryTextLight,
          ),
        ),
      ],
    );
  }
}
