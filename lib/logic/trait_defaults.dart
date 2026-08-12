/// 主角/配角默认「个人特质」文案生成。
///
/// 规则（按用户设定）：
/// - 性别决定特质文案：男 → 冷峻自傲；女 → 冷艳聪明；
/// - 语言决定文案措辞；
/// - 开头带出用户设定的小说发生地点：{地点}出生长大，{特质}。
///
/// 例：zh 男 → 「上海出生长大，冷峻自傲」；en 女 → 「Shanghai grew up there, Cold and clever」。
String buildDefaultTraits({
  required int genderIndex, // 0=男, 1=女
  required String language,
  required String location,
}) {
  final isMale = genderIndex == 0;
  final loc = location.trim();
  final grewUp = _grewUpIn(language, loc);
  final traits = isMale ? _maleTraits(language) : _femaleTraits(language);
  if (loc.isEmpty) return traits;
  if (_isCjk(language)) {
    return '$grewUp，$traits';
  }
  return '$grewUp, $traits';
}

bool _isCjk(String language) {
  final lang = language;
  return lang == 'zh-TW' ||
      lang == 'yue' ||
      lang == 'ja' ||
      lang == 'ko' ||
      lang.startsWith('zh');
}

/// 「{地点}出生长大」的本地化措辞。
String _grewUpIn(String language, String location) {
  switch (language) {
    case 'zh-TW':
    case 'yue':
      return '$location出生长大';
    case 'en':
      return '$location grew up there';
    case 'es':
      return 'Creció en $location';
    case 'fr':
      return 'A grandi à $location';
    case 'de':
      return 'Aufgewachsen in $location';
    case 'pt':
      return 'Cresceu em $location';
    case 'ja':
      return '$locationで育った';
    case 'ko':
      return '$location에서 자랐다';
    default:
      return '$location出生长大';
  }
}

String _maleTraits(String language) {
  switch (language) {
    case 'zh-TW':
    case 'yue':
      return '冷峻自傲';
    case 'en':
      return 'Cold and proud';
    case 'es':
      return 'Frío y orgulloso';
    case 'fr':
      return 'Froid et fier';
    case 'de':
      return 'Kühl und stolz';
    case 'pt':
      return 'Frio e orgulhoso';
    case 'ja':
      return 'クールで誇り高い';
    case 'ko':
      return '차갑고 자부심 강함';
    default:
      return '冷峻自傲';
  }
}

String _femaleTraits(String language) {
  switch (language) {
    case 'zh-TW':
    case 'yue':
      return '冷艷聰明';
    case 'en':
      return 'Cold and clever';
    case 'es':
      return 'Fría e inteligente';
    case 'fr':
      return 'Froide et intelligente';
    case 'de':
      return 'Kühl und klug';
    case 'pt':
      return 'Fria e inteligente';
    case 'ja':
      return 'クールで聡明';
    case 'ko':
      return '차갑고 영리함';
    default:
      return '冷艳聪明';
  }
}
