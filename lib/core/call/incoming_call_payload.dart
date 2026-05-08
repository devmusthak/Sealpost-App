/// Shared parsing for FCM / VoIP incoming voice call payloads (no plugin imports).
abstract final class IncomingCallPayload {
  static bool isVoiceCallEnded(Map<String, String> d) {
    final t = (d['type'] ?? '').trim();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    return t == 'voice_call_ended' ||
        t == 'call_ended' ||
        nt == 'call_ended' ||
        nt == 'voice_call_ended';
  }

  static bool isIncomingAudioCall(Map<String, String> d) {
    final t = (d['type'] ?? '').trim().toLowerCase();
    final nt = (d['notificationType'] ?? '').trim().toLowerCase();
    final callType = (d['callType'] ?? d['mediaType'] ?? 'audio').trim().toLowerCase();
    final isAudio = callType.isEmpty || callType == 'audio' || callType == 'voice';
    if (t == 'incoming_voice_call' || t == 'incoming_call') return isAudio;
    if (nt == 'incoming_call' || nt == 'incoming_voice_call') return isAudio;
    return false;
  }

  /// Normalized map for [AgoraCallService.sessionFromInvitePayload] + [PendingVoiceCall].
  static Map<String, String> normalizeInviteStrings(Map<String, String> raw) {
    final out = Map<String, String>.from(raw);
    var token = (out['token'] ?? '').trim();
    if (token.isEmpty) {
      token = (out['agoraToken'] ?? '').trim();
    }
    if (token.isNotEmpty) out['token'] = token;
    out['type'] = 'incoming_voice_call';
    return out;
  }
}
