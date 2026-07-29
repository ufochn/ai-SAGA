import 'package:flutter/cupertino.dart';

/// Apple HIG 兼容的深色/浅色主题颜色工具
///
/// 根据 Apple Human Interface Guidelines 推荐的配色方案：
///   浅色模式: 白底黑字, 蓝色 #007AFF
///   深色模式: 黑底白字, 蓝色 #0A84FF
class AppTheme {
  AppTheme._();

  /// 判断当前是否为深色模式
  static bool isDark(BuildContext context) =>
      CupertinoTheme.of(context).brightness == Brightness.dark;

  // ──────────────────────────────────────────────
  // 页面背景 (Apple HIG: systemGroupedBackground)
  // ──────────────────────────────────────────────
  /// 最底层页面背景: 浅色 #F2F2F7 / 深色 #000000
  static Color get pageBackgroundLight => const Color(0xFFF2F2F7);
  static Color get pageBackgroundDark => const Color(0xFF000000);

  // ──────────────────────────────────────────────
  // 卡片/列表项背景 (Apple HIG: secondarySystemGroupedBackground)
  // ──────────────────────────────────────────────
  /// 卡片背景: 浅色 #FFFFFF / 深色 #1C1C1E
  static Color get cardBackgroundLight => const Color(0xFFFFFFFF);
  static Color get cardBackgroundDark => const Color(0xFF1C1C1E);

  // ──────────────────────────────────────────────
  // 输入框/文本域背景 (Apple HIG: tertiarySystemGroupedBackground)
  // ──────────────────────────────────────────────
  /// 输入框背景: 浅色 #F2F2F7 / 深色 #2C2C2E
  static Color get fieldBackgroundLight => const Color(0xFFF2F2F7);
  static Color get fieldBackgroundDark => const Color(0xFF2C2C2E);

  // ──────────────────────────────────────────────
  // 文字颜色 (Apple HIG Label Colors)
  // ──────────────────────────────────────────────
  /// 主文字: 浅色 #000000 / 深色 #FFFFFF
  static Color get primaryTextLight => const Color(0xFF000000);
  static Color get primaryTextDark => const Color(0xFFFFFFFF);

  /// 次要文字: 浅色 #3C3C43 / 深色 #98989D
  static Color get secondaryTextLight => const Color(0xFF3C3C43);
  static Color get secondaryTextDark => const Color(0xFF98989D);

  /// 占位/说明文字: 浅色 #8E8E93 / 深色 #636366
  static Color get tertiaryTextLight => const Color(0xFF8E8E93);
  static Color get tertiaryTextDark => const Color(0xFF636366);

  // ──────────────────────────────────────────────
  // 强调色 (Apple HIG Blue)
  // ──────────────────────────────────────────────
  /// 强调蓝: 浅色 #007AFF / 深色 #0A84FF
  static Color get accentBlueLight => const Color(0xFF007AFF);
  static Color get accentBlueDark => const Color(0xFF0A84FF);

  /// 按钮填充色 (同强调蓝)
  static Color get buttonFillLight => const Color(0xFF007AFF);
  static Color get buttonFillDark => const Color(0xFF0A84FF);

  /// 按钮上的文字 (始终白色)
  static Color get buttonText => const Color(0xFFFFFFFF);

  /// 禁用按钮文字: 浅色 #C7C7CC / 深色 #48484A
  static Color get buttonDisabledTextLight => const Color(0xFFC7C7CC);
  static Color get buttonDisabledTextDark => const Color(0xFF48484A);

  // ──────────────────────────────────────────────
  // 分割线 (Apple HIG separator)
  // ──────────────────────────────────────────────
  /// 分割线: 浅色 #C6C6C8 / 深色 #38383A
  static Color get separatorLight => const Color(0xFFC6C6C8);
  static Color get separatorDark => const Color(0xFF38383A);

  // ──────────────────────────────────────────────
  // 输入框边框
  // ──────────────────────────────────────────────
  /// 输入框边框: 浅色 #C6C6C8 / 深色 #48484A
  static Color get inputBorderLight => const Color(0xFFC6C6C8);
  static Color get inputBorderDark => const Color(0xFF48484A);

  // ──────────────────────────────────────────────
  // 语义颜色
  // ──────────────────────────────────────────────
  /// 破坏性操作红色: 浅色 #FF3B30 / 深色 #FF453A
  static Color get destructiveRedLight => const Color(0xFFFF3B30);
  static Color get destructiveRedDark => const Color(0xFFFF453A);

  // ──────────────────────────────────────────────
  // 工具方法
  // ──────────────────────────────────────────────
  static Color pageBackground(BuildContext context) =>
      isDark(context) ? pageBackgroundDark : pageBackgroundLight;

  static Color cardBackground(BuildContext context) =>
      isDark(context) ? cardBackgroundDark : cardBackgroundLight;

  static Color fieldBackground(BuildContext context) =>
      isDark(context) ? fieldBackgroundDark : fieldBackgroundLight;

  static Color primaryText(BuildContext context) =>
      isDark(context) ? primaryTextDark : primaryTextLight;

  static Color secondaryText(BuildContext context) =>
      isDark(context) ? secondaryTextDark : secondaryTextLight;

  static Color tertiaryText(BuildContext context) =>
      isDark(context) ? tertiaryTextDark : tertiaryTextLight;

  static Color accentBlue(BuildContext context) =>
      isDark(context) ? accentBlueDark : accentBlueLight;

  static Color buttonFill(BuildContext context) =>
      isDark(context) ? buttonFillDark : buttonFillLight;

  static Color buttonDisabledText(BuildContext context) =>
      isDark(context) ? buttonDisabledTextDark : buttonDisabledTextLight;

  static Color separator(BuildContext context) =>
      isDark(context) ? separatorDark : separatorLight;

  static Color inputBorder(BuildContext context) =>
      isDark(context) ? inputBorderDark : inputBorderLight;

  static Color destructiveRed(BuildContext context) =>
      isDark(context) ? destructiveRedDark : destructiveRedLight;
}
