/// 按"显示宽度"统计字数的工具。
///
/// 规则：宽字符（汉字/日文假名/韩文谚文/全角符号等）按 3 字计，
/// 窄字符（英文字母/数字/ASCII 标点）按 1 字计。
library;

/// 计算文本的加权字数（宽字符=3，窄字符=1）。
int weightedCharCount(String text) {
  var count = 0;
  for (final rune in text.runes) {
    count += isWideChar(rune) ? 3 : 1;
  }
  return count;
}

/// 特质输入是否超过字数上限（宽字符=3、窄字符=1，全部累加不超过 150）。
bool isTraitsOverLimit(String text) => weightedCharCount(text) > 150;

/// 是否为宽字符（一个汉字/日文/韩文 ≈ 两个英文字母的宽度）。
bool isWideChar(int r) {
  if (r >= 0x1100 && r <= 0x11FF) return true; // 谚文字母
  if (r >= 0x2E80 && r <= 0x2EFF) return true; // CJK 部首补充
  if (r >= 0x3000 && r <= 0x303F) return true; // CJK 标点
  if (r >= 0x3040 && r <= 0x30FF) return true; // 平假名/片假名
  if (r >= 0x3130 && r <= 0x318F) return true; // 谚文兼容字母
  if (r >= 0x3400 && r <= 0x4DBF) return true; // CJK 扩展A
  if (r >= 0x4E00 && r <= 0x9FFF) return true; // CJK 统一表意文字
  if (r >= 0xAC00 && r <= 0xD7A3) return true; // 谚文音节
  if (r >= 0xF900 && r <= 0xFAFF) return true; // CJK 兼容表意文字
  if (r >= 0xFF00 && r <= 0xFF60) return true; // 全角符号
  if (r >= 0xFFE0 && r <= 0xFFE6) return true; // 全角 ¥ 等
  if (r >= 0x20000 && r <= 0x2FFFD) return true; // CJK 扩展B 起
  return false;
}
