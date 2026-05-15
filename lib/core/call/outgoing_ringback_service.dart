import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'agora_call_service.dart';

/// Caller-only ringback for project file [assets/ring.wav] (pubspec entry). Never used for incoming / receiver.
///
/// [AssetSource] is given `ring.wav` only — audioplayers prepends `assets/`, so `assets/ring.wav` would become `assets/assets/ring.wav`.
class OutgoingRingbackService {
  OutgoingRingbackService._();

  /// Path relative to the Flutter `assets/` directory (see pubspec `assets/ring.wav`).
  static const String _assetPath = 'ring.wav';

  static final AudioPlayer _player =
      AudioPlayer(playerId: 'outgoing-ringback');
  static bool _playerConfigured = false;
  static bool _isPlaying = false;
  static String? _activeRingbackCallId;

  static String? get activeRingbackCallId => _activeRingbackCallId;

  static bool get isPlaying => _isPlaying;

  /// Sync ringback with [AgoraAudioCallScreen] state (only place that should start audio).
  static Future<void> syncFromAgoraCallScreen({
    required VoiceCallSession session,
    required bool remoteJoined,
    required bool peerAccepted,
    required bool pickedIncoming,
  }) async {
    if (session.isIncoming) {
      if (kDebugMode) {
        debugPrint(
          '[ringback] blocked role=receiver reason=incoming_call_screen callId=${session.callId}',
        );
      }
      await stop(reason: 'incoming_call_screen');
      return;
    }
    if (pickedIncoming) {
      await stop(reason: 'incoming_pickup_state');
      return;
    }

    final callId = session.callId.trim();
    final self = session.selfUserId.trim();
    final caller = session.callerId.trim();
    final recv = session.receiverId.trim();

    if (callId.isEmpty || self.isEmpty || caller.isEmpty || recv.isEmpty) {
      await stop(reason: 'invalid_ids');
      return;
    }
    if (self != caller || self == recv) {
      if (kDebugMode) {
        debugPrint(
          '[ringback] blocked role=receiver self=$self caller=$caller recv=$recv callId=$callId',
        );
      }
      await stop(reason: 'not_outgoing_caller');
      return;
    }

    if (remoteJoined) {
      await stop(reason: 'remote_joined');
      return;
    }
    if (peerAccepted) {
      await stop(reason: 'accepted');
      return;
    }

    if (_activeRingbackCallId == callId && _isPlaying) {
      if (kDebugMode) {
        debugPrint('[ringback] duplicate ignored callId=$callId');
      }
      return;
    }

    if (_activeRingbackCallId != null && _activeRingbackCallId != callId) {
      await stop(reason: 'superseded_by_new_call');
    }

    await _startLocked(callId);
  }

  static Future<void> _startLocked(String callId) async {
    try {
      if (!_playerConfigured) {
        _playerConfigured = true;
        await _player.setReleaseMode(ReleaseMode.loop);
        await _player.setPlayerMode(PlayerMode.mediaPlayer);
        _player.onPlayerComplete.listen((_) {
          _isPlaying = false;
        });
      }
      await _player.stop();
      await _player.play(AssetSource(_assetPath));
      _activeRingbackCallId = callId;
      _isPlaying = true;
      if (kDebugMode) {
        debugPrint('[ringback] start callId=$callId role=caller');
      }
    } catch (e) {
      _isPlaying = false;
      _activeRingbackCallId = null;
      if (kDebugMode) {
        debugPrint('[ringback] play failed callId=$callId err=$e');
      }
    }
  }

  /// Stops ringback if playing. Safe from any thread / role.
  static Future<void> stop({required String reason}) async {
    final hadId = _activeRingbackCallId;
    final wasPlaying = _isPlaying;
    _activeRingbackCallId = null;
    _isPlaying = false;
    try {
      await _player.stop();
    } catch (_) {}
    if (kDebugMode && (wasPlaying || hadId != null)) {
      debugPrint('[ringback] stop reason=$reason callId=${hadId ?? '-'}');
    }
  }

  static Future<void> dispose() async {
    await stop(reason: 'dispose');
    try {
      await _player.dispose();
    } catch (_) {}
    _playerConfigured = false;
  }
}
