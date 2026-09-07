import 'package:flutter/cupertino.dart';

import 'package:ai_saga/logic/storage_service.dart';

/// 启动时（Splash 标题出现前）向用户展示的「仅供技术交流 · 非正式发布商业版」免责弹窗。
///
/// 每次启动都会弹出（不记忆、不跳过），语言随 StorageService.getLanguage()；
/// 用户点"知道了"后才关闭，Splash 标题才出现/动画才开始。
Future<void> showTechnicalDisclaimer(BuildContext context) async {
  final lang = _resolveLang();
  await showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(
        _title(lang),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _body(lang),
              textAlign: TextAlign.left,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(_ok(lang)),
        ),
      ],
    ),
  );
}

/// 语言代码与 App 其它多语言保持一致（缺省按简体中文）。
String _resolveLang() {
  final l = StorageService.getLanguage();
  return l.isEmpty ? 'zh' : l;
}

String _title(String lang) {
  switch (lang) {
    case 'yue':
      return '淨係技術交流 · 未正式推出商業版';
    case 'zh-TW':
      return '僅供技術交流 · 非正式發佈商業版';
    case 'en':
      return 'Technical-Exchange Only · Pre-release (Non-commercial)';
    case 'ja':
      return '技術交流専用・未正式リリース版（商用版ではありません）';
    case 'ko':
      return '기술교류 전용 · 정식 출시 전(비상업용)';
    case 'es':
      return 'Solo intercambio técnico · versión previa (no comercial)';
    case 'fr':
      return 'Échange technique uniquement · version préliminaire (non commerciale)';
    case 'de':
      return 'Nur technischer Austausch · Vorabversion (nicht kommerziell)';
    case 'pt':
      return 'Apenas intercâmbio técnico · versão preliminar (não comercial)';
    default:
      return '仅供技术交流 · 非正式发布商业版';
  }
}

String _body(String lang) {
  switch (lang) {
    case 'yue':
      return '呢個 App 淨係用嚟做技術交流，係未正式推出嘅商業版本。App 喺運行以下功能嗰陣，彈窗會顯示相關嘅技術細節：\n'
          '1、基本嘅小說文本生成環節；\n'
          '2、違禁內容審核環節；\n'
          '3、用戶自由輸入文字引導情節發展環節；\n'
          '4、用戶輸入內容係咪違規嘅審核環節；\n'
          '5、小說大綱生成環節；\n'
          '6、LLM 生成小說文本嘅違規審核環節；\n'
          '7、用時間樹功能完全重寫環節；\n'
          '8、小說情節對應嘅圖片生成功能（遲啲先提供）；\n'
          '9、小說圖片違規審核功能（遲啲先提供）；\n'
          '10、音樂功能（遲啲先提供）。\n'
          '所有彈窗提示內容僅供參考。';
    case 'zh-TW':
      return '本 App 僅供技術交流，為非正式發佈的商業版本。App 在執行以下功能時，彈窗會顯示相關技術細節：\n'
          '1、基本的小說文本生成環節；\n'
          '2、違禁內容審核環節；\n'
          '3、用戶自由輸入文字引導情節發展環節；\n'
          '4、用戶輸入內容是否違規審核環節；\n'
          '5、小說大綱生成環節；\n'
          '6、LLM 生成小說文字的違規審核環節；\n'
          '7、使用時間樹功能完全重寫環節；\n'
          '8、小說情節對應的圖片生成功能（稍晚提供）；\n'
          '9、小說圖片違規審核功能（稍晚提供）；\n'
          '10、音樂功能（稍晚提供）。\n'
          '所有彈窗提示內容僅供參考。';
    case 'en':
      return 'This app is for technical exchange only and is a pre-release '
          'build, not a formally released commercial version. While it runs '
          'the following features, pop-ups will show related technical details:\n'
          '1. Basic novel text generation;\n'
          '2. Prohibited-content review;\n'
          '3. Freely typing to steer plot development;\n'
          '4. Review of whether your input text violates guidelines;\n'
          '5. Novel outline generation;\n'
          '6. Review of whether the LLM-generated novel text violates guidelines;\n'
          '7. Fully rewriting using the time-tree feature;\n'
          '8. Plot-to-image generation (coming later);\n'
          '9. Review of images with prohibited content (coming later);\n'
          '10. Music features (coming later).\n'
          'All pop-up notices are for reference only.';
    case 'ja':
      return '本アプリは技術交流のみを目的とした、正式リリース前の非商用版です。以下の機能を実行している間、ポップアップに関連する技術的な詳細が表示されることがあります：\n'
          '1. 基本的な小説本文の生成；\n'
          '2. 禁止内容の審査；\n'
          '3. ユーザーが自由に入力して展開を導く機能；\n'
          '4. ユーザー入力内容がガイドライン違反かどうかの審査；\n'
          '5. 小説のあらすじ生成；\n'
          '6. LLM が生成した小説本文の違反審査；\n'
          '7. タイムツリーによる完全な書き直し；\n'
          '8. 展開に応じた画像生成（近日提供）；\n'
          '9. 画像の禁止内容審査（近日提供）；\n'
          '10. 音楽機能（近日提供）。\n'
          'ポップアップの内容はすべて参考情報です。';
    case 'ko':
      return '본 앱은 기술 교류 목적의 정식 출시 전 비상업용 버전입니다. 다음 기능이 실행되는 동안 관련 기술 세부사항이 팝업으로 표시될 수 있습니다:\n'
          '1. 기본 소설 본문 생성;\n'
          '2. 금지 콘텐츠 심사;\n'
          '3. 사용자가 자유롭게 입력해 전개를 이끄는 기능;\n'
          '4. 사용자 입력 내용의 위반 여부 심사;\n'
          '5. 소설 개요 생성;\n'
          '6. LLM이 생성한 소설 본문의 위반 심사;\n'
          '7. 타임트리로 완전히 다시 쓰기;\n'
          '8. 전개에 맞는 이미지 생성(추후 제공);\n'
          '9. 이미지 위반 심사(추후 제공);\n'
          '10. 음악 기능(추후 제공).\n'
          '팝업 내용은 모두 참고용입니다.';
    case 'es':
      return 'Esta app es solo para intercambio técnico y es una versión previa, '
          'no una versión comercial publicada. Mientras ejecuta las siguientes '
          'funciones, las ventanas emergentes mostrarán detalles técnicos:\n'
          '1. Generación básica del texto de la novela;\n'
          '2. Revisión de contenido prohibido;\n'
          '3. Escribir libremente para guiar el desarrollo de la trama;\n'
          '4. Revisión de si el texto que escribes infringe las normas;\n'
          '5. Generación del esquema de la novela;\n'
          '6. Revisión de si el texto generado por el LLM infringe las normas;\n'
          '7. Reescritura completa mediante el árbol del tiempo;\n'
          '8. Generación de imágenes según la trama (próximamente);\n'
          '9. Revisión de infracciones en imágenes (próximamente);\n'
          '10. Funciones de música (próximamente).\n'
          'Todos los avisos emergentes son solo de referencia.';
    case 'fr':
      return 'Cette app est destinée uniquement à l\'échange technique ; il '
          's\'agit d\'une version préliminaire, non commerciale. Pendant '
          'l\'exécution des fonctions suivantes, des fenêtres afficheront des '
          'détails techniques :\n'
          '1. Génération de base du texte du roman ;\n'
          '2. Vérification des contenus interdits ;\n'
          '3. Saisie libre pour guider le développement de l\'intrigue ;\n'
          '4. Vérification de la conformité de votre saisie ;\n'
          '5. Génération du plan du roman ;\n'
          '6. Vérification de la conformité du texte généré par le LLM ;\n'
          '7. Réécriture complète via l\'arbre temporel ;\n'
          '8. Génération d\'images selon l\'intrigue (à venir) ;\n'
          '9. Vérification des images interdites (à venir) ;\n'
          '10. Fonctions musicales (à venir).\n'
          'Toutes les fenêtres sont fournies à titre indicatif.';
    case 'de':
      return 'Diese App dient nur dem technischen Austausch und ist eine '
          'Vorabversion, keine veröffentlichte kommerzielle Version. Während '
          'der folgenden Funktionen werden technische Details in Pop-ups angezeigt:\n'
          '1. Grundlegende Erzeugung des Roman-Textes;\n'
          '2. Prüfung verbotener Inhalte;\n'
          '3. Freies Tippen zur Lenkung der Handlung;\n'
          '4. Prüfung, ob Ihre Eingabe gegen die Regeln verstößt;\n'
          '5. Erzeugung der Roman-Gliederung;\n'
          '6. Prüfung, ob der vom LLM erzeugte Text verstößt;\n'
          '7. Vollständiges Neuschreiben mit dem Zeitbaum;\n'
          '8. Bilderzeugung passend zur Handlung (folgt später);\n'
          '9. Prüfung verbotener Bilder (folgt später);\n'
          '10. Musikfunktionen (folgt später).\n'
          'Alle Pop-up-Hinweise dienen nur zur Orientierung.';
    case 'pt':
      return 'Este app destina-se apenas ao intercâmbio técnico e é uma versão '
          'preliminar, não uma versão comercial publicada. Durante a execução '
          'das seguintes funções, janelas mostrarão detalhes técnicos:\n'
          '1. Geração básica do texto da novela;\n'
          '2. Revisão de conteúdo proibido;\n'
          '3. Digitar livremente para conduzir o desenvolvimento da trama;\n'
          '4. Revisão se o texto digitado viola as normas;\n'
          '5. Geração do esboço da novela;\n'
          '6. Revisão se o texto gerado pelo LLM viola as normas;\n'
          '7. Reescrita completa com a árvore do tempo;\n'
          '8. Geração de imagens conforme a trama (em breve);\n'
          '9. Revisão de imagens com conteúdo proibido (em breve);\n'
          '10. Funções de música (em breve).\n'
          'Todas as janelas são apenas informativas.';
    default:
      return '本 App 仅供技术交流，为非正式发布的商业版本。App 在运行如下功能时，弹窗会显示相关技术细节：\n'
          '1、基本的小说文本生成环节；\n'
          '2、违禁内容审核环节；\n'
          '3、用户自由输入文本引导情节发展环节；\n'
          '4、用户输入内容是否违规审核环节；\n'
          '5、小说大纲生成环节；\n'
          '6、LLM 生成小说文本的违规审核环节；\n'
          '7、使用时间树功能完全重写环节；\n'
          '8、小说情节对应的图片生成功能（稍晚提供）；\n'
          '9、小说图片违规审核功能（稍晚提供）；\n'
          '10、音乐功能（稍晚提供）。\n'
          '所有弹窗提示内容仅供参考。';
  }
}

String _ok(String lang) {
  switch (lang) {
    case 'yue':
      return '明白喇';
    case 'zh-TW':
      return '知道了';
    case 'en':
      return 'Got it';
    case 'ja':
      return '了解しました';
    case 'ko':
      return '확인';
    case 'es':
      return 'Entendido';
    case 'fr':
      return 'Compris';
    case 'de':
      return 'Verstanden';
    case 'pt':
      return 'Entendido';
    default:
      return '知道了';
  }
}
