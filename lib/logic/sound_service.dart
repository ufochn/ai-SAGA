import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:soundpool/soundpool.dart';

/// 全平台音效服务。
///
/// 以程序化方式合成短音效（PCM16 / WAV），通过 [Soundpool] 播放，
/// 兼容 Android / iOS / macOS / Web，不再依赖 Web Audio API。
/// 在不支持 soundpool 的平台上静默降级，不抛异常、不影响功能。
class SoundService {
  SoundService._();

  static const int _sampleRate = 44100;
  static const int _numChannels = 1;
  static const int _bytesPerSample = 2; // 16-bit

  static Soundpool? _pool;
  static final Map<String, int> _soundIds = {};
  static bool _unavailable = false;

  /// 按钮点击音效（短促的嘀嗒声）
  static void playClick() => _play('click', _clickWav);

  /// 确认/成功音效（两个上升音调）
  static void playConfirm() => _play('confirm', _confirmWav);

  /// 错误/取消音效（低沉短促）
  static void playCancel() => _play('cancel', _cancelWav);

  /// 恐怖音效（低沉不和谐的下行音调，适合跳吓场景）
  static void playHorror() => _play('horror', _horrorWav);

  /// 恐怖音效2（尖锐刺耳的不和谐音 + 突然的冲击，适合跳吓场景）
  static void playHorror2() => _play('horror2', _horror2Wav);

  // ---------------------------------------------------------------------
  // 音效定义：与原先 Web Audio 实现一一对应（波形、频率、包络、时长）
  // ---------------------------------------------------------------------

  static final Uint8List _clickWav = _buildWav(const [
    _Tone(_Wave.sine, 800, 800, 0, 0.1, 0.10),
  ]);

  static final Uint8List _confirmWav = _buildWav(const [
    _Tone(_Wave.sine, 600, 600, 0, 0.1, 0.08),
    _Tone(_Wave.sine, 900, 900, 0.1, 0.15, 0.08),
  ]);

  static final Uint8List _cancelWav = _buildWav(const [
    _Tone(_Wave.square, 200, 200, 0, 0.15, 0.08),
  ]);

  static final Uint8List _horrorWav = _buildWav(const [
    // 主音：低频咆哮（锯齿波），110 -> 55
    _Tone(_Wave.sawtooth, 110, 55, 0, 0.8, 0.12),
    // 不和谐副音：高半音程颤抖（方波），155 -> 77
    _Tone(_Wave.square, 155, 77, 0, 0.7, 0.06),
    // 冲击音：短促噪声般的爆炸音（正弦波+快速调制），80 -> 20
    _Tone(_Wave.sine, 80, 20, 0.05, 0.25, 0.15),
  ]);

  static final Uint8List _horror2Wav = _buildWav(const [
    // 主音：尖锐不和谐的高频（锯齿波 + 快速颤音），880 -> 110
    _Tone(_Wave.sawtooth, 880, 110, 0, 0.8, 0.10),
    // 副音：颤抖的不和谐音（方波，小二度碰撞），830 -> 100
    _Tone(_Wave.square, 830, 100, 0, 0.6, 0.07),
    // 冲击音：突然的噪声爆炸（正弦波 + 快速调制），60 -> 15
    _Tone(_Wave.sine, 60, 15, 0.15, 0.2, 0.18),
    // 额外：高频金属般的尖叫声（正弦波），1200 -> 400
    _Tone(_Wave.sine, 1200, 400, 0.1, 0.4, 0.06),
  ]);

  // ---------------------------------------------------------------------
  // 播放
  // ---------------------------------------------------------------------

  static Future<void> _play(String key, Uint8List wav) async {
    if (_unavailable) return;
    try {
      final pool = _pool ??= Soundpool.fromOptions(
        options: const SoundpoolOptions(maxStreams: 16),
      );
      int? soundId = _soundIds[key];
      if (soundId == null) {
        soundId = await pool.loadUint8List(wav);
        if (soundId < 0) return;
        _soundIds[key] = soundId;
      }
      await pool.play(soundId);
    } catch (_) {
      // 平台不支持或初始化/播放失败时静默降级，避免影响功能。
      _unavailable = true;
    }
  }

  // ---------------------------------------------------------------------
  // PCM16/WAV 合成
  // ---------------------------------------------------------------------

  static Uint8List _buildWav(List<_Tone> tones) {
    final totalDuration = tones.fold<double>(
        0, (acc, t) => math.max(acc, t.startTime + t.duration));
    final sampleCount = (totalDuration * _sampleRate).ceil() + 1;
    final dataSize = sampleCount * _bytesPerSample;

    final bytes = Uint8List(44 + dataSize);
    final data = ByteData.view(bytes.buffer);

    // RIFF/WAVE 头
    _writeAscii(bytes, 0, 'RIFF');
    data.setUint32(4, 36 + dataSize, Endian.little);
    _writeAscii(bytes, 8, 'WAVE');
    _writeAscii(bytes, 12, 'fmt ');
    data.setUint32(16, 16, Endian.little); // fmt chunk 大小
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, _numChannels, Endian.little);
    data.setUint32(24, _sampleRate, Endian.little);
    data.setUint32(
        28, _sampleRate * _numChannels * _bytesPerSample, Endian.little);
    data.setUint16(32, _numChannels * _bytesPerSample, Endian.little);
    data.setUint16(34, 16, Endian.little); // bits per sample
    _writeAscii(bytes, 36, 'data');
    data.setUint32(40, dataSize, Endian.little);

    // 逐采样混音
    final phases = List<double>.filled(tones.length, 0);
    for (int i = 0; i < sampleCount; i++) {
      final t = i / _sampleRate;
      double value = 0;
      for (int k = 0; k < tones.length; k++) {
        final tone = tones[k];
        final lt = t - tone.startTime;
        if (lt < 0 || lt >= tone.duration) continue;

        // 频率线性变化
        final progress = lt / tone.duration;
        final freq =
            tone.freqStart + (tone.freqEnd - tone.freqStart) * progress;

        // 相位累加（每个音起始相位为 0，对应 Web Audio oscillator.start）
        phases[k] += 2 * math.pi * freq / _sampleRate;
        final phase = phases[k];

        double v;
        switch (tone.wave) {
          case _Wave.sine:
            v = math.sin(phase);
          case _Wave.square:
            v = math.sin(phase) >= 0 ? 1.0 : -1.0;
          case _Wave.sawtooth:
            final p = phase / (2 * math.pi);
            v = 2 * (p - p.floorToDouble()) - 1;
        }

        // 增益线性淡出：amp -> 0（对应 linearRampToValueAtTime(0, end)）
        final gain = tone.amp * (1 - progress);
        value += v * gain;
      }

      value = value.clamp(-1.0, 1.0);
      data.setInt16(44 + i * _bytesPerSample, (value * 32767).round(),
          Endian.little);
    }
    return bytes;
  }

  static void _writeAscii(Uint8List bytes, int offset, String text) {
    for (int i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }
}

/// 波形类型
enum _Wave { sine, square, sawtooth }

/// 单个音（振荡器）的合成参数
class _Tone {
  final _Wave wave;
  final double freqStart;
  final double freqEnd;
  final double startTime; // 秒
  final double duration; // 秒
  final double amp; // 0..1

  const _Tone(
    this.wave,
    this.freqStart,
    this.freqEnd,
    this.startTime,
    this.duration,
    this.amp,
  );
}
