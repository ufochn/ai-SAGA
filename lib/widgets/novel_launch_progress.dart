import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ai_saga/logic/storage_service.dart';

/// 「生成新小说」全黑等待屏（点击设置确认后、收到首段正文前）。
///
/// 黑底 + 进度条 + 分阶段文案。进度/文案按【启动后经过时间】推进（纯时间脚本，
/// 设计总时长 1 分钟 = 60s；40 章大纲 + 第一章正文可能耗时较长，故 60s 后若还没
/// 收到正文则进度卡在 99.9% 继续等，收到正文才离开）：
///   - 0~15s    进度 0→40%（慢启动），文案①；
///   - 15~30s   进度 40→55%，文案②；
///   - 30~45s   进度 55→78（快）→90（缓），文案③；
///   - 45~60s   进度 90→100%，文案④；
///   - ≥60s 仍未收到正文：进度卡在 99.9%，文案⑤（继续等，收到正文才离开）。
///
/// [completed] 由外部在【开始收到正文打字机流】时置 true：进度瞬间拉到 100%、
/// 文案切为⑥「接收完毕，精彩现在开始」，随后由外部淡出本屏揭示正文。
/// 文案始终带省略号动画（… / …… / ……… 之间循环，约一秒一档，中间以空白复位），
/// 省略号紧贴文末、在【文末固定预留位】内自己变换，文字本身固定不动不会来回移动；
/// 文案多语言适配。
class NovelLaunchProgress extends StatefulWidget {
  /// 是否已收到首段正文（置 true 后不再按时间推进，直接显示完成态）。
  final bool completed;

  const NovelLaunchProgress({super.key, required this.completed});

  @override
  State<NovelLaunchProgress> createState() => _NovelLaunchProgressState();
}

class _NovelLaunchProgressState extends State<NovelLaunchProgress> {
  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;
  int _tickCount = 0;
  int _ellipsisStep = 0; // 0=无 1=… 2=……
  double _progress = 0.0;

  double get _elapsedSec => _watch.elapsedMilliseconds / 1000.0;

  @override
  void initState() {
    super.initState();
    _watch.start();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => _onTick(),
    );
  }

  @override
  void didUpdateWidget(NovelLaunchProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.completed && !oldWidget.completed) {
      // 已收到正文：进度拉满、停表（文案由 build 切为完成态）
      _ticker?.cancel();
      _ticker = null;
      if (mounted) {
        setState(() {
          _progress = 1.0;
        });
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _watch.stop();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    _tickCount++;
    if (widget.completed) {
      if (_progress < 1.0) {
        setState(() {
          _progress = 1.0;
        });
      }
      return;
    }
    setState(() {
      _progress = _waitPercent(_elapsedSec);
      // 省略号约每 7 次 tick（~1.05s）切换一档（一秒左右变一次）
      if (_tickCount % 7 == 0) {
        _ellipsisStep = (_ellipsisStep + 1) % 4;
      }
    });
  }

  /// 时间脚本：返回 0..1 的目标进度（总时长 60s，各阶段按比例压缩）。
  static double _waitPercent(double s) {
    if (s <= 0) return 0.0;
    if (s < 15) {
      // 0→40%，开头慢（ease-in），"进展慢点"
      final double t = (s / 15.0).clamp(0.0, 1.0);
      return 0.40 * t * t;
    }
    if (s < 30) {
      // 40→55%
      final double t = ((s - 15) / 15.0).clamp(0.0, 1.0);
      return 0.40 + 0.15 * t;
    }
    if (s < 45) {
      // 30~35s：55→78 快；35~45s：78→90 缓
      if (s < 35) {
        final double t = ((s - 30) / 5.0).clamp(0.0, 1.0);
        return 0.55 + 0.23 * t;
      }
      final double t = ((s - 35) / 10.0).clamp(0.0, 1.0);
      return 0.78 + 0.12 * t;
    }
    if (s < 60) {
      final double t = ((s - 45) / 15.0).clamp(0.0, 1.0);
      return 0.90 + 0.10 * t;
    }
    // ≥60s 仍未收到正文：卡在 99.9% 继续等（正文到了由 completed 拉满）
    return 0.999;
  }

  String get _suffix {
    switch (_ellipsisStep) {
      case 1:
        return '…';
      case 2:
        return '……';
      case 3:
        return '………';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final double s = _elapsedSec;
    final String base;
    if (widget.completed) {
      base = _phaseText(6);
    } else if (s >= 60) {
      base = _phaseText(5);
    } else if (s >= 45) {
      base = _phaseText(4);
    } else if (s >= 30) {
      base = _phaseText(3);
    } else if (s >= 15) {
      base = _phaseText(2);
    } else {
      base = _phaseText(1);
    }
    final double p = _progress.clamp(0.0, 1.0);

    // 文案区可用宽度（两侧各 40 padding + 文末固定省略号预留位）
    final double availW =
        (MediaQuery.of(context).size.width - 80 - 56).clamp(80.0, 10000.0);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 文字固定不动：主文案只占自己的区域，文末省略号在固定宽度预留位内变换，
            // 不参与布局宽度变化 → 省略号切换时整行不再左右移动。
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: availW),
                  child: Text(
                    base,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      height: 1.6,
                    ),
                  ),
                ),
                // 与文字零间距，紧贴文末；固定宽度预留位容纳最多三个省略号，宽度恒定
                SizedBox(
                  width: 56,
                  child: Text(
                    _suffix,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: 260,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: p,
                  minHeight: 6,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 六段进度文案（多语言）。
  static String _phaseText(int phase) {
    switch (phase) {
      case 1:
        return StorageService.localizedText(
          zhCN: '大模型正在寻找专属于您的创作思路',
          zhTW: '大模型正在尋找專屬於您的創作思路',
          yue: 'AI 正在諗緊專屬於您嘅創作思路',
          en: 'The AI is crafting a creative direction just for you',
          es: 'La IA está buscando una idea creativa pensada solo para ti',
          fr: "L'IA cherche une direction créative rien que pour vous",
          de: 'Die KI entwickelt einen kreativen Ansatz nur für dich',
          pt: 'A IA está criando uma direção criativa feita só para você',
          ja: 'あなただけの創作の方向性をAIが考えています',
          ko: 'AI가 당신만을 위한 창작 방향을 찾고 있습니다',
        );
      case 2:
        return StorageService.localizedText(
          zhCN: '创作思路已确定，正在生成大纲',
          zhTW: '創作思路已確定，正在生成大綱',
          yue: '創作思路已確定，開始生成大綱',
          en: 'Creative direction set. Now generating the outline',
          es: 'Dirección creativa definida. Ahora se genera el esquema',
          fr: 'Direction créative définie. Génération du plan en cours',
          de: 'Kreativrichtung festgelegt. Die Gliederung wird erstellt',
          pt: 'Direção criativa definida. Gerando o esboço agora',
          ja: '創作方針が確定しました。あらすじを作成しています',
          ko: '창작 방향이 확정되었습니다. 개요를 생성하는 중입니다',
        );
      case 3:
        return StorageService.localizedText(
          zhCN: '大纲已生成，正在审核并打磨精彩程度，即将开始生成正文',
          zhTW: '大綱已生成，正在審核並打磨精彩程度，即將開始生成正文',
          yue: '大綱已生成，而家做緊審核同潤色，就快開始寫正文',
          en: 'Outline ready. Reviewing and polishing it — the story is about to begin',
          es: 'Esquema listo. Revisando y puliendo su calidad, la historia está por comenzar',
          fr: "Plan prêt. Vérification et polissage en cours, le récit va bientôt commencer",
          de: 'Gliederung fertig. Prüfung und Feinschliff laufen, die Geschichte beginnt gleich',
          pt: 'Esboço pronto. Revisando e aprimorando — a história está prestes a começar',
          ja: 'あらすじが完成し、品質を確認中です。まもなく本文の作成を始めます',
          ko: '개요가 준비되었습니다. 품질을 검토하는 중이며 곧 본문 작성을 시작합니다',
        );
      case 4:
        return StorageService.localizedText(
          zhCN: '大纲审核和调整已完成，开始生成小说正文',
          zhTW: '大綱審核和調整已完成，開始生成小說正文',
          yue: '大綱審核同調整已完成，開始生成小說正文',
          en: 'Outline review complete. Beginning to write your story',
          es: 'Revisión del esquema completada. Comenzando a escribir tu historia',
          fr: "Révision du plan terminée. Début de l'écriture de votre histoire",
          de: 'Prüfung der Gliederung abgeschlossen. Deine Geschichte wird jetzt geschrieben',
          pt: 'Revisão do esboço concluída. Começando a escrever sua história',
          ja: 'あらすじの確認が完了しました。小説本文の作成を始めます',
          ko: '개요 검토가 완료되었습니다. 소설 본문 작성을 시작합니다',
        );
      case 5:
        return StorageService.localizedText(
          zhCN: '大模型正在做最后的润色，正文即将完成',
          zhTW: '大模型正在做最後的潤色，正文即將完成',
          yue: 'AI 正在做最後嘅潤飾，正文就快完成',
          en: 'The AI is adding the final touches — your story is almost ready',
          es: 'La IA está dando los últimos toques, tu historia está casi lista',
          fr: "L'IA apporte les dernières touches, votre histoire est presque prête",
          de: 'Die KI arbeitet am Feinschliff — deine Geschichte ist fast fertig',
          pt: 'A IA está fazendo os últimos ajustes — sua história está quase pronta',
          ja: 'AIが最後の仕上げをしています。本文はまもなく完成します',
          ko: 'AI가 마지막 손질을 하고 있습니다. 본문이 곧 완성됩니다',
        );
      case 6:
      default:
        return StorageService.localizedText(
          zhCN: '接收完毕，精彩现在开始',
          zhTW: '接收完畢，精彩現在開始',
          yue: '接收完成，精彩而家開始',
          en: 'All received — the adventure begins now',
          es: 'Todo recibido: la aventura comienza ahora',
          fr: "Tout est prêt — l'aventure commence maintenant",
          de: 'Alles angekommen — das Abenteuer beginnt jetzt',
          pt: 'Tudo recebido — a aventura começa agora',
          ja: 'すべて受信しました。冒険が今始まります',
          ko: '모두 수신했습니다. 지금 모험이 시작됩니다',
        );
    }
  }
}
