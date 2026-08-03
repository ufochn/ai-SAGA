import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/auth_service.dart';
import 'package:ai_saga/logic/storage_service.dart';
import 'package:ai_saga/logic/sound_service.dart';

/// 游戏地点设定页面 - 在语言选择之后、角色设定之前
class LocationSetupPage extends StatefulWidget {
  final VoidCallback onComplete;
  final VoidCallback? onBack;

  const LocationSetupPage({super.key, required this.onComplete, this.onBack});

  @override
  State<LocationSetupPage> createState() => _LocationSetupPageState();
}

class _LocationSetupPageState extends State<LocationSetupPage> {
  final TextEditingController _locationController = TextEditingController();
  final FocusNode _locationFocusNode = FocusNode();
  String _selectedCity = '';
  List<String> _cityOptions = [];

  @override
  void initState() {
    super.initState();
    _locationFocusNode.addListener(_onFocusChange);
    _loadCityOptions();
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

  /// 根据已选语言加载城市列表，默认选中该语言最有名的城市
  void _loadCityOptions() {
    final language = StorageService.getLanguage();
    final cities = _getCitiesForLanguage(language);
    final defaultCity = _defaultCityByLanguage[language] ?? cities.first;
    setState(() {
      _cityOptions = cities;
      if (cities.isNotEmpty) {
        _selectedCity = cities.contains(defaultCity)
            ? defaultCity
            : cities.first;
        _locationController.text = _selectedCity;
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
    });
  }

  void _onSubmit() {
    final location = _locationController.text.trim();
    if (location.isEmpty) return;
    SoundService.playConfirm();

    // 弹出审核弹窗，调取服务器审核器（AWS Guard）进行审核；
    // 审核通过（Action: NONE）时保存地点并进入下一步，未通过时弹窗警告
    showCupertinoDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _AuditDialog(
        text: location,
        onApproved: () {
          StorageService.saveLocation(location);
          widget.onComplete();
        },
      ),
    );
  }

  /// 弹出 Cupertino 风格的城市选择器
  void _showCityPicker() {
    final fixedList = List<String>.from(_cityOptions);
    final initialIndex = fixedList.indexOf(_selectedCity);
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) {
        return _CityPickerWheel(
          cities: fixedList,
          initialIndex: initialIndex >= 0 ? initialIndex : 0,
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
                    color: isDark
                        ? AppTheme.primaryTextDark
                        : AppTheme.primaryTextLight,
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
                  onPressed: _locationController.text.trim().isNotEmpty
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
                    _getConfirmText(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _locationController.text.trim().isNotEmpty
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

/// 审核弹窗 - 调取服务器审核器（AWS Guard）进行审核。
/// 等待期间显示"正在审核输入，请稍后"；收到结果后：
/// - 若为 Action: NONE（通过）→ 自动保存地点并进入下一步；
/// - 若不为 Action: NONE（不通过）→ 以当前语言弹出警告，提示内容可能不合适需修改。
class _AuditDialog extends StatefulWidget {
  final String text;
  final VoidCallback onApproved;

  const _AuditDialog({required this.text, required this.onApproved});

  @override
  State<_AuditDialog> createState() => _AuditDialogState();
}

class _AuditDialogState extends State<_AuditDialog> {
  /// 审核服务器地址（读取自 .env 环境变量）
  String get _auditApiUrl => dotenv.env['AUDIT_API_URL'] ?? '';

  bool _loading = true;
  bool _approved = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _callAuditServer();
  }

  /// 调用审核服务器，等待审核结果
  Future<void> _callAuditServer() async {
    try {
      // 环境变量缺失时给出明确提示，避免用空配置发起请求
      if (_auditApiUrl.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _errorMessage = getConfigMissingMessage();
        });
        return;
      }

      // 获取服务器签发的审核令牌（未注册或已过期时自动注册），
      // 令牌保存在系统安全存储中，不再在 App 内保存任何共享密钥
      final token = await AuthService.ensureToken();

      final response = await http
          .post(
            Uri.parse(_auditApiUrl),
            headers: {
              'accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'user_id': StorageService.getUserUniqueId(),
              'text': widget.text,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      if (_isActionNone(response.body)) {
        // 审核通过：短暂展示通过提示后，自动关闭弹窗并进入下一步
        setState(() {
          _loading = false;
          _approved = true;
        });
        Future.delayed(const Duration(milliseconds: 900), () {
          if (!mounted) return;
          Navigator.of(context).pop();
          widget.onApproved();
        });
      } else {
        // 审核未通过：以当前语言弹出警告（未通过为默认状态）
        setState(() {
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e.toString();
      });
    }
  }

  /// 判断服务器返回的审核结果是否为 Action: NONE（通过）。
  /// 兼容 JSON 字段（如 action / guardrailAction = NONE）与文本（如 "Action: NONE"）。
  bool _isActionNone(String body) {
    try {
      final decoded = jsonDecode(body);
      return _findActionNone(decoded);
    } catch (_) {
      // 非 JSON，直接全文搜索
      return body.toLowerCase().contains('action: none');
    }
  }

  /// 递归搜索 JSON 中表示"审核通过（NONE）"的节点
  bool _findActionNone(dynamic node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value;
        // 字段名含 action 且值为 NONE（AWS Guard 常返回 guardrailAction）
        if (key.contains('action') &&
            value is String &&
            value.trim().toUpperCase() == 'NONE') {
          return true;
        }
        if (_findActionNone(value)) return true;
      }
    } else if (node is List) {
      for (final item in node) {
        if (_findActionNone(item)) return true;
      }
    } else if (node is String && node.toLowerCase().contains('action: none')) {
      return true;
    }
    return false;
  }

  String get _language => StorageService.getLanguage();

  // 等待时的标题文字
  String getWaitingTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '正在審核輸入，請稍後';
      case 'en':
        return 'Auditing Input, Please Wait…';
      case 'es':
        return 'Auditando la Entrada, Espere…';
      case 'fr':
        return 'Audit de la Saisie, Veuillez Patienter…';
      case 'de':
        return 'Eingabe wird geprüft, bitte warten…';
      case 'pt':
        return 'Auditando a Entrada, Aguarde…';
      case 'ja':
        return '入力を審査中です。少々お待ちください…';
      case 'ko':
        return '입력을 심사 중입니다. 잠시 기다려 주세요…';
      default:
        return '正在审核输入，请稍后';
    }
  }

  // 等待时的说明文字
  String getWaitingMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '正在等待服務器返回審核結果…';
      case 'en':
        return 'Waiting for the audit server response…';
      case 'es':
        return 'Esperando la respuesta del servidor de auditoría…';
      case 'fr':
        return 'En attente de la réponse du serveur d\'audit…';
      case 'de':
        return 'Warten auf die Antwort des Prüfservers…';
      case 'pt':
        return 'Aguardando a resposta do servidor de auditoria…';
      case 'ja':
        return '審査サーバーの応答を待っています…';
      case 'ko':
        return '심사 서버 응답을 기다리는 중…';
      default:
        return '正在等待服务器返回审核结果…';
    }
  }

  // 审核失败时的标题文字
  String getErrorTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '審核失敗';
      case 'en':
        return 'Audit Failed';
      case 'es':
        return 'Error de Auditoría';
      case 'fr':
        return 'Échec de l\'Audit';
      case 'de':
        return 'Prüfung fehlgeschlagen';
      case 'pt':
        return 'Falha na Auditoria';
      case 'ja':
        return '審査に失敗しました';
      case 'ko':
        return '심사 실패';
      default:
        return '审核失败';
    }
  }

  // 环境变量缺失时的提示文字
  String getConfigMissingMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '伺服器設定缺失，請在 .env 中設定 AUDIT_API_URL 與 REGISTER_API_URL。';
      case 'en':
        return 'Server configuration is missing. Please set AUDIT_API_URL and REGISTER_API_URL in the .env file.';
      case 'es':
        return 'Falta la configuración del servidor. Configure AUDIT_API_URL y REGISTER_API_URL en el archivo .env.';
      case 'fr':
        return 'La configuration du serveur est manquante. Définissez AUDIT_API_URL et REGISTER_API_URL dans le fichier .env.';
      case 'de':
        return 'Serverkonfiguration fehlt. Bitte setzen Sie AUDIT_API_URL und REGISTER_API_URL in der .env-Datei.';
      case 'pt':
        return 'Falta a configuração do servidor. Defina AUDIT_API_URL e REGISTER_API_URL no arquivo .env.';
      case 'ja':
        return 'サーバー設定がありません。.env ファイルで AUDIT_API_URL と REGISTER_API_URL を設定してください。';
      case 'ko':
        return '서버 설정이 없습니다. .env 파일에서 AUDIT_API_URL과 REGISTER_API_URL을 설정해 주세요.';
      default:
        return '服务器配置缺失，请在 .env 中设置 AUDIT_API_URL 与 REGISTER_API_URL。';
    }
  }

  // 审核通过时的标题文字
  String getApprovedTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '審核通過';
      case 'en':
        return 'Approved';
      case 'es':
        return 'Aprobado';
      case 'fr':
        return 'Approuvé';
      case 'de':
        return 'Genehmigt';
      case 'pt':
        return 'Aprovado';
      case 'ja':
        return '審査に合格しました';
      case 'ko':
        return '승인됨';
      default:
        return '审核通过';
    }
  }

  // 审核通过时的说明文字
  String getApprovedMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您輸入的地點已通過審核，即將進入下一步…';
      case 'en':
        return 'Your location has been approved. Moving on…';
      case 'es':
        return 'Su ubicación ha sido aprobada. Continuando…';
      case 'fr':
        return 'Votre lieu a été approuvé. Continuons…';
      case 'de':
        return 'Ihr Standort wurde genehmigt. Weiter…';
      case 'pt':
        return 'Seu local foi aprovado. Continuando…';
      case 'ja':
        return '入力した場所は審査に合格しました。次のステップへ進みます…';
      case 'ko':
        return '입력한 장소가 승인되었습니다. 다음 단계로 이동합니다…';
      default:
        return '您输入的地点已通过审核，即将进入下一步…';
    }
  }

  // 审核未通过时的标题文字
  String getRejectedTitle() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '請修改您的內容';
      case 'en':
        return 'Please Revise Your Input';
      case 'es':
        return 'Revise Su Entrada';
      case 'fr':
        return 'Veuillez Modifier Votre Saisie';
      case 'de':
        return 'Bitte Eingabe Überarbeiten';
      case 'pt':
        return 'Revise Sua Entrada';
      case 'ja':
        return '入力内容を修正してください';
      case 'ko':
        return '입력 내용을 수정해 주세요';
      default:
        return '请修改您的内容';
    }
  }

  // 审核未通过时的警告文字
  String getRejectedMessage() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '您輸入的內容可能有些不合適，請修改後再試。';
      case 'en':
        return 'Your input may not be suitable. Please review and revise it before trying again.';
      case 'es':
        return 'Su entrada puede no ser adecuada. Revísela y modifíquela antes de volver a intentarlo.';
      case 'fr':
        return 'Votre saisie peut ne pas convenir. Veuillez la revoir et la modifier avant de réessayer.';
      case 'de':
        return 'Ihre Eingabe ist möglicherweise nicht geeignet. Bitte überprüfen und ändern Sie sie, bevor Sie es erneut versuchen.';
      case 'pt':
        return 'Sua entrada pode não ser adequada. Revise-a e modifique-a antes de tentar novamente.';
      case 'ja':
        return '入力した内容が適切でない可能性があります。修正してからもう一度お試しください。';
      case 'ko':
        return '입력한 내용이 적절하지 않을 수 있습니다. 수정한 후 다시 시도해 주세요.';
      default:
        return '您输入的内容可能有些不合适，请修改后再试。';
    }
  }

  // 关闭按钮文字
  String getCloseText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '關閉';
      case 'en':
        return 'Close';
      case 'ja':
        return '閉じる';
      case 'ko':
        return '닫기';
      default:
        return '关闭';
    }
  }

  // "知道了"按钮文字
  String getGotItText() {
    switch (_language) {
      case 'zh-TW':
      case 'yue':
        return '知道了';
      case 'en':
        return 'OK';
      case 'es':
        return 'Aceptar';
      case 'fr':
        return 'OK';
      case 'de':
        return 'OK';
      case 'pt':
        return 'OK';
      case 'ja':
        return '了解';
      case 'ko':
        return '확인';
      default:
        return '知道了';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);

    final title = _loading
        ? getWaitingTitle()
        : (_errorMessage != null
              ? getErrorTitle()
              : (_approved ? getApprovedTitle() : getRejectedTitle()));

    // 等待中或已通过时无按钮（通过后自动进入下一步）
    final actions = _loading || _approved
        ? const <Widget>[]
        : <Widget>[
            CupertinoDialogAction(
              child: Text(
                _errorMessage != null ? getCloseText() : getGotItText(),
                style: TextStyle(
                  color: isDark
                      ? AppTheme.accentBlueDark
                      : AppTheme.accentBlueLight,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ];

    return CupertinoAlertDialog(
      title: Text(
        title,
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: isDark ? AppTheme.primaryTextDark : AppTheme.primaryTextLight,
        ),
      ),
      content: _buildContent(isDark),
      actions: actions,
    );
  }

  /// 根据审核状态构建弹窗内容
  Widget _buildContent(bool isDark) {
    // 等待审核结果中
    if (_loading) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CupertinoActivityIndicator(),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  getWaitingMessage(),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark
                        ? AppTheme.secondaryTextDark
                        : AppTheme.secondaryTextLight,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    // 审核失败
    if (_errorMessage != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          SelectableText(
            _errorMessage!,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark
                  ? AppTheme.secondaryTextDark
                  : AppTheme.secondaryTextLight,
            ),
          ),
        ],
      );
    }

    // 审核通过（Action: NONE）
    if (_approved) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 4),
          const Icon(
            CupertinoIcons.checkmark_alt_circle_fill,
            color: Color(0xFF34C759),
            size: 44,
          ),
          const SizedBox(height: 10),
          Text(
            getApprovedMessage(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: isDark
                  ? AppTheme.secondaryTextDark
                  : AppTheme.secondaryTextLight,
            ),
          ),
        ],
      );
    }

    // 审核未通过（Action 非 NONE）：以当前语言弹出警告
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        const Icon(
          CupertinoIcons.exclamationmark_triangle_fill,
          color: Color(0xFFFF9F0A),
          size: 44,
        ),
        const SizedBox(height: 10),
        Text(
          getRejectedMessage(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: isDark
                ? AppTheme.secondaryTextDark
                : AppTheme.secondaryTextLight,
          ),
        ),
      ],
    );
  }
}

/// Cupertino 风格的城市选择滚轮弹窗
class _CityPickerWheel extends StatelessWidget {
  final List<String> cities;
  final int initialIndex;
  final ValueChanged<int> onSelectedItemChanged;

  const _CityPickerWheel({
    required this.cities,
    required this.initialIndex,
    required this.onSelectedItemChanged,
  });

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
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          // 选择滚轮
          Expanded(
            child: CupertinoPicker(
              scrollController: FixedExtentScrollController(
                initialItem: initialIndex,
              ),
              itemExtent: 36,
              onSelectedItemChanged: onSelectedItemChanged,
              children: cities.map((city) {
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
