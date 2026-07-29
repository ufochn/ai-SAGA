import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 角色设定页面 - iOS风格表单
class CharacterSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;

  const CharacterSetupPage({super.key, required this.onComplete, this.onBack});

  @override
  State<CharacterSetupPage> createState() => _CharacterSetupPageState();
}

class _CharacterSetupPageState extends State<CharacterSetupPage> {
  final TextEditingController _playerNameController = TextEditingController();
  final TextEditingController _partnerNameController = TextEditingController();
  final TextEditingController _partnerTraitsController =
      TextEditingController();
  int _playerGenderIndex = 0; // 0=男, 1=女
  int _partnerGenderIndex = 0; // 0=男, 1=女

  @override
  void dispose() {
    _playerNameController.dispose();
    _partnerNameController.dispose();
    _partnerTraitsController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    SoundService.playHorror2();
    StorageService.savePlayerName(_playerNameController.text);
    StorageService.savePlayerGender(_playerGenderIndex == 0 ? '男' : '女');
    StorageService.savePartnerName(_partnerNameController.text);
    StorageService.savePartnerGender(_partnerGenderIndex == 0 ? '男' : '女');
    StorageService.savePartnerTraits(_partnerTraitsController.text);
    StorageService.setInitialized();
    widget.onComplete();
  }

  /// 根据地区返回本地化的欢迎标题
  String _getTitleText() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '歡迎您進入這個冒險探案戀愛遊戲。';
      case 'singapore':
      case 'usa':
        return 'Welcome to this adventure detective romance game.';
      case 'japan':
        return 'この冒険探偵恋愛ゲームへようこそ。';
      case 'korea':
        return '이 모험 탐정 연애 게임에 오신 것을 환영합니다.';
      default:
        return '欢迎您进入这个冒险探案恋爱游戏。';
    }
  }

  /// 根据地区返回本地化的副标题
  String _getSubtitleText() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '在遊戲開始前，請您先做一些小小的設定。';
      case 'singapore':
      case 'usa':
        return 'Before the game begins, please do a little setup.';
      case 'japan':
        return 'ゲームを始める前に、いくつかの設定をお願いします。';
      case 'korea':
        return '게임을 시작하기 전에 몇 가지 설정을 해주세요.';
      default:
        return '在游戏开始前，请您先做一些小小的设定。';
    }
  }

  /// 根据地区返回本地化的"姓名"标签
  String _getNameLabel({required bool isPlayer}) {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return isPlayer ? '您在遊戲中的姓名' : '搭檔及曖昧對象姓名';
      case 'singapore':
      case 'usa':
        return isPlayer ? 'Your Name' : 'Partner & Love Interest Name';
      case 'japan':
        return isPlayer ? 'あなたの名前' : 'パートナー＆恋愛対象の名前';
      case 'korea':
        return isPlayer ? '당신의 이름' : '파트너 및 연애 상대 이름';
      default:
        return isPlayer ? '您在游戏中的姓名' : '搭档及暧昧对象姓名';
    }
  }

  /// 根据地区返回本地化的"性别"标签
  String _getGenderLabel({required bool isPlayer}) {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return isPlayer ? '您的性別' : '他（她）的性別';
      case 'singapore':
      case 'usa':
        return isPlayer ? 'Your Gender' : 'Their Gender';
      case 'japan':
        return isPlayer ? 'あなたの性別' : 'パートナーの性別';
      case 'korea':
        return isPlayer ? '당신의 성별' : '파트너의 성별';
      default:
        return isPlayer ? '您的性别' : '他（她）的性别';
    }
  }

  /// 根据地区返回本地化的性别选项
  String _getMaleText() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '男';
      case 'singapore':
      case 'usa':
        return 'Male';
      case 'japan':
        return '男性';
      case 'korea':
        return '남성';
      default:
        return '男';
    }
  }

  String _getFemaleText() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '女';
      case 'singapore':
      case 'usa':
        return 'Female';
      case 'japan':
        return '女性';
      case 'korea':
        return '여성';
      default:
        return '女';
    }
  }

  /// 根据地区返回本地化的"确认设定"文字
  String _getSubmitText() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '確認設定';
      case 'singapore':
      case 'usa':
        return 'Confirm';
      case 'japan':
        return '設定確定';
      case 'korea':
        return '설정 확인';
      default:
        return '确认设定';
    }
  }

  /// 根据地区返回 placeholder
  String _getNamePlaceholder() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '請輸入姓名';
      case 'singapore':
      case 'usa':
        return 'Enter name';
      case 'japan':
        return '名前を入力';
      case 'korea':
        return '이름 입력';
      default:
        return '请输入姓名';
    }
  }

  /// 根据地区返回特质标签
  String _getTraitsLabel() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '他（她）的個人特質';
      case 'singapore':
      case 'usa':
        return 'Their Personal Traits';
      case 'japan':
        return 'パートナーの特徴';
      case 'korea':
        return '파트너의 특징';
      default:
        return '他（她）的个人特质';
    }
  }

  /// 根据地区返回特质提示
  String _getTraitsHint() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '性格、外貌、喜好等，請隨意輸入。不輸入則系統隨機生成。';
      case 'singapore':
      case 'usa':
        return 'Personality, appearance, hobbies, etc. Leave empty for random generation.';
      case 'japan':
        return '性格、外見、趣味など自由に入力してください。空欄の場合はランダム生成されます。';
      case 'korea':
        return '성격, 외모, 취미 등을 자유롭게 입력하세요. 입력하지 않으면 무작위 생성됩니다.';
      default:
        return '性格、外貌、喜好等，请随意输入。不输入则系统随机生成。';
    }
  }

  /// 根据地区返回"选填"
  String _getOptionalText() {
    switch (StorageService.getRegion()) {
      case 'taiwan':
      case 'hongkong':
        return '選填';
      case 'singapore':
      case 'usa':
        return 'Optional';
      case 'japan':
        return '任意';
      case 'korea':
        return '선택사항';
      default:
        return '选填';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: widget.onBack,
          child: Icon(
            CupertinoIcons.back,
            color: isDark ? AppTheme.accentBlueDark : AppTheme.accentBlueLight,
          ),
        ),
        backgroundColor: isDark
            ? AppTheme.pageBackgroundDark
            : AppTheme.pageBackgroundLight,
        border: null,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _getTitleText(),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppTheme.primaryTextDark
                      : AppTheme.primaryTextLight,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 32),
              // iOS风格分组表单
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.cardBackgroundDark
                      : AppTheme.cardBackgroundLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    // 玩家姓名
                    _buildFormRow(
                      context,
                      label: _getNameLabel(isPlayer: true),
                      child: CupertinoTextField(
                        controller: _playerNameController,
                        placeholder: _getNamePlaceholder(),
                        placeholderStyle: TextStyle(
                          color: isDark
                              ? AppTheme.tertiaryTextDark
                              : AppTheme.tertiaryTextLight,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: null,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.primaryTextDark
                              : AppTheme.primaryTextLight,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    _buildDivider(context),
                    // 玩家性别
                    _buildFormRow(
                      context,
                      label: _getGenderLabel(isPlayer: true),
                      child: CupertinoSlidingSegmentedControl<int>(
                        groupValue: _playerGenderIndex,
                        children: {
                          0: Text(
                            _getMaleText(),
                            style: TextStyle(
                              fontSize: 14,
                              color: _playerGenderIndex == 0
                                  ? (isDark
                                        ? AppTheme.primaryTextDark
                                        : AppTheme.primaryTextLight)
                                  : (isDark
                                        ? AppTheme.secondaryTextDark
                                        : AppTheme.secondaryTextLight),
                            ),
                          ),
                          1: Text(
                            _getFemaleText(),
                            style: TextStyle(
                              fontSize: 14,
                              color: _playerGenderIndex == 1
                                  ? (isDark
                                        ? AppTheme.primaryTextDark
                                        : AppTheme.primaryTextLight)
                                  : (isDark
                                        ? AppTheme.secondaryTextDark
                                        : AppTheme.secondaryTextLight),
                            ),
                          ),
                        },
                        onValueChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _playerGenderIndex = value;
                            });
                          }
                        },
                      ),
                    ),
                    _buildDivider(context),
                    // 搭档姓名
                    _buildFormRow(
                      context,
                      label: _getNameLabel(isPlayer: false),
                      child: CupertinoTextField(
                        controller: _partnerNameController,
                        placeholder: _getNamePlaceholder(),
                        placeholderStyle: TextStyle(
                          color: isDark
                              ? AppTheme.tertiaryTextDark
                              : AppTheme.tertiaryTextLight,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: null,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.primaryTextDark
                              : AppTheme.primaryTextLight,
                          fontSize: 17,
                        ),
                      ),
                    ),
                    _buildDivider(context),
                    // 搭档性别
                    _buildFormRow(
                      context,
                      label: _getGenderLabel(isPlayer: false),
                      child: CupertinoSlidingSegmentedControl<int>(
                        groupValue: _partnerGenderIndex,
                        children: {
                          0: Text(
                            _getMaleText(),
                            style: TextStyle(
                              fontSize: 14,
                              color: _partnerGenderIndex == 0
                                  ? (isDark
                                        ? AppTheme.primaryTextDark
                                        : AppTheme.primaryTextLight)
                                  : (isDark
                                        ? AppTheme.secondaryTextDark
                                        : AppTheme.secondaryTextLight),
                            ),
                          ),
                          1: Text(
                            _getFemaleText(),
                            style: TextStyle(
                              fontSize: 14,
                              color: _partnerGenderIndex == 1
                                  ? (isDark
                                        ? AppTheme.primaryTextDark
                                        : AppTheme.primaryTextLight)
                                  : (isDark
                                        ? AppTheme.secondaryTextDark
                                        : AppTheme.secondaryTextLight),
                            ),
                          ),
                        },
                        onValueChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _partnerGenderIndex = value;
                            });
                          }
                        },
                      ),
                    ),
                    _buildDivider(context),
                    // 搭档特质
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _getTraitsLabel(),
                            style: TextStyle(
                              fontSize: 15,
                              color: isDark
                                  ? AppTheme.primaryTextDark
                                  : AppTheme.primaryTextLight,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _getTraitsHint(),
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? AppTheme.secondaryTextDark
                                  : AppTheme.secondaryTextLight,
                            ),
                          ),
                          const SizedBox(height: 8),
                          CupertinoTextField(
                            controller: _partnerTraitsController,
                            placeholder: _getOptionalText(),
                            placeholderStyle: TextStyle(
                              color: isDark
                                  ? AppTheme.tertiaryTextDark
                                  : AppTheme.tertiaryTextLight,
                            ),
                            maxLines: 3,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppTheme.fieldBackgroundDark
                                  : AppTheme.fieldBackgroundLight,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isDark
                                    ? AppTheme.inputBorderDark
                                    : AppTheme.inputBorderLight,
                                width: 0.5,
                              ),
                            ),
                            style: TextStyle(
                              color: isDark
                                  ? AppTheme.primaryTextDark
                                  : AppTheme.primaryTextLight,
                              fontSize: 17,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // iOS风格确认按钮
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  onPressed: _onSubmit,
                  borderRadius: BorderRadius.circular(12),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  color: isDark
                      ? AppTheme.buttonFillDark
                      : AppTheme.buttonFillLight,
                  child: Text(
                    _getSubmitText(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.buttonText,
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

  Widget _buildFormRow(
    BuildContext context, {
    required String label,
    required Widget child,
  }) {
    final isDark = AppTheme.isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: isDark
                    ? AppTheme.primaryTextDark
                    : AppTheme.primaryTextLight,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildDivider(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Container(
      height: 0.5,
      margin: const EdgeInsets.only(left: 16),
      color: isDark ? AppTheme.separatorDark : AppTheme.separatorLight,
    );
  }
}
