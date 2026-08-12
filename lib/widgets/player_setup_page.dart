import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/setup_draft.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/text_width.dart';
import 'package:ai_saga/logic/trait_defaults.dart';

/// 主角设定页面 - 性别 + 姓名（iOS风格表单）
class PlayerSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;

  /// 当前已选语言（用于检测语言是否变化，从而将主角页重置为从未设置过）
  final String? languageKey;

  const PlayerSetupPage({
    super.key,
    required this.onComplete,
    this.onBack,
    this.languageKey,
  });

  @override
  State<PlayerSetupPage> createState() => _PlayerSetupPageState();
}

class _PlayerSetupPageState extends State<PlayerSetupPage> {
  final TextEditingController _playerNameController = TextEditingController();
  final TextEditingController _playerTraitsController = TextEditingController();
  final FocusNode _playerNameFocusNode = FocusNode();

  int _playerGenderIndex = 0; // 0=男, 1=女

  /// 标记用户是否已手动编辑过姓名（防止性别切换时覆盖用户输入）
  bool _playerNameEdited = false;

  /// 标记用户是否已手动编辑过特质（防止性别切换时覆盖用户输入）
  bool _playerTraitsEdited = false;

  /// 最近一次加载姓名所使用的语言（用于检测语言变更）
  String? _loadedLanguage;

  /// 姓名输入字数上限（按显示宽度统计）
  static const int _maxNameLength = 30;

  /// 当前姓名是否超过字数上限（宽字符=3、窄字符=1）
  bool get _isNameOverLimit =>
      weightedCharCount(_playerNameController.text) > _maxNameLength;

  /// 当前主角性格特质是否超过字数上限
  /// （宽字符按 3 计、窄字符按 1 计，全部累加不超过 150）
  bool get _isTraitsOverLimit =>
      isTraitsOverLimit(_playerTraitsController.text);

  @override
  void initState() {
    super.initState();

    // 若此前已确认过主角（进入下一页后返回本页），恢复性别与姓名，否则用默认
    final savedGender = SetupDraft.instance.playerGender;
    if (savedGender == '女') {
      _playerGenderIndex = 1;
    } else if (savedGender == '男') {
      _playerGenderIndex = 0;
    }
    final savedName = SetupDraft.instance.playerName.trim();
    _playerNameController.text = savedName.isNotEmpty
        ? savedName
        : _getDefaultName(genderIndex: _playerGenderIndex);
    // 特质默认值：按性别 + 语言自动填入；用户此前已确认过则恢复已保存值
    final savedTraits = SetupDraft.instance.playerTraits.trim();
    _playerTraitsController.text = savedTraits.isNotEmpty
        ? savedTraits
        : buildDefaultTraits(
            genderIndex: _playerGenderIndex,
            language: _language,
            location: SetupDraft.instance.location,
          );

    // 记录当前已加载语言（用于检测语言变更）
    _loadedLanguage = widget.languageKey ?? StorageService.getLanguage();

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
  void didUpdateWidget(covariant PlayerSetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newLanguage = widget.languageKey ?? StorageService.getLanguage();
    if (newLanguage != _loadedLanguage) {
      // 语言发生变化：主角页完全按从未设置过处理
      // （延迟到当前帧结束后重置，避免在 build 过程中调用 setState）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _playerNameEdited = false;
        _playerGenderIndex = 0;
        SetupDraft.instance.playerName = '';
        SetupDraft.instance.playerGender = '';
        SetupDraft.instance.playerTraits = '';
        _playerNameController.text = _getDefaultName(
          genderIndex: _playerGenderIndex,
        );
        _playerTraitsEdited = false;
        _playerTraitsController.text = buildDefaultTraits(
          genderIndex: _playerGenderIndex,
          language: newLanguage,
          location: SetupDraft.instance.location,
        );
        _loadedLanguage = widget.languageKey ?? StorageService.getLanguage();
      });
    }
  }

  @override
  void dispose() {
    _playerNameController.dispose();
    _playerTraitsController.dispose();
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
      if (!_playerTraitsEdited) {
        // 性别切换时，特质输入框随性别自动换成对应的默认文案
        _playerTraitsController.text = buildDefaultTraits(
          genderIndex: value,
          language: _language,
          location: SetupDraft.instance.location,
        );
      }
    });
  }

  void _onSubmit() {
    final playerName = _playerNameController.text.trim();
    final playerTraits = _playerTraitsController.text.trim();
    if (playerName.isEmpty || playerTraits.isEmpty) return;
    SoundService.playHorror2();
    // 保存主角设定并进入下一步（审核统一在最终确认页进行）
    SetupDraft.instance.playerName = playerName;
    SetupDraft.instance.playerGender = _playerGenderIndex == 0 ? '男' : '女';
    SetupDraft.instance.playerTraits = playerTraits;
    widget.onComplete();
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

  /// 根据语言返回特质标签
  String _getTraitsLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您的個人特質';
      case 'en':
        return 'Your Personal Traits';
      case 'es':
        return 'Tus Rasgos Personales';
      case 'fr':
        return 'Vos Traits Personnels';
      case 'de':
        return 'Deine Persönlichen Eigenschaften';
      case 'pt':
        return 'Suas Características Pessoais';
      case 'ja':
        return 'あなたの特徴';
      case 'ko':
        return '당신의 특징';
      default:
        return '您的个人特质';
    }
  }

  /// 根据语言返回特质提示
  String _getTraitsHint() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '性格、外貌、喜好等，請輸入您對主角的設定。';
      case 'en':
        return 'Personality, appearance, hobbies, etc. Describe your character.';
      case 'es':
        return 'Personalidad, apariencia, pasatiempos, etc. Describe a tu personaje.';
      case 'fr':
        return 'Personnalité, apparence, loisirs, etc. Décrivez votre personnage.';
      case 'de':
        return 'Persönlichkeit, Aussehen, Hobbys usw. Beschreiben Sie Ihren Charakter.';
      case 'pt':
        return 'Personalidade, aparência, hobbies, etc. Descreva seu personagem.';
      case 'ja':
        return '性格、外見、趣味など、あなたのキャラクターの設定を入力してください。';
      case 'ko':
        return '성격, 외모, 취미 등 자신의 캐릭터 설정을 입력하세요.';
      default:
        return '性格、外貌、喜好等，请输入您对主角的设定。';
    }
  }

  /// 根据语言返回特质输入框占位文字
  String _getTraitsPlaceholder() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請輸入性格、外貌、喜好等';
      case 'en':
        return 'Enter personality, appearance, hobbies, etc.';
      case 'es':
        return 'Ingrese personalidad, apariencia, pasatiempos, etc.';
      case 'fr':
        return 'Saisissez la personnalité, l\'apparence, les loisirs, etc.';
      case 'de':
        return 'Persönlichkeit, Aussehen, Hobbys usw. eingeben';
      case 'pt':
        return 'Digite personalidade, aparência, hobbies, etc.';
      case 'ja':
        return '性格、外見、趣味などを入力';
      case 'ko':
        return '성격, 외모, 취미 등을 입력하세요';
      default:
        return '请输入性格、外貌、喜好等';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final canSubmit =
        !_isNameOverLimit &&
        !_isTraitsOverLimit &&
        _playerNameController.text.trim().isNotEmpty &&
        _playerTraitsController.text.trim().isNotEmpty;
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
                          color: _isNameOverLimit
                              ? (isDark
                                    ? AppTheme.destructiveRedDark
                                    : AppTheme.destructiveRedLight)
                              : (isDark
                                    ? AppTheme.primaryTextDark
                                    : AppTheme.primaryTextLight),
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
              const SizedBox(height: 16),
              // 主角性格特质卡片
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.cardBackgroundDark
                      : AppTheme.cardBackgroundLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
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
                          const SizedBox(height: 12),
                          CupertinoTextField(
                            controller: _playerTraitsController,
                            placeholder: _getTraitsPlaceholder(),
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
                              color: _isTraitsOverLimit
                                  ? (isDark
                                        ? AppTheme.destructiveRedDark
                                        : AppTheme.destructiveRedLight)
                                  : (isDark
                                        ? AppTheme.primaryTextDark
                                        : AppTheme.primaryTextLight),
                              fontSize: 17,
                            ),
                            onChanged: (value) {
                              // 用户手动输入后，性别切换不再覆盖其自定义内容
                              _playerTraitsEdited = true;
                              setState(() {});
                            },
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
                  onPressed: canSubmit ? _onSubmit : null,
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
                      color: canSubmit
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
