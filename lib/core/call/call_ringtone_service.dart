import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Shared ringtone player for incoming/outgoing ringing states.
class CallRingtoneService {
  CallRingtoneService._();

  static final AudioPlayer _player = AudioPlayer(playerId: 'call-ringtone');
  static bool _initialized = false;
  static bool _isPlaying = false;

  static bool get isPlaying => _isPlaying;

  static Future<void> playLoop() async {
    if (_isPlaying) return;
    try {
      if (!_initialized) {
        _initialized = true;
        await _player.setReleaseMode(ReleaseMode.loop);
        await _player.setPlayerMode(PlayerMode.mediaPlayer);
        _player.onPlayerComplete.listen((_) {
          // With [ReleaseMode.loop], complete should not happen normally.
          _isPlaying = false;
        });
      }
      await _player.play(AssetSource('ring.wav'));
      _isPlaying = true;
    } catch (e) {
      _isPlaying = false;
      if (kDebugMode) {
        debugPrint('[ringtone] playLoop failed: $e');
      }
    }
  }

  static Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // no-op
    } finally {
      _isPlaying = false;
    }
  }

  static Future<void> dispose() async {
    try {
      await stop();
      await _player.dispose();
    } catch (_) {
      // no-op
    } finally {
      _initialized = false;
      _isPlaying = false;
    }
  }
}
