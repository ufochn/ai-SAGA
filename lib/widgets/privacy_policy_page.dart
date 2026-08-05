import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/app_theme.dart';
import 'package:ai_saga/logic/storage_service.dart';

/// 隐私政策页面。
///
/// 以 App 内嵌静态页呈现（不依赖网络），保证审核环境一定能打开；
/// 内容与删除账号流程中的披露保持一致。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  /// 根据用户选择的语言返回隐私政策标题。
  String get _policyTitle {
    switch (StorageService.getLanguage()) {
      case 'yue':
        return '私隱政策';
      case 'zh-TW':
        return '隱私政策';
      case 'en':
        return 'Privacy Policy';
      case 'es':
        return 'Política de Privacidad';
      case 'fr':
        return 'Politique de confidentialité';
      case 'de':
        return 'Datenschutzrichtlinie';
      case 'pt':
        return 'Política de Privacidade';
      case 'ja':
        return 'プライバシーポリシー';
      case 'ko':
        return '개인정보 처리방침';
      default:
        return '隐私政策';
    }
  }

  static const String _content = '''
感谢你使用本应用。我们非常重视你的隐私。本政策说明我们收集、使用、存储和保留哪些信息。

一、我们收集的信息
1. 账号信息：当你通过 Apple 或 Google 账号登录时，我们会获取你的平台账号标识、邮箱地址和昵称，用于创建和管理你的账号。
2. 设备信息：我们会生成并使用设备唯一标识，用于账号安全、限制接口滥用和提供正常服务。

二、信息的使用
我们仅将上述信息用于：登录与账号管理、保存和同步你的创作进度、安全保障与反滥用。

三、信息的共享
我们不会出售你的个人信息。除法律要求或保障服务安全所必需外，我们不会向第三方提供你的信息。

四、信息的存储与删除
你的数据存储于我们的服务器。当你删除账号时，我们会删除你的账号及相关个人数据。为防范滥用，我们会在删除后保留去标识化的设备防刷标记不超过 7 天；该标记不包含你的身份信息，也无法用于还原或关联你已删除的账号数据。

五、你的权利
你可以随时在应用内删除你的账号及相关数据。删除后无法恢复。

六、联系我们
如对本隐私政策有任何疑问，请联系：privacy@example.com

（更新日期：____年__月__日）
''';

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_policyTitle),
        backgroundColor: isDark
            ? AppTheme.pageBackgroundDark
            : AppTheme.pageBackgroundLight,
      ),
      backgroundColor: isDark
          ? AppTheme.pageBackgroundDark
          : AppTheme.pageBackgroundLight,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Text(
            _content,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: isDark
                  ? AppTheme.primaryTextDark
                  : AppTheme.primaryTextLight,
            ),
          ),
        ),
      ),
    );
  }
}
