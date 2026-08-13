import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/setup_draft.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/text_width.dart';

/// 游戏年代设定页面 - 在地点之后、角色设定之前
class EraSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;

  /// 当前已选语言（用于检测语言是否变化，从而将年代页重置为从未设置过）
  final String? languageKey;

  const EraSetupPage({
    super.key,
    required this.onComplete,
    this.onBack,
    this.languageKey,
  });

  @override
  State<EraSetupPage> createState() => _EraSetupPageState();
}

class _EraSetupPageState extends State<EraSetupPage> {
  final TextEditingController _eraController = TextEditingController();
  final FocusNode _eraFocusNode = FocusNode();
  String _selectedEra = '';
  List<String> _eraOptions = [];

  /// 用户是否已通过选择齿轮选过年代（用于决定第二次打开齿轮时的对准项）
  bool _hasPickedEra = false;

  /// 最近一次加载年代列表所使用的语言（用于检测语言变更）
  String? _loadedLanguage;

  /// 输入字数上限（按显示宽度统计）
  static const int _maxTextLength = 30;

  /// 当前输入是否超过字数上限（宽字符=3、窄字符=1）
  bool get _isOverLimit =>
      weightedCharCount(_eraController.text) > _maxTextLength;

  /// 每种语言对应的默认年代（当代）
  static const _defaultEraByLanguage = {
    'zh-TW': '當代',
    'yue': '當代',
    'en': 'Contemporary',
    'es': 'Contemporáneo',
    'fr': 'Contemporain',
    'de': 'Gegenwart',
    'pt': 'Contemporâneo',
    'ja': '現代',
    'ko': '현대',
    'zh': '当代',
  };

  @override
  void initState() {
    super.initState();
    _eraFocusNode.addListener(_onFocusChange);
    _loadEraOptions();
  }

  @override
  void didUpdateWidget(covariant EraSetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newLanguage = widget.languageKey ?? StorageService.getLanguage();
    if (newLanguage != _loadedLanguage) {
      // 语言发生变化：年代页完全按从未设置过处理
      // （延迟到当前帧结束后重置，避免在 build 过程中调用 setState）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hasPickedEra = false;
        SetupDraft.instance.era = '';
        _loadEraOptions();
      });
    }
  }

  @override
  void dispose() {
    _eraFocusNode.removeListener(_onFocusChange);
    _eraFocusNode.dispose();
    _eraController.dispose();
    super.dispose();
  }

  /// 输入框获得焦点时全选文字，方便直接覆盖
  void _onFocusChange() {
    if (_eraFocusNode.hasFocus && _eraController.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _eraController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _eraController.text.length,
        );
      });
    }
  }

  /// 根据已选语言加载年代选项，默认选中当代；
  /// 若用户此前已确认过年代（进入下一页后返回本页），则恢复该年代而非默认
  void _loadEraOptions() {
    _loadedLanguage = widget.languageKey ?? StorageService.getLanguage();
    final language = StorageService.getLanguage();
    final eras = _getEraOptionsForLanguage(language);
    final defaultEra = _defaultEraByLanguage[language] ?? eras.first;
    // 用户已确认过的年代（点击"确认年代"后保存到草稿）
    final savedEra = SetupDraft.instance.era.trim();
    setState(() {
      _eraOptions = eras;
      if (eras.isNotEmpty) {
        if (savedEra.isNotEmpty) {
          _selectedEra = savedEra;
          _eraController.text = savedEra;
        } else {
          _selectedEra = eras.contains(defaultEra) ? defaultEra : eras.first;
          _eraController.text = _selectedEra;
        }
      }
    });
  }

  /// 根据语言代码返回该语言对应的文学作品常见年代选项
  List<String> _getEraOptionsForLanguage(String language) {
    switch (language) {
      case 'zh':
        return [
          '当代',
          '古代',
          '三国时期',
          '唐朝',
          '宋朝',
          '明朝',
          '清朝',
          '民国时期',
          '改革开放后',
          '架空时代',
        ];
      case 'zh-TW':
        return [
          '當代',
          '古代',
          '三國時期',
          '唐朝',
          '宋朝',
          '明朝',
          '清朝',
          '日治時期',
          '民國時期',
          '架空時代',
        ];
      case 'yue':
        return ['當代', '古代', '三國時期', '唐朝', '宋朝', '明朝', '清朝', '民國時期', '架空時代'];
      case 'en':
        return [
          'Contemporary',
          'Medieval',
          'Renaissance',
          'Victorian Era',
          'Roaring Twenties',
          'WWII Era',
          'Cold War Era',
          'Ancient Greece',
          'Modern',
        ];
      case 'ja':
        return [
          '現代',
          '平安時代',
          '鎌倉時代',
          '戦国時代',
          '江戸時代',
          '明治時代',
          '大正時代',
          '昭和時代',
          '平成時代',
        ];
      case 'ko':
        return ['현대', '고려시대', '조선시대', '일제강점기', '대한제국', '삼국시대'];
      case 'es':
        return [
          'Contemporáneo',
          'Edad Media',
          'Renacimiento',
          'Siglo de Oro',
          'Época Colonial',
          'Independencia',
          'Guerra Civil Española',
        ];
      case 'fr':
        return [
          'Contemporain',
          'Moyen Âge',
          'Renaissance',
          'Grand Siècle',
          'Révolution française',
          'Belle Époque',
          'Années folles',
        ];
      case 'de':
        return [
          'Gegenwart',
          'Mittelalter',
          'Renaissance',
          'Barock',
          'Klassik',
          'Kaiserreich',
          'Weimarer Republik',
        ];
      case 'pt':
        return [
          'Contemporâneo',
          'Idade Média',
          'Renascimento',
          'Era dos Descobrimentos',
          'Brasil Colônia',
          'Império do Brasil',
        ];
      default:
        return [
          'Contemporary',
          'Medieval',
          'Renaissance',
          'Victorian Era',
          'Roaring Twenties',
          'WWII Era',
          'Modern',
        ];
    }
  }

  void _onEraSelected(String era) {
    setState(() {
      _selectedEra = era;
      _eraController.text = era;
      _hasPickedEra = true;
    });
  }

  void _onSubmit() {
    final era = _eraController.text.trim();
    if (era.isEmpty) return;
    SoundService.playConfirm();
    // 保存年代并进入下一步（审核统一在最终确认页进行）
    SetupDraft.instance.era = era;
    widget.onComplete();
  }

  /// 弹出 Cupertino 风格的时代选择器
  ///
  /// 输入框保留用户之前的年代。首次打开齿轮时默认对准该语言默认的
  /// 年代（当代）；若用户已通过齿轮选过年代，则保持用户所选择的年代。
  void _showEraPicker() {
    final fixedList = List<String>.from(_eraOptions);
    var initialIndex;
    if (_hasPickedEra) {
      // 用户已通过齿轮选过年代，保持该选择
      initialIndex = fixedList.indexOf(_selectedEra);
      if (initialIndex < 0) initialIndex = 0;
    } else {
      // 首次打开：对准该语言默认的年代
      final language = StorageService.getLanguage();
      final defaultEra =
          _defaultEraByLanguage[language] ??
          (fixedList.isEmpty ? '' : fixedList.first);
      initialIndex = defaultEra.isEmpty ? 0 : fixedList.indexOf(defaultEra);
      if (initialIndex < 0) initialIndex = 0;
    }
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return _EraPickerWheel(
          eras: fixedList,
          initialIndex: initialIndex,
          onSelectedItemChanged: (int index) {
            _onEraSelected(fixedList[index]);
          },
        );
      },
    );
  }

  /// 根据语言返回本地化的页面标题
  String _getTitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '故事發生在什麼年代？';
      case 'en':
        return 'What time period is your story set in?';
      case 'es':
        return '¿En qué época transcurre tu historia?';
      case 'fr':
        return 'À quelle époque se déroule votre histoire ?';
      case 'de':
        return 'In welcher Zeit spielt Ihre Geschichte?';
      case 'pt':
        return 'Em que época sua história se passa?';
      case 'ja':
        return '物語はどの時代ですか？';
      case 'ko':
        return '이야기는 어떤 시대인가요?';
      default:
        return '故事发生在什么年代？';
    }
  }

  /// 根据语言返回本地化的副标题说明
  String _getSubtitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '請直接輸入時代名稱或從下拉選單中選擇';
      case 'en':
        return 'Type a time period or select from the dropdown';
      case 'es':
        return 'Escriba un período o seleccione del menú desplegable';
      case 'fr':
        return 'Saisissez une période ou choisissez dans le menu déroulant';
      case 'de':
        return 'Geben Sie eine Zeitperiode ein oder wählen Sie aus dem Dropdown-Menü';
      case 'pt':
        return 'Digite um período ou selecione no menu suspenso';
      case 'ja':
        return '時代名を直接入力するか、ドロップダウンメニューから選択してください';
      case 'ko':
        return '시대 이름을 직접 입력하거나 드롭다운 메뉴에서 선택하세요';
      default:
        return '请直接输入时代名称或从下拉菜单中选择';
    }
  }

  /// 根据语言返回确认按钮文字
  String _getConfirmText() {
    switch (StorageService.getLanguage()) {
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

  /// 根据语言返回输入框占位文字
  String _getInputPlaceholder() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '輸入年代或時代名稱';
      case 'en':
        return 'Enter an era or time period';
      case 'es':
        return 'Ingrese una época o período';
      case 'fr':
        return 'Entrez une époque ou une période';
      case 'de':
        return 'Geben Sie eine Epoche oder Zeitperiode ein';
      case 'pt':
        return 'Digite uma era ou período';
      case 'ja':
        return '年代や時代を入力';
      case 'ko':
        return '시대 또는 연대 입력';
      default:
        return '输入年代或时代名称';
    }
  }

  /// 根据语言返回年代提示文字
  String _getEraHint() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '💡 可自由輸入任何歷史時期或自定義時代背景';
      case 'en':
        return '💡 Feel free to enter any historical period or custom era';
      case 'es':
        return '💡 Puede ingresar cualquier período histórico o época personalizada';
      case 'fr':
        return '💡 Vous pouvez saisir n\'importe quelle période historique ou époque personnalisée';
      case 'de':
        return '💡 Sie können jede historische Periode oder eigene Epoche eingeben';
      case 'pt':
        return '💡 Sinta-se à vontade para digitar qualquer período histórico ou era personalizada';
      case 'ja':
        return '💡 歴史的な時代や自由な年代設定を入力できます';
      case 'ko':
        return '💡 역사적 시대나 원하는 시대를 자유롭게 입력할 수 있습니다';
      default:
        return '💡 可自由输入任何历史时期或自定义时代背景';
    }
  }

  /// 根据语言返回年代示例文字
  String _getEraExamples() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
        return '例如：1960、60年代、我小時候';
      case 'yue':
        return '例如：1960、60年代、我細個嗰陣';
      case 'en':
        return 'e.g. 1960, the 60s, my childhood';
      case 'es':
        return 'Por ejemplo: 1960, los años 60, mi infancia';
      case 'fr':
        return 'Exemple : 1960, les années 60, mon enfance';
      case 'de':
        return 'Z. B. 1960, die 60er Jahre, meine Kindheit';
      case 'pt':
        return 'Exemplo: 1960, anos 60, minha infância';
      case 'ja':
        return '例：1960、60年代、子供の頃';
      case 'ko':
        return '예: 1960, 60년대, 내 어린 시절';
      default:
        return '例如：1960、60年代、我小时候';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final canSubmit = !_isOverLimit && _eraController.text.trim().isNotEmpty;
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final buttonTop = constraints.maxHeight * 0.75;
            return Stack(
              children: [
                Positioned.fill(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      24,
                      16,
                      constraints.maxHeight * 0.25,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 20),
                        // 标题 + 副标题（固定高度，保证下方输入框位置一致）
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
                        // 合并输入框 + 下拉选择
                        Container(
                          height: 50,
                          decoration: BoxDecoration(
                            color: isDark
                                ? AppTheme.cardBackgroundDark
                                : AppTheme.cardBackgroundLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: CupertinoTextField(
                            controller: _eraController,
                            focusNode: _eraFocusNode,
                            placeholder: _getInputPlaceholder(),
                            placeholderStyle: TextStyle(
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
                              color: _isOverLimit
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
                            suffix: GestureDetector(
                              onTap: _showEraPicker,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Icon(
                                  CupertinoIcons.chevron_down_circle,
                                  color: isDark
                                      ? AppTheme.accentBlueDark
                                      : AppTheme.accentBlueLight,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 提示 + 示例
                        Column(
                          children: [
                            Text(
                              _getEraHint(),
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? AppTheme.secondaryTextDark
                                    : AppTheme.secondaryTextLight,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _getEraExamples(),
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: isDark
                                    ? AppTheme.tertiaryTextDark
                                    : AppTheme.tertiaryTextLight,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
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
                        _getConfirmText(),
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
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Cupertino 风格的时代选择滚轮弹窗
class _EraPickerWheel extends StatefulWidget {
  final List<String> eras;
  final int initialIndex;
  final ValueChanged<int> onSelectedItemChanged;

  const _EraPickerWheel({
    required this.eras,
    required this.initialIndex,
    required this.onSelectedItemChanged,
  });

  @override
  State<_EraPickerWheel> createState() => _EraPickerWheelState();
}

class _EraPickerWheelState extends State<_EraPickerWheel> {
  /// 当前滚轮停留的索引（默认即初始索引；仅在点 Done 时提交）
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return Container(
      height: 300,
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1C1C1E)
            : CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(14),
          topRight: Radius.circular(14),
        ),
      ),
      child: Column(
        children: [
          // 顶部工具栏
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: isDark
                        ? CupertinoColors.lightBackgroundGray
                        : CupertinoColors.activeBlue,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Text(
                'Era',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: isDark ? CupertinoColors.white : CupertinoColors.black,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Done',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? CupertinoColors.lightBackgroundGray
                        : CupertinoColors.activeBlue,
                  ),
                ),
                onPressed: () {
                  // 即便用户没有拨动滚轮，也提交当前显示的时代（默认项）
                  widget.onSelectedItemChanged(_currentIndex);
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          // 选择滚轮
          Expanded(
            child: CupertinoPicker(
              scrollController: FixedExtentScrollController(
                initialItem: widget.initialIndex,
              ),
              itemExtent: 36,
              onSelectedItemChanged: (index) {
                setState(() {
                  _currentIndex = index;
                });
                widget.onSelectedItemChanged(index);
              },
              children: widget.eras.map((era) {
                return Center(
                  child: Text(
                    era,
                    style: TextStyle(
                      fontSize: 20,
                      color: isDark
                          ? CupertinoColors.white
                          : CupertinoColors.black,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
