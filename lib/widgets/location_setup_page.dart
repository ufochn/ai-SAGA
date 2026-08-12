import 'package:flutter/cupertino.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/setup_draft.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';
import 'package:ai_saga/logic/text_width.dart';

/// 游戏地点设定页面 - 在语言选择之后、角色设定之前
class LocationSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;

  /// 当前已选语言（用于检测语言是否变化，从而将地名页重置为从未设置过）
  final String? languageKey;

  const LocationSetupPage({
    super.key,
    required this.onComplete,
    this.onBack,
    this.languageKey,
  });

  @override
  State<LocationSetupPage> createState() => _LocationSetupPageState();
}

class _LocationSetupPageState extends State<LocationSetupPage> {
  final TextEditingController _locationController = TextEditingController();
  final FocusNode _locationFocusNode = FocusNode();
  String _selectedCity = '';
  List<String> _cityOptions = [];

  /// 用户是否已通过选择齿轮选过城市（用于决定第二次打开齿轮时的对准项）
  bool _hasPickedCity = false;

  /// 最近一次加载城市列表所使用的语言（用于检测语言变更）
  String? _loadedLanguage;

  /// 输入字数上限（按显示宽度统计）
  static const int _maxTextLength = 30;

  /// 当前输入是否超过字数上限（宽字符=3、窄字符=1）
  bool get _isOverLimit =>
      weightedCharCount(_locationController.text) > _maxTextLength;

  @override
  void initState() {
    super.initState();
    _locationFocusNode.addListener(_onFocusChange);
    _loadCityOptions();
  }

  @override
  void didUpdateWidget(covariant LocationSetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newLanguage = widget.languageKey ?? StorageService.getLanguage();
    if (newLanguage != _loadedLanguage) {
      // 语言发生变化：地名页完全按从未设置过处理
      // （延迟到当前帧结束后重置，避免在 build 过程中调用 setState）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hasPickedCity = false;
        SetupDraft.instance.location = '';
        _loadCityOptions();
      });
    }
  }

  @override
  void dispose() {
    _locationFocusNode.removeListener(_onFocusChange);
    _locationFocusNode.dispose();
    _locationController.dispose();
    super.dispose();
  }

  /// 输入框获得焦点时全选文字，方便直接覆盖
  void _onFocusChange() {
    if (_locationFocusNode.hasFocus && _locationController.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _locationController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _locationController.text.length,
        );
      });
    }
  }

  /// 每种语言对应的默认（最有名）城市
  static const _defaultCityByLanguage = {
    'en': 'New York',
    'ja': '東京',
    'es': 'Madrid',
    'fr': 'Paris',
    'de': 'Berlin',
    'pt': 'Lisbon',
    'zh-TW': '台北',
    'yue': '香港',
    'zh': '上海',
    'ko': '서울',
  };

  /// 根据已选语言加载城市列表，默认选中该语言最有名的城市；
  /// 若用户此前已确认过地点（进入下一页后返回本页），则恢复该地点而非默认城市
  void _loadCityOptions() {
    _loadedLanguage = widget.languageKey ?? StorageService.getLanguage();
    final language = StorageService.getLanguage();
    final cities = _getCitiesForLanguage(language);
    final defaultCity = _defaultCityByLanguage[language] ?? cities.first;
    // 用户已确认过的地点（点击"确认地点"后保存到草稿）
    final savedLocation = SetupDraft.instance.location.trim();
    setState(() {
      _cityOptions = cities;
      if (cities.isNotEmpty) {
        if (savedLocation.isNotEmpty) {
          _selectedCity = savedLocation;
          _locationController.text = savedLocation;
        } else {
          _selectedCity = cities.contains(defaultCity)
              ? defaultCity
              : cities.first;
          _locationController.text = _selectedCity;
        }
      }
    });
  }

  /// 根据语言代码返回该语⾔对应的国际主要城市列表（已按字母排序）
  List<String> _getCitiesForLanguage(String language) {
    switch (language) {
      case 'en':
        return [
          'Amsterdam',
          'Auckland',
          'Bangkok',
          'Barcelona',
          'Berlin',
          'Brussels',
          'Chicago',
          'Dubai',
          'Dublin',
          'Geneva',
          'Hong Kong',
          'Istanbul',
          'Lisbon',
          'London',
          'Los Angeles',
          'Madrid',
          'Melbourne',
          'Miami',
          'Milan',
          'Mumbai',
          'New York',
          'Paris',
          'Prague',
          'Rome',
          'San Francisco',
          'São Paulo',
          'Seoul',
          'Shanghai',
          'Singapore',
          'Stockholm',
          'Sydney',
          'Tokyo',
          'Toronto',
          'Vancouver',
          'Vienna',
          'Washington D.C.',
        ];
      case 'ja':
        return ['福岡', '広島', '神戸', '京都', '名古屋', '大阪', '札幌', '仙台', '東京', '横浜'];
      case 'es':
        return [
          'Barcelona',
          'Bogotá',
          'Buenos Aires',
          'Caracas',
          'Havana',
          'La Paz',
          'Lima',
          'Madrid',
          'Málaga',
          'Managua',
          'Medellín',
          'Mexico City',
          'Montevideo',
          'Panama City',
          'Quito',
          'San José',
          'San Juan',
          'San Salvador',
          'Santiago',
          'Santo Domingo',
          'Seville',
          'Valencia',
        ];
      case 'fr':
        return [
          'Bordeaux',
          'Brussels',
          'Geneva',
          'Lille',
          'Lyon',
          'Marseille',
          'Montreal',
          'Nantes',
          'Nice',
          'Paris',
          'Strasbourg',
          'Toulouse',
          'Tunis',
        ];
      case 'de':
        return [
          'Berlin',
          'Bern',
          'Köln',
          'Frankfurt',
          'Hamburg',
          'München',
          'Stuttgart',
          'Wien',
          'Zürich',
        ];
      case 'pt':
        return [
          'Brasília',
          'Lisbon',
          'Luanda',
          'Maputo',
          'Porto',
          'Recife',
          'Rio de Janeiro',
          'Salvador',
          'São Paulo',
        ];
      case 'zh-TW':
        return ['台北', '台中', '台南', '高雄', '桃園', '新竹'];
      case 'yue':
        return ['广州', '深圳', '香港', '澳门', '佛山', '东莞'];
      case 'zh':
        return [
          '北京',
          '成都',
          '重庆',
          '广州',
          '杭州',
          '南京',
          '上海',
          '深圳',
          '苏州',
          '天津',
          '武汉',
          '西安',
          '厦门',
        ];
      case 'ko':
        return ['부산', '대구', '대전', '광주', '인천', '제주', '서울', '수원', '울산'];
      default:
        return [
          'Amsterdam',
          'Auckland',
          'Bangkok',
          'Barcelona',
          'Berlin',
          'Brussels',
          'Chicago',
          'Dubai',
          'Dublin',
          'Geneva',
          'Hong Kong',
          'Istanbul',
          'Lisbon',
          'London',
          'Los Angeles',
          'Madrid',
          'Melbourne',
          'Miami',
          'Milan',
          'Mumbai',
          'New York',
          'Paris',
          'Prague',
          'Rome',
          'San Francisco',
          'São Paulo',
          'Seoul',
          'Shanghai',
          'Singapore',
          'Stockholm',
          'Sydney',
          'Tokyo',
          'Toronto',
          'Vancouver',
          'Vienna',
          'Washington D.C.',
        ];
    }
  }

  void _onCitySelected(String city) {
    setState(() {
      _selectedCity = city;
      _locationController.text = city;
      _hasPickedCity = true;
    });
  }

  void _onSubmit() {
    final location = _locationController.text.trim();
    if (location.isEmpty) return;
    SoundService.playConfirm();
    // 保存地点并进入下一步（审核统一在最终确认页进行）
    SetupDraft.instance.location = location;
    widget.onComplete();
  }

  /// 弹出 Cupertino 风格的城市选择器
  ///
  /// 输入框保留用户之前的地名。首次打开齿轮时默认对准该语言最著名的
  /// 默认城市；若用户已通过齿轮选过城市，则保持用户所选择的城市。
  void _showCityPicker() {
    final fixedList = List<String>.from(_cityOptions);
    var initialIndex;
    if (_hasPickedCity) {
      // 用户已通过齿轮选过城市，保持该选择
      initialIndex = fixedList.indexOf(_selectedCity);
      if (initialIndex < 0) initialIndex = 0;
    } else {
      // 首次打开：对准该语言最著名的默认城市
      final language = StorageService.getLanguage();
      final defaultCity =
          _defaultCityByLanguage[language] ??
          (fixedList.isEmpty ? '' : fixedList.first);
      initialIndex = defaultCity.isEmpty ? 0 : fixedList.indexOf(defaultCity);
      if (initialIndex < 0) initialIndex = 0;
    }
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return _CityPickerWheel(
          cities: fixedList,
          initialIndex: initialIndex,
          onSelectedItemChanged: (int index) {
            _onCitySelected(fixedList[index]);
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
        return '請選擇故事發生的地點';
      case 'en':
        return 'Where does your story take place?';
      case 'es':
        return '¿Dónde ocurre tu historia?';
      case 'fr':
        return 'Où se déroule votre histoire ?';
      case 'de':
        return 'Wo spielt Ihre Geschichte?';
      case 'pt':
        return 'Onde sua história acontece?';
      case 'ja':
        return '物語の舞台を選んでください';
      case 'ko':
        return '이야기의 배경을 선택하세요';
      default:
        return '请选择故事发生的地点';
    }
  }

  /// 根据语言返回本地化的副标题说明
  String _getSubtitleText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '請直接輸入城市名稱或從下拉選單中選擇';
      case 'en':
        return 'Type a city name or select from the dropdown';
      case 'es':
        return 'Escriba el nombre de una ciudad o seleccione del menú desplegable';
      case 'fr':
        return 'Saisissez un nom de ville ou choisissez dans le menu déroulant';
      case 'de':
        return 'Geben Sie einen Stadtnamen ein oder wählen Sie aus dem Dropdown-Menü';
      case 'pt':
        return 'Digite o nome de uma cidade ou selecione no menu suspenso';
      case 'ja':
        return '都市名を直接入力するか、ドロップダウンメニューから選択してください';
      case 'ko':
        return '도시 이름을 직접 입력하거나 드롭다운 메뉴에서 선택하세요';
      default:
        return '请直接输入城市名字或在下拉菜单中选择';
    }
  }

  /// 根据语言返回输入框占位文字
  String _getInputPlaceholder() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '輸入城市或地點名稱';
      case 'en':
        return 'Enter a city or location';
      case 'es':
        return 'Ingrese una ciudad o lugar';
      case 'fr':
        return 'Entrez une ville ou un lieu';
      case 'de':
        return 'Geben Sie eine Stadt oder einen Ort ein';
      case 'pt':
        return 'Digite uma cidade ou local';
      case 'ja':
        return '都市名や地名を入力';
      case 'ko':
        return '도시 또는 장소 입력';
      default:
        return '输入城市或地点名称';
    }
  }

  /// 根据语言返回确认按钮文字
  String _getConfirmText() {
    switch (StorageService.getLanguage()) {
      case 'zh-TW':
      case 'yue':
        return '確認地點';
      case 'en':
        return 'Confirm Location';
      case 'es':
        return 'Confirmar Ubicación';
      case 'fr':
        return 'Confirmer le Lieu';
      case 'de':
        return 'Standort Bestätigen';
      case 'pt':
        return 'Confirmar Local';
      case 'ja':
        return '場所を確定';
      case 'ko':
        return '장소 확인';
      default:
        return '确认地点';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final canSubmit =
        !_isOverLimit && _locationController.text.trim().isNotEmpty;
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
              const SizedBox(height: 20),
              // 页面标题
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
              // 说明文字
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
              // 合并输入框 + 下拉选择 - 既可输入文字，又可点击右侧按钮选择城市
              Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.cardBackgroundDark
                      : AppTheme.cardBackgroundLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: CupertinoTextField(
                  controller: _locationController,
                  focusNode: _locationFocusNode,
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
                    onTap: _showCityPicker,
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
              // 提示：可随意填写任何地点 + 示例
              Column(
                children: [
                  Text(
                    switch (StorageService.getLanguage()) {
                      'zh-TW' || 'yue' => '💡 您可以自由填寫任何城市、國家或自訂地點',
                      'en' =>
                        '💡 Feel free to enter any city, country, or custom location',
                      'es' =>
                        '💡 Puede ingresar cualquier ciudad, país o lugar personalizado',
                      'fr' =>
                        '💡 Vous pouvez saisir n\'importe quelle ville, pays ou lieu personnalisé',
                      'de' =>
                        '💡 Sie können jede Stadt, jedes Land oder einen eigenen Ort eingeben',
                      'pt' =>
                        '💡 Sinta-se à vontade para digitar qualquer cidade, país ou local personalizado',
                      'ja' => '💡 都市、国、または自由な場所を入力できます',
                      'ko' => '💡 도시, 국가 또는 원하는 장소를 자유롭게 입력할 수 있습니다',
                      _ => '💡 您可以自由填写任何城市、国家或自定义地点',
                    },
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
                    switch (StorageService.getLanguage()) {
                      'zh-TW' => '例如：我家鄉的小鎮\n      某個封閉鄉村',
                      'yue' => '例如：我鄉下嘅小鎮\n      某個封閉鄉村',
                      'en' =>
                        'e.g. A small town in Tuscany\n     A remote village in Iceland',
                      'es' =>
                        'Por ejemplo: Un pueblo pequeño en Andalucía\n             Una aldea remota en los Andes',
                      'fr' =>
                        'Exemple : Un petit village en Provence\n          Une campagne isolée en Bretagne',
                      'de' =>
                        'Z. B. Ein kleines Dorf in Bayern\n     Ein abgelegener Ort in den Alpen',
                      'pt' =>
                        'Exemplo: Uma pequena cidade no interior\n         Uma vila remota no Alentejo',
                      'ja' => '例：田舎の小さな町\n      どこかの閉ざされた村',
                      'ko' => '예: 고향의 작은 마을\n     어느 외딴 마을',
                      _ => '例如：我故乡的小镇\n      某个封闭乡村',
                    },
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
              const SizedBox(height: 24),
              // 确认按钮
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
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cupertino 风格的城市选择滚轮弹窗
class _CityPickerWheel extends StatefulWidget {
  final List<String> cities;
  final int initialIndex;
  final ValueChanged<int> onSelectedItemChanged;

  const _CityPickerWheel({
    required this.cities,
    required this.initialIndex,
    required this.onSelectedItemChanged,
  });

  @override
  State<_CityPickerWheel> createState() => _CityPickerWheelState();
}

class _CityPickerWheelState extends State<_CityPickerWheel> {
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
                'City',
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
                  // 即便用户没有拨动滚轮，也提交当前显示的地名（默认项）
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
              children: widget.cities.map((city) {
                return Center(
                  child: Text(
                    city,
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
