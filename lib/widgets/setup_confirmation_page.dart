import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/setup_draft.dart';
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

  /// 左上角"返回"回调：跳回上一页（搭档设定）
  final VoidCallback onBack;

  const SetupConfirmationPage({
    super.key,
    required this.onEdit,
    required this.onConfirmed,
    required this.onBack,
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

  /// 将存储的性别（'男'/'女'）转换为当前语言的显示文本
  String _genderText(String gender) {
    switch (gender) {
      case '男':
        return _getMaleText();
      case '女':
        return _getFemaleText();
      default:
        return gender.isEmpty ? '—' : gender;
    }
  }

  /// 根据语言返回本地化的"男性"文本
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

  /// 根据语言返回本地化的"女性"文本
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

  /// 根据语言返回本地化的"语言"标签
  String _getLanguageLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '語言';
      case 'en':
        return 'Language';
      case 'es':
        return 'Idioma';
      case 'fr':
        return 'Langue';
      case 'de':
        return 'Sprache';
      case 'pt':
        return 'Idioma';
      case 'ja':
        return '言語';
      case 'ko':
        return '언어';
      default:
        return '语言';
    }
  }

  /// 根据语言返回本地化的"地点"标签
  String _getLocationLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '地點';
      case 'en':
        return 'Location';
      case 'es':
        return 'Ubicación';
      case 'fr':
        return 'Lieu';
      case 'de':
        return 'Standort';
      case 'pt':
        return 'Local';
      case 'ja':
        return '場所';
      case 'ko':
        return '위치';
      default:
        return '地点';
    }
  }

  /// 根据语言返回本地化的"年代"标签
  String _getEraLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '年代';
      case 'en':
        return 'Era';
      case 'es':
        return 'Época';
      case 'fr':
        return 'Époque';
      case 'de':
        return 'Epoche';
      case 'pt':
        return 'Era';
      case 'ja':
        return '時代';
      case 'ko':
        return '시대';
      default:
        return '年代';
    }
  }

  /// 根据语言返回本地化的"主角"标签
  String _getPlayerLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '主角';
      case 'en':
        return 'Protagonist';
      case 'es':
        return 'Protagonista';
      case 'fr':
        return 'Protagoniste';
      case 'de':
        return 'Protagonist';
      case 'pt':
        return 'Protagonista';
      case 'ja':
        return '主人公';
      case 'ko':
        return '주인공';
      default:
        return '主角';
    }
  }

  /// 根据语言返回本地化的"搭档"标签
  String _getPartnerLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '搭檔';
      case 'en':
        return 'Partner';
      case 'es':
        return 'Compañero/a';
      case 'fr':
        return 'Partenaire';
      case 'de':
        return 'Partner';
      case 'pt':
        return 'Parceiro/a';
      case 'ja':
        return 'パートナー';
      case 'ko':
        return '파트너';
      default:
        return '搭档';
    }
  }

  /// 根据语言返回本地化的"性别"标签
  String _getGenderLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '性別';
      case 'en':
        return 'Gender';
      case 'es':
        return 'Género';
      case 'fr':
        return 'Genre';
      case 'de':
        return 'Geschlecht';
      case 'pt':
        return 'Gênero';
      case 'ja':
        return '性別';
      case 'ko':
        return '성별';
      default:
        return '性别';
    }
  }

  /// 根据语言返回本地化的"姓名"标签
  String _getNameLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '姓名';
      case 'en':
        return 'Name';
      case 'es':
        return 'Nombre';
      case 'fr':
        return 'Nom';
      case 'de':
        return 'Name';
      case 'pt':
        return 'Nome';
      case 'ja':
        return '名前';
      case 'ko':
        return '이름';
      default:
        return '姓名';
    }
  }

  /// 根据语言返回本地化的"性格设定"标签
  String _getTraitsLabel() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '性格設定';
      case 'en':
        return 'Personality';
      case 'es':
        return 'Personalidad';
      case 'fr':
        return 'Personnalité';
      case 'de':
        return 'Persönlichkeit';
      case 'pt':
        return 'Personalidade';
      case 'ja':
        return '性格設定';
      case 'ko':
        return '성격 설정';
      default:
        return '性格设定';
    }
  }

  /// 根据语言返回本地化的"编辑"文字
  String _getEditText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '編輯';
      case 'en':
        return 'Edit';
      case 'es':
        return 'Editar';
      case 'fr':
        return 'Modifier';
      case 'de':
        return 'Bearbeiten';
      case 'pt':
        return 'Editar';
      case 'ja':
        return '編集';
      case 'ko':
        return '편집';
      default:
        return '编辑';
    }
  }

  /// 根据语言返回本地化的页面主标题
  String _getTitleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return _counting ? '準備就緒' : '確認您的設定';
      case 'en':
        return _counting ? 'Ready' : 'Confirm Your Settings';
      case 'es':
        return _counting ? 'Listo' : 'Confirma tu configuración';
      case 'fr':
        return _counting ? 'Prêt' : 'Confirmez vos paramètres';
      case 'de':
        return _counting ? 'Bereit' : 'Bestätige deine Einstellungen';
      case 'pt':
        return _counting ? 'Pronto' : 'Confirme suas configurações';
      case 'ja':
        return _counting ? '準備完了' : '設定を確認してください';
      case 'ko':
        return _counting ? '준비 완료' : '설정을 확인하세요';
      default:
        return _counting ? '准备就绪' : '确认你的设定';
    }
  }

  /// 根据语言返回本地化的页面副标题
  String _getSubtitleText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return _counting
            ? '現在開始進入全新的世界，敬請期待'
            : '以下是您本次冒險的設定，可點擊「編輯」隨時修改';
      case 'en':
        return _counting
            ? 'A brand-new world awaits you. Get ready!'
            : 'These are your adventure settings. Tap "Edit" to change them anytime.';
      case 'es':
        return _counting
            ? 'Un mundo nuevo te espera. ¡Prepárate!'
            : 'Estas son tus configuraciones de aventura. Toca "Editar" para cambiarlas cuando quieras.';
      case 'fr':
        return _counting
            ? 'Un tout nouveau monde vous attend. Préparez-vous !'
            : 'Voici les paramètres de votre aventure. Touchez « Modifier » pour les changer à tout moment.';
      case 'de':
        return _counting
            ? 'Eine brandneue Welt erwartet dich. Mach dich bereit!'
            : 'Dies sind deine Abenteuer-Einstellungen. Tippe auf „Bearbeiten“, um sie jederzeit zu ändern.';
      case 'pt':
        return _counting
            ? 'Um mundo totalmente novo espera por você. Prepare-se!'
            : 'Estas são as configurações da sua aventura. Toque em "Editar" para alterá-las a qualquer momento.';
      case 'ja':
        return _counting
            ? '新しい世界へようこそ。お楽しみに！'
            : 'これがあなたの冒険の設定です。「編集」をタップしていつでも変更できます。';
      case 'ko':
        return _counting
            ? '새로운 세계가 당신을 기다립니다. 기대하세요!'
            : '이것은 당신의 모험 설정입니다. 언제든지 "편집"을 눌러 변경할 수 있습니다.';
      default:
        return _counting
            ? '现在开始进入全新的世界，请期待'
            : '以下是你本次冒险的设定，可点击"编辑"随时修改';
    }
  }

  /// 根据语言返回本地化的"确定"按钮文字
  String _getConfirmButtonText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '確定';
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
        return '確定';
      case 'ko':
        return '확인';
      default:
        return '确定';
    }
  }

  /// 根据语言返回本地化的"正在进入全新的世界"文字
  String _getEnteringText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '正在進入全新的世界…';
      case 'en':
        return 'Entering a brand-new world…';
      case 'es':
        return 'Entrando a un mundo nuevo…';
      case 'fr':
        return 'Entrée dans un tout nouveau monde…';
      case 'de':
        return 'Betreten einer brandneuen Welt…';
      case 'pt':
        return 'Entrando em um mundo novo…';
      case 'ja':
        return '新しい世界に入っています…';
      case 'ko':
        return '새로운 세계로 들어가는 중…';
      default:
        return '正在进入全新的世界…';
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

  /// 左上角"返回"：取消倒计时并跳回上一页（搭档设定）
  void _onBackPressed() {
    _timer?.cancel();
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);

    final items = <({String label, String value, int index})>[
      (label: _getLanguageLabel(), value: _languageName(_language), index: 0),
      (
        label: _getLocationLabel(),
        value: SetupDraft.instance.location,
        index: 1
      ),
      (label: _getEraLabel(), value: SetupDraft.instance.era, index: 2),
    ];

    return CupertinoPageScaffold(
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _onBackPressed,
          child: Icon(
            CupertinoIcons.back,
            color: isDark
                ? AppTheme.accentBlueDark
                : AppTheme.accentBlueLight,
          ),
        ),
        backgroundColor: isDark
            ? AppTheme.pageBackgroundDark
            : AppTheme.pageBackgroundLight,
        border: null,
      ),
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
                      _getTitleText(),
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
                      _getSubtitleText(),
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
                      _buildCharacterCard(
                        isDark,
                        label: _getPlayerLabel(),
                        gender: _genderText(SetupDraft.instance.playerGender),
                        name: SetupDraft.instance.playerName,
                        traits: null,
                        onEdit: () => widget.onEdit(3),
                      ),
                      _buildCharacterCard(
                        isDark,
                        label: _getPartnerLabel(),
                        gender: _genderText(SetupDraft.instance.partnerGender),
                        name: SetupDraft.instance.partnerName,
                        traits: SetupDraft.instance.partnerTraits,
                        onEdit: () => widget.onEdit(4),
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
                  child: Text(
                    _getConfirmButtonText(),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600),
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
            width: 100,
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
              _getEditText(),
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

  /// 主角/搭档卡片：性别、姓名、性格设定逐项清晰展示
  Widget _buildCharacterCard(
    bool isDark, {
    required String label,
    required String gender,
    required String name,
    required String? traits,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
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
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: onEdit,
                child: Text(
                  _getEditText(),
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
          const SizedBox(height: 6),
          _buildCharacterRow(isDark, _getGenderLabel(), gender),
          _buildCharacterRow(isDark, _getNameLabel(), name),
          if (traits != null && traits.isNotEmpty)
            _buildCharacterRow(isDark, _getTraitsLabel(), traits),
        ],
      ),
    );
  }

  Widget _buildCharacterRow(bool isDark, String field, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              field,
              style: TextStyle(
                fontSize: 15,
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
          _getEnteringText(),
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
