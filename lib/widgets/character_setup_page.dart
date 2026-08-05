import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/widgets/audit_dialog.dart';

/// 搭档设定页面 - 性别 + 姓名 + 特质（iOS风格表单）
class CharacterSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;
  final int? playerGenderIndex; // 主角性别: 0=男, 1=女, null=未知

  const CharacterSetupPage({
    super.key,
    required this.onComplete,
    this.onBack,
    this.playerGenderIndex,
  });

  @override
  State<CharacterSetupPage> createState() => _CharacterSetupPageState();
}

class _CharacterSetupPageState extends State<CharacterSetupPage> {
  final TextEditingController _partnerNameController = TextEditingController();
  final TextEditingController _partnerTraitsController =
      TextEditingController();
  final FocusNode _partnerNameFocusNode = FocusNode();

  int _partnerGenderIndex = 1; // 0=男, 1=女，默认女

  /// 标记用户是否已手动编辑过姓名（防止性别切换时覆盖用户输入）
  bool _partnerNameEdited = false;

  /// 防连点标记：审核弹窗打开期间禁止再次提交，避免重复请求触发服务器限流
  bool _submitting = false;

  @override
  void initState() {
    super.initState();

    // 根据主角性别决定搭档默认性别（相反）
    if (widget.playerGenderIndex != null) {
      _partnerGenderIndex = widget.playerGenderIndex == 0 ? 1 : 0;
    }

    // 初始化默认姓名
    _partnerNameController.text = _getDefaultName(
      genderIndex: _partnerGenderIndex,
    );

    // 搭档姓名监听
    _partnerNameFocusNode.addListener(() {
      if (_partnerNameFocusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _partnerNameController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _partnerNameController.text.length,
          );
        });
        if (!_partnerNameEdited) {
          setState(() {
            _partnerNameEdited = true;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _partnerNameController.dispose();
    _partnerTraitsController.dispose();
    _partnerNameFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CharacterSetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playerGenderIndex != null &&
        widget.playerGenderIndex != oldWidget.playerGenderIndex) {
      setState(() {
        _partnerGenderIndex = widget.playerGenderIndex == 0 ? 1 : 0;
        if (!_partnerNameEdited) {
          _partnerNameController.text = _getDefaultName(
            genderIndex: _partnerGenderIndex,
          );
        }
      });
    }
  }

  // ──────────────────────────────────────────────
  // 默认姓名体系（按语言 x 性别）
  // ──────────────────────────────────────────────

  /// 获取当前语言的代码
  String get _language => StorageService.getLanguage();

  /// 获取搭档的默认姓名
  String _getDefaultName({required int genderIndex}) {
    final lang = _language;
    final isMale = genderIndex == 0;

    return isMale
        ? _getPartnerMaleDefault(lang)
        : _getPartnerFemaleDefault(lang);
  }

  /// 搭档 - 男性默认姓名
  String _getPartnerMaleDefault(String language) {
    switch (language) {
      case 'zh-TW':
      case 'yue':
        return '陳子豪';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'James';
      case 'ja':
        return '大輔';
      case 'ko':
        return '준호';
      default:
        return '陈子豪';
    }
  }

  /// 搭档 - 女性默认姓名
  String _getPartnerFemaleDefault(String language) {
    switch (language) {
      case 'zh-TW':
      case 'yue':
        return '陳雨晴';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Emma';
      case 'ja':
        return '結衣';
      case 'ko':
        return '은지';
      default:
        return '陈雨晴';
    }
  }

  /// 当性别切换时更新默认姓名（仅当用户未手动编辑过）
  void _onPartnerGenderChanged(int? value) {
    if (value == null || value == _partnerGenderIndex) return;
    setState(() {
      _partnerGenderIndex = value;
      if (!_partnerNameEdited) {
        _partnerNameController.text = _getDefaultName(genderIndex: value);
      }
    });
  }

  void _onSubmit() {
    // 防止连点重复弹出审核弹窗、重复请求服务器
    if (_submitting) return;
    final partnerName = _partnerNameController.text.trim();
    final partnerTraits = _partnerTraitsController.text.trim();
    if (partnerName.isEmpty || partnerTraits.isEmpty) return;
    _submitting = true;
    SoundService.playHorror2();

    // 向服务器传输的内容 = 用户选择的姓名 + 换行 + 用户对搭档性格的设定文字
    final auditText = '$partnerName\n$partnerTraits';

    // 弹出审核弹窗，调取服务器审核器（AWS Guard）进行审核；
    // 审核通过（Action: NONE）时保存搭档设定并进入下一步，未通过时弹窗警告
    showCupertinoDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AuditDialog(
        text: auditText,
        onApproved: () {
          StorageService.savePartnerName(partnerName);
          StorageService.savePartnerGender(
              _partnerGenderIndex == 0 ? '男' : '女');
          StorageService.savePartnerTraits(partnerTraits);
          StorageService.setInitialized();
          widget.onComplete();
        },
      ),
    ).then((_) {
      // 弹窗关闭后（拒绝/出错）允许再次提交
      _submitting = false;
    });
  }

  /// 根据语言返回本地化的标题
  String _getTitleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '接下來，設定您的搭檔。';
      case 'en':
        return 'Now, set up your partner.';
      case 'es':
        return 'Ahora, configura a tu compañero/a.';
      case 'fr':
        return 'Maintenant, configurez votre partenaire.';
      case 'de':
        return 'Jetzt richtest du deinen Partner ein.';
      case 'pt':
        return 'Agora, configure seu parceiro/sua parceira.';
      case 'ja':
        return '次に、パートナーを設定しましょう。';
      case 'ko':
        return '이제 파트너를 설정해보세요.';
      default:
        return '接下来，设定您的搭档。';
    }
  }

  /// 根据语言返回本地化的副标题
  String _getSubtitleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '他（她）將是您在遊戲中的搭檔及曖昧對象。';
      case 'en':
        return 'They will be your partner and love interest in the game.';
      case 'es':
        return 'Será tu compañero/a e interés amoroso en el juego.';
      case 'fr':
        return 'Il/Elle sera votre partenaire et intérêt amoureux dans le jeu.';
      case 'de':
        return 'Er/Sie wird dein Partner und Liebesinteresse im Spiel sein.';
      case 'pt':
        return 'Ele/Ela será seu parceiro e interesse amoroso no jogo.';
      case 'ja':
        return 'ゲーム中のパートナーであり恋愛対象です。';
      case 'ko':
        return '그或그녀는 게임에서 당신의 파트너이자 연애 상대입니다.';
      default:
        return '他（她）将是您在游戏中的搭档及暧昧对象。';
    }
  }

  /// 根据语言返回本地化的"姓名"标签
  String _getNameLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '搭檔及曖昧對象姓名';
      case 'en':
        return 'Partner & Love Interest Name';
      case 'es':
        return 'Nombre del Compañero/a e Interés Amoroso';
      case 'fr':
        return 'Nom du Partenaire et Intérêt Amoureux';
      case 'de':
        return 'Name des Partners & Liebesinteresses';
      case 'pt':
        return 'Nome do Parceiro e Interesse Amoroso';
      case 'ja':
        return 'パートナー＆恋愛対象の名前';
      case 'ko':
        return '파트너 및 연애 상대 이름';
      default:
        return '搭档及暧昧对象姓名';
    }
  }

  /// 根据语言返回本地化的"性别"标签
  String _getGenderLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '他（她）的性別';
      case 'en':
        return 'Their Gender';
      case 'es':
        return 'Su Género';
      case 'fr':
        return 'Leur Genre';
      case 'de':
        return 'Ihr Geschlecht';
      case 'pt':
        return 'O Gênero Dele/Dela';
      case 'ja':
        return 'パートナーの性別';
      case 'ko':
        return '파트너의 성별';
      default:
        return '他（她）的性别';
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

  /// 根据语言返回本地化的"完成設定"文字
  String _getSubmitText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '完成設定';
      case 'en':
        return 'Done';
      case 'es':
        return 'Hecho';
      case 'fr':
        return 'Terminé';
      case 'de':
        return 'Fertig';
      case 'pt':
        return 'Concluído';
      case 'ja':
        return '設定完了';
      case 'ko':
        return '설정 완료';
      default:
        return '完成设定';
    }
  }

  /// 根据语言返回特质标签
  String _getTraitsLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '他（她）的個人特質';
      case 'en':
        return 'Their Personal Traits';
      case 'es':
        return 'Sus Rasgos Personales';
      case 'fr':
        return 'Leurs Traits Personnels';
      case 'de':
        return 'Ihre Persönlichen Eigenschaften';
      case 'pt':
        return 'Suas Características Pessoais';
      case 'ja':
        return 'パートナーの特徴';
      case 'ko':
        return '파트너의 특징';
      default:
        return '他（她）的个人特质';
    }
  }

  /// 根据语言返回特质提示
  String _getTraitsHint() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '性格、外貌、喜好等，請輸入您對搭檔的設定。';
      case 'en':
        return 'Personality, appearance, hobbies, etc. Describe your partner.';
      case 'es':
        return 'Personalidad, apariencia, pasatiempos, etc. Describe a tu pareja.';
      case 'fr':
        return 'Personnalité, apparence, loisirs, etc. Décrivez votre partenaire.';
      case 'de':
        return 'Persönlichkeit, Aussehen, Hobbys usw. Beschreiben Sie Ihren Partner.';
      case 'pt':
        return 'Personalidade, aparência, hobbies, etc. Descreva seu parceiro.';
      case 'ja':
        return '性格、外見、趣味など、パートナーの設定を入力してください。';
      case 'ko':
        return '성격, 외모, 취미 등 파트너의 설정을 입력하세요.';
      default:
        return '性格、外貌、喜好等，请输入您对搭档的设定。';
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
    // 姓名与特质均非空时才能提交
    final canSubmit =
        _partnerNameController.text.trim().isNotEmpty &&
        _partnerTraitsController.text.trim().isNotEmpty;
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
                        onValueChanged: _onPartnerGenderChanged,
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
                        controller: _partnerNameController,
                        focusNode: _partnerNameFocusNode,
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
              const SizedBox(height: 16),
              // 个人特质卡片
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
                            controller: _partnerTraitsController,
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
                              color: isDark
                                  ? AppTheme.primaryTextDark
                                  : AppTheme.primaryTextLight,
                              fontSize: 17,
                            ),
                            onChanged: (value) {
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
              // iOS风格完成按钮
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
                    _getSubmitText(),
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

  /// 根据语言返回 placeholder
  String _getNamePlaceholder() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請輸入姓名';
      case 'en':
      case 'es':
      case 'fr':
      case 'de':
      case 'pt':
        return 'Enter name';
      case 'ja':
        return '名前を入力';
      case 'ko':
        return '이름 입력';
      default:
        return '请输入姓名';
    }
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
