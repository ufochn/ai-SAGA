import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/widgets/audit_dialog.dart';

/// 主角设定页面 - 性别 + 姓名（iOS风格表单）
class PlayerSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;

  const PlayerSetupPage({super.key, required this.onComplete, this.onBack});

  @override
  State<PlayerSetupPage> createState() => _PlayerSetupPageState();
}

class _PlayerSetupPageState extends State<PlayerSetupPage> {
  final TextEditingController _playerNameController = TextEditingController();
  final FocusNode _playerNameFocusNode = FocusNode();

  int _playerGenderIndex = 0; // 0=男, 1=女

  /// 标记用户是否已手动编辑过姓名（防止性别切换时覆盖用户输入）
  bool _playerNameEdited = false;

  /// 防连点标记：审核弹窗打开期间禁止再次提交，避免重复请求触发服务器限流
  bool _submitting = false;

  @override
  void initState() {
    super.initState();

    // 初始化默认姓名
    _playerNameController.text = _getDefaultName(
      genderIndex: _playerGenderIndex,
    );

    // 玩家姓名监听：光标全选
    _playerNameFocusNode.addListener(() {
      if (_playerNameFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _playerNameController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _playerNameController.text.length,
          );
        });
        if (!_playerNameEdited) {
          setState(() {
            _playerNameEdited = true;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _playerNameController.dispose();
    _playerNameFocusNode.dispose();
    super.dispose();
  }

  // ──────────────────────────────────────────────
  // 默认姓名体系（按语言 x 性别）
  // ──────────────────────────────────────────────

  /// 获取当前语言的代码
  String get _language => StorageService.getLanguage();

  /// 获取主角的默认姓名
  String _getDefaultName({required int genderIndex}) {
    final lang = _language;
    final isMale = genderIndex == 0;

    return isMale ? _getPlayerMaleDefault(lang) : _getPlayerFemaleDefault(lang);
  }

  /// 玩家 - 男性默认姓名
  String _getPlayerMaleDefault(String language) {
    switch (language) {
      case 'zh-TW':
      case 'yue':
        return '陸一鳴';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Jimmy';
      case 'ja':
        return '蓮';
      case 'ko':
        return '민준';
      default:
        return '陆一鸣';
    }
  }

  /// 玩家 - 女性默认姓名
  String _getPlayerFemaleDefault(String language) {
    switch (language) {
      case 'zh-TW':
      case 'yue':
        return '林語嫣';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Aurora';
      case 'ja':
        return '琴音';
      case 'ko':
        return '아린';
      default:
        return '林语嫣';
    }
  }

  /// 当性别切换时更新默认姓名（仅当用户未手动编辑过）
  void _onPlayerGenderChanged(int? value) {
    if (value == null || value == _playerGenderIndex) return;
    setState(() {
      _playerGenderIndex = value;
      if (!_playerNameEdited) {
        _playerNameController.text = _getDefaultName(genderIndex: value);
      }
    });
  }

  void _onSubmit() {
    // 防止连点重复弹出审核弹窗、重复请求服务器
    if (_submitting) return;
    final playerName = _playerNameController.text.trim();
    if (playerName.isEmpty) return;
    _submitting = true;
    SoundService.playHorror2();

    // 弹出审核弹窗，调取服务器审核器（AWS Guard）进行审核；
    // 审核通过（Action: NONE）时保存主角设定并进入下一步，未通过时弹窗警告
    showCupertinoDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AuditDialog(
        text: playerName,
        onApproved: () {
          StorageService.savePlayerName(playerName);
          StorageService.savePlayerGender(
              _playerGenderIndex == 0 ? '男' : '女');
          widget.onComplete();
        },
      ),
    ).then((_) {
      // 弹窗关闭后（拒绝/出错）允许再次提交
      _submitting = false;
    });
  }

  /// 根据语言返回本地化的欢迎标题
  String _getTitleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '歡迎您進入這個冒險探案戀愛遊戲。';
      case 'en':
        return 'Welcome to this adventure detective romance game.';
      case 'es':
        return 'Bienvenido a este juego de aventura, detectives y romance.';
      case 'fr':
        return 'Bienvenue dans ce jeu d\'aventure, de détective et de romance.';
      case 'de':
        return 'Willkommen zu diesem Abenteuer-Detektiv-Liebes-Spiel.';
      case 'pt':
        return 'Bem-vindo a este jogo de aventura, detetive e romance.';
      case 'ja':
        return 'この冒険探偵恋愛ゲームへようこそ。';
      case 'ko':
        return '이 모험 탐정 연애 게임에 오신 것을 환영합니다.';
      default:
        return '欢迎您进入这个冒险探案恋爱游戏。';
    }
  }

  /// 根据语言返回本地化的副标题
  String _getSubtitleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '先來設定您自己的角色吧。';
      case 'en':
        return 'First, let\'s set up your own character.';
      case 'es':
        return 'Primero, configuremos tu propio personaje.';
      case 'fr':
        return 'D\'abord, configurons votre personnage.';
      case 'de':
        return 'Lass uns zuerst deinen eigenen Charakter einrichten.';
      case 'pt':
        return 'Primeiro, vamos configurar seu próprio personagem.';
      case 'ja':
        return 'まずはあなた自身のキャラクターを設定しましょう。';
      case 'ko':
        return '먼저 자신의 캐릭터를 설정해보세요.';
      default:
        return '先来设定您自己的角色吧。';
    }
  }

  /// 根据语言返回本地化的"姓名"标签
  String _getNameLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您在遊戲中的姓名';
      case 'en':
        return 'Your Name';
      case 'es':
        return 'Tu Nombre';
      case 'fr':
        return 'Votre Nom';
      case 'de':
        return 'Dein Name';
      case 'pt':
        return 'Seu Nome';
      case 'ja':
        return 'あなたの名前';
      case 'ko':
        return '당신의 이름';
      default:
        return '您在游戏中的姓名';
    }
  }

  /// 根据语言返回本地化的"性别"标签
  String _getGenderLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您的性別';
      case 'en':
        return 'Your Gender';
      case 'es':
        return 'Tu Género';
      case 'fr':
        return 'Votre Genre';
      case 'de':
        return 'Dein Geschlecht';
      case 'pt':
        return 'Seu Gênero';
      case 'ja':
        return 'あなたの性別';
      case 'ko':
        return '당신의 성별';
      default:
        return '您的性别';
    }
  }

  /// 根据语言返回本地化的性别选项
  String _getMaleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '男';
      case 'en':
        return 'Male';
      case 'es':
        return 'Masculino';
      case 'fr':
        return 'Masculin';
      case 'de':
        return 'Männlich';
      case 'pt':
        return 'Masculino';
      case 'ja':
        return '男性';
      case 'ko':
        return '남성';
      default:
        return '男';
    }
  }

  String _getFemaleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '女';
      case 'en':
        return 'Female';
      case 'es':
        return 'Femenino';
      case 'fr':
        return 'Féminin';
      case 'de':
        return 'Weiblich';
      case 'pt':
        return 'Feminino';
      case 'ja':
        return '女性';
      case 'ko':
        return '여성';
      default:
        return '女';
    }
  }

  /// 根据语言返回本地化的"下一步"文字
  String _getNextText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
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

  /// 根据语言返回 placeholder
  String _getNamePlaceholder() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請輸入姓名';
      case 'en':
        return 'Enter name';
      case 'es':
        return 'Introduce tu nombre';
      case 'fr':
        return 'Entrez votre nom';
      case 'de':
        return 'Name eingeben';
      case 'pt':
        return 'Insira seu nome';
      case 'ja':
        return '名前を入力';
      case 'ko':
        return '이름 입력';
      default:
        return '请输入姓名';
    }
  }

  /// 根据语言返回编辑提示（更直观醒目）
  String _getEditHint() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '✏️ 可自由更改';
      case 'en':
        return '✏️ Feel free to edit';
      case 'es':
        return '✏️ Siéntete libre de editarlo';
      case 'fr':
        return '✏️ Modifiable librement';
      case 'de':
        return '✏️ Frei änderbar';
      case 'pt':
        return '✏️ Sinta-se livre para editar';
      case 'ja':
        return '✏️ 自由に変更できます';
      case 'ko':
        return '✏️ 자유롭게 변경 가능';
      default:
        return '✏️ 可自由更改';
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
              // 性别选择卡片
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.cardBackgroundDark
                      : AppTheme.cardBackgroundLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _buildFormRow(
                      context,
                      label: _getGenderLabel(),
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
                        onValueChanged: _onPlayerGenderChanged,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // 姓名输入卡片
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.cardBackgroundDark
                      : AppTheme.cardBackgroundLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _buildFormRow(
                      context,
                      label: _getNameLabel(),
                      child: CupertinoTextField(
                        controller: _playerNameController,
                        focusNode: _playerNameFocusNode,
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
                        onChanged: (value) {
                          setState(() {});
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 12,
                        bottom: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.pencil,
                            size: 14,
                            color: isDark
                                ? AppTheme.secondaryTextDark
                                : AppTheme.secondaryTextLight,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _getEditHint().replaceAll('✏️ ', ''),
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? AppTheme.secondaryTextDark
                                  : AppTheme.secondaryTextLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // iOS风格下一步按钮
              SizedBox(
                height: 48,
                child: CupertinoButton.filled(
                  onPressed: _playerNameController.text.trim().isNotEmpty
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
                    _getNextText(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _playerNameController.text.trim().isNotEmpty
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
}
