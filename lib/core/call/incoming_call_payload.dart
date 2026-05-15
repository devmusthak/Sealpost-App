/// Shared parsing for FCM / VoIP incoming call payloads (no plugin imports).
abstract final class IncomingCallPayload {
  static bool isVoiceCallEnded(Map<String, String> d) {
    final t = (d['type'] ?? '').trim();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    return t == 'voice_call_ended' ||
        t == 'call_ended' ||
        nt == 'call_ended' ||
        nt == 'voice_call_ended';
  }

  static String _callType(Map<String, String> d) =>
      (d['callType'] ?? d['mediaType'] ?? 'audio').trim().toLowerCase();

  static bool isIncomingVideoCall(Map<String, String> d) {
    if (_callType(d) != 'video') return false;
    final t = (d['type'] ?? '').trim().toLowerCase();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    if (t == 'incoming_video_call' || nt == 'incoming_video_call') return true;
    if (t == 'incoming_call' || nt == 'incoming_call') return true;
    return false;
  }

  static bool isIncomingAudioCall(Map<String, String> d) {
    if (_callType(d) == 'video') return false;
    final t = (d['type'] ?? '').trim().toLowerCase();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    if (t == 'incoming_voice_call' || t == 'incoming_call') return true;
    if (nt == 'incoming_call' || nt == 'incoming_voice_call') return true;
    return false;
  }

  static bool isIncomingCall(Map<String, String> d) =>
      isIncomingAudioCall(d) || isIncomingVideoCall(d);

  /// Normal FCM missed-call banner (not CallKit / not incoming_call).
  static bool isMissedVoiceCallNotification(Map<String, String> d) {
    final t = (d['type'] ?? '').trim().toLowerCase();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    return t == 'missed_voice_call' || nt == 'missed_voice_call';
  }

  static bool isMissedVideoCallNotification(Map<String, String> d) {
    final t = (d['type'] ?? '').trim().toLowerCase();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    return t == 'missed_video_call' || nt == 'missed_video_call';
  }

  /// Normalized map for [AgoraCallService.sessionFromInvitePayload] + [PendingVoiceCall].
  static Map<String, String> normalizeInviteStrings(Map<String, String> raw) {
    final out = Map<String, String>.from(raw);
    var token = (out['token'] ?? '').trim();
    if (token.isEmpty) {
      token = (out['agoraToken'] ?? '').trim();
    }
    if (token.isEmpty) {
      token = (out['tokenFetchKey'] ?? '').trim();
    }
    if (token.isNotEmpty) out['token'] = token;
    var uidRaw = (out['uid'] ?? '').trim();
    if (uidRaw.contains('.')) {
      final asDouble = double.tryParse(uidRaw);
      if (asDouble != null) {
        uidRaw = asDouble.toInt().toString();
        out['uid'] = uidRaw;
      }
    }
    final video = _callType(out) == 'video';
    out['callType'] = video ? 'video' : 'audio';
    out['type'] = video ? 'incoming_video_call' : 'incoming_voice_call';
    return out;
  }
}
