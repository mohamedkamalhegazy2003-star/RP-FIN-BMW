import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'db.dart';

/// أنواع الأحداث التفاعلية (صوت + اهتزاز)
enum Fx { pay, delete, edit, move, tap }

/// المؤثرات التفاعلية: أصوات + اهتزاز بمستوى قابل للتحكم من الإعدادات.
class FX {
  static bool soundOn = true;
  static double volume = 0.8; // 0..1
  static bool vibOn = true;
  static double vibLevel = 0.6; // 0..1 (شدة الاهتزاز)
  static bool vibOnMove = true; // اهتزاز خفيف عند التنقل والسحب

  static const _files = {
    Fx.pay: 'sounds/pay.wav',
    Fx.delete: 'sounds/delete.wav',
    Fx.edit: 'sounds/edit.wav',
    Fx.move: 'sounds/move.wav',
  };

  /// نمط الاهتزاز بالملّي ثانية: [انتظار، اهتزاز، انتظار، اهتزاز، ...]
  static const _patterns = {
    Fx.pay: [0, 35, 70, 90],
    Fx.delete: [0, 140],
    Fx.edit: [0, 30, 50, 30],
    Fx.move: [0, 14],
    Fx.tap: [0, 10],
  };

  static final Map<Fx, AudioPlayer> _players = {};
  static bool? _hasVibrator;
  static bool? _hasAmplitude;

  static Future<void> load() async {
    try {
      soundOn = (await DB.getSetting('fx_sound')) != '0';
      vibOn = (await DB.getSetting('fx_vib')) != '0';
      vibOnMove = (await DB.getSetting('fx_vib_move')) != '0';
      volume = (double.tryParse(await DB.getSetting('fx_volume') ?? '') ?? 0.8)
          .clamp(0.0, 1.0);
      vibLevel = (double.tryParse(await DB.getSetting('fx_vib_level') ?? '') ?? 0.6)
          .clamp(0.0, 1.0);
    } catch (_) {}
  }

  static Future<void> save() async {
    await DB.setSetting('fx_sound', soundOn ? '1' : '0');
    await DB.setSetting('fx_vib', vibOn ? '1' : '0');
    await DB.setSetting('fx_vib_move', vibOnMove ? '1' : '0');
    await DB.setSetting('fx_volume', volume.toStringAsFixed(2));
    await DB.setSetting('fx_vib_level', vibLevel.toStringAsFixed(2));
  }

  /// يشغّل الصوت والاهتزاز المناسبين للحدث (لا يرمي أخطاء أبداً)
  static void play(Fx e) {
    _sound(e);
    _vibe(e);
  }

  static Future<void> _sound(Fx e) async {
    if (!soundOn || volume <= 0) return;
    final f = _files[e];
    if (f == null) return;
    try {
      final pl = _players.putIfAbsent(e, () {
        final p = AudioPlayer();
        p.setPlayerMode(PlayerMode.lowLatency);
        return p;
      });
      await pl.stop();
      await pl.setVolume(volume);
      await pl.play(AssetSource(f), volume: volume);
    } catch (_) {}
  }

  /// [force] لتجربة الاهتزاز من الإعدادات حتى لو كان معطلاً للتنقل
  static Future<void> _vibe(Fx e, {bool force = false}) async {
    if (!vibOn || vibLevel <= 0) return;
    if (!force && (e == Fx.move || e == Fx.tap) && !vibOnMove) return;
    try {
      _hasVibrator ??= await Vibration.hasVibrator();
      if (_hasVibrator != true) {
        await HapticFeedback.selectionClick();
        return;
      }
      _hasAmplitude ??= await Vibration.hasAmplitudeControl();
      final base = _patterns[e]!;
      if (_hasAmplitude == true) {
        final amp = (vibLevel * 255).round().clamp(1, 255);
        await Vibration.vibrate(
          pattern: base,
          intensities: [for (var i = 0; i < base.length; i++) i.isOdd ? amp : 0],
        );
      } else {
        // لا يدعم التحكم في الشدة: نغيّر مدة الاهتزاز بدلاً من الشدة
        final scale = 0.4 + vibLevel * 1.2;
        await Vibration.vibrate(
          pattern: [
            for (var i = 0; i < base.length; i++)
              i.isOdd ? (base[i] * scale).round().clamp(5, 400) : base[i]
          ],
        );
      }
    } catch (_) {}
  }

  /// تجربة من شاشة الإعدادات
  static void test(Fx e) {
    _sound(e);
    _vibe(e, force: true);
  }

  /// اهتزاز فقط (مثلاً أثناء تحريك شريط الشدة)
  static void testVibe() => _vibe(Fx.edit, force: true);
}
