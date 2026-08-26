/// 主角默认「个人特质」文案生成。
///
/// 规则：
/// - 主角固定为男性（早期版本可选性别、有搭档的功能已废弃），默认特质为「冷峻自傲」；
/// - 语言决定文案措辞。
///
/// 例：zh → 「冷峻自傲」；en → 「Cold and proud」。
String buildDefaultTraits({
  required String language,
  String location = '', // 兼容保留参数（不再使用）
}) {
  return _traits(language);
}

String _traits(String language) {
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
