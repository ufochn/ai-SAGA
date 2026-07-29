import 'package:web/web.dart' as web;

/// 使用 Web Audio API 生成简单交互音效
class SoundService {
  static web.AudioContext? _audioContext;

  static web.AudioContext _getContext() {
    _audioContext ??= web.AudioContext();
    return _audioContext!;
  }

  /// 按钮点击音效（短促的嘀嗒声）
  static void playClick() {
    final ctx = _getContext();
    final oscillator = ctx.createOscillator();
    final gain = ctx.createGain();
    oscillator.connect(gain);
    gain.connect(ctx.destination);
    oscillator.type = 'sine';
    oscillator.frequency.value = 800;
    gain.gain.value = 0.1;
    oscillator.start(0);
    gain.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.1);
    oscillator.stop(ctx.currentTime + 0.1);
  }

  /// 确认/成功音效（两个上升音调）
  static void playConfirm() {
    final ctx = _getContext();
    _playTone(ctx, 600, 0, 0.1);
    _playTone(ctx, 900, 0.1, 0.15);
  }

  /// 错误/取消音效（低沉短促）
  static void playCancel() {
    final ctx = _getContext();
    final oscillator = ctx.createOscillator();
    final gain = ctx.createGain();
    oscillator.connect(gain);
    gain.connect(ctx.destination);
    oscillator.type = 'square';
    oscillator.frequency.value = 200;
    gain.gain.value = 0.08;
    oscillator.start(0);
    gain.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.15);
    oscillator.stop(ctx.currentTime + 0.15);
  }

  /// 恐怖音效（低沉不和谐的下行音调，适合跳吓场景）
  static void playHorror() {
    final ctx = _getContext();
    // 主音：低频咆哮（锯齿波）
    final osc1 = ctx.createOscillator();
    final gain1 = ctx.createGain();
    osc1.connect(gain1);
    gain1.connect(ctx.destination);
    osc1.type = 'sawtooth';
    osc1.frequency.value = 110;
    gain1.gain.value = 0.12;
    osc1.start(0);
    osc1.frequency.linearRampToValueAtTime(55, ctx.currentTime + 0.6);
    gain1.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.8);
    osc1.stop(ctx.currentTime + 0.8);

    // 不和谐副音：高半音程颤抖（方波）
    final osc2 = ctx.createOscillator();
    final gain2 = ctx.createGain();
    osc2.connect(gain2);
    gain2.connect(ctx.destination);
    osc2.type = 'square';
    osc2.frequency.value = 155;
    gain2.gain.value = 0.06;
    osc2.start(0);
    osc2.frequency.linearRampToValueAtTime(77, ctx.currentTime + 0.5);
    gain2.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.7);
    osc2.stop(ctx.currentTime + 0.7);

    // 冲击音：短促噪声般的爆炸音（正弦波+快速调制）
    final osc3 = ctx.createOscillator();
    final gain3 = ctx.createGain();
    osc3.connect(gain3);
    gain3.connect(ctx.destination);
    osc3.type = 'sine';
    osc3.frequency.value = 80;
    gain3.gain.value = 0.15;
    osc3.start(ctx.currentTime + 0.05);
    osc3.frequency.linearRampToValueAtTime(20, ctx.currentTime + 0.25);
    gain3.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.3);
    osc3.stop(ctx.currentTime + 0.3);
  }

  /// 恐怖音效2（尖锐刺耳的不和谐音 + 突然的冲击，适合跳吓场景）
  static void playHorror2() {
    final ctx = _getContext();

    // 主音：尖锐不和谐的高频（锯齿波 + 快速颤音）
    final osc1 = ctx.createOscillator();
    final gain1 = ctx.createGain();
    osc1.connect(gain1);
    gain1.connect(ctx.destination);
    osc1.type = 'sawtooth';
    osc1.frequency.value = 880;
    gain1.gain.value = 0.1;
    osc1.start(0);
    // 快速下降音调
    osc1.frequency.linearRampToValueAtTime(110, ctx.currentTime + 0.7);
    gain1.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.8);
    osc1.stop(ctx.currentTime + 0.8);

    // 副音：颤抖的不和谐音（方波，小二度碰撞）
    final osc2 = ctx.createOscillator();
    final gain2 = ctx.createGain();
    osc2.connect(gain2);
    gain2.connect(ctx.destination);
    osc2.type = 'square';
    osc2.frequency.value = 830;
    gain2.gain.value = 0.07;
    osc2.start(0);
    osc2.frequency.linearRampToValueAtTime(100, ctx.currentTime + 0.5);
    gain2.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.6);
    osc2.stop(ctx.currentTime + 0.6);

    // 冲击音：突然的噪声爆炸（正弦波 + 快速调制）
    final osc3 = ctx.createOscillator();
    final gain3 = ctx.createGain();
    osc3.connect(gain3);
    gain3.connect(ctx.destination);
    osc3.type = 'sine';
    osc3.frequency.value = 60;
    gain3.gain.value = 0.18;
    osc3.start(ctx.currentTime + 0.15);
    osc3.frequency.linearRampToValueAtTime(15, ctx.currentTime + 0.3);
    gain3.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.35);
    osc3.stop(ctx.currentTime + 0.35);

    // 额外：高频金属般的尖叫声（正弦波）
    final osc4 = ctx.createOscillator();
    final gain4 = ctx.createGain();
    osc4.connect(gain4);
    gain4.connect(ctx.destination);
    osc4.type = 'sine';
    osc4.frequency.value = 1200;
    gain4.gain.value = 0.06;
    osc4.start(ctx.currentTime + 0.1);
    osc4.frequency.linearRampToValueAtTime(400, ctx.currentTime + 0.4);
    gain4.gain.linearRampToValueAtTime(0, ctx.currentTime + 0.5);
    osc4.stop(ctx.currentTime + 0.5);
  }

  /// 辅助：播放单个音调
  static void _playTone(
    web.AudioContext ctx,
    double freq,
    double startTime,
    double duration,
  ) {
    final oscillator = ctx.createOscillator();
    final gain = ctx.createGain();
    oscillator.connect(gain);
    gain.connect(ctx.destination);
    oscillator.type = 'sine';
    oscillator.frequency.value = freq;
    gain.gain.value = 0.08;
    oscillator.start(startTime);
    gain.gain.linearRampToValueAtTime(0, startTime + duration);
    oscillator.stop(startTime + duration);
  }
}
