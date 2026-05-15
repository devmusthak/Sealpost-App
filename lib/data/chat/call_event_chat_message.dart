import 'dart:convert';

/// Server `t: call_event` (and legacy `t: vc_notice`) for WhatsApp-style call rows in DM.
class CallEventChatMessage {
  const CallEventChatMessage({
    required this.kind,
    required this.callId,
    required this.callType,
    required this.callStatus,
    required this.callerId,
    required this.receiverId,
    required this.durationSeconds,
    this.ringCause = '',
    this.createdAtIso = '',
  });

  /// `missed_voice_call` | `voice_call` | `missed_video_call` | `video_call`
  final String kind;
  final String callId;
  final String callType;
  final String callStatus;
  final String callerId;
  final String receiverId;
  final int durationSeconds;
  final String ringCause;
  final String createdAtIso;

  bool get isMissedKind =>
      kind == 'missed_voice_call' || kind == 'missed_video_call';

  bool get isVideoKind => kind == 'missed_video_call' || kind == 'video_call';

  static CallEventChatMessage? tryParse(String raw) {
    final t = raw.trim();
    if (!t.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(t);
      if (decoded is! Map) return null;
      final m = Map<String, dynamic>.from(decoded);
      final type = '${m['t'] ?? ''}'.trim();
      if (type == 'vc_notice') {
        return _fromLegacyVcNotice(m);
      }
      if (type != 'call_event') return null;
      final kind = '${m['kind'] ?? ''}'.trim();
      final callId = '${m['callId'] ?? ''}'.trim();
      final callerId = '${m['callerId'] ?? ''}'.trim();
      final receiverId = '${m['receiverId'] ?? ''}'.trim();
      final callType = '${m['callType'] ?? 'audio'}'.trim();
      final callStatus = '${m['callStatus'] ?? ''}'.trim();
      if (callId.isEmpty || callerId.isEmpty || receiverId.isEmpty) return null;
      final allowed = {
        'missed_voice_call',
        'voice_call',
        'missed_video_call',
        'video_call',
      };
      if (!allowed.contains(kind)) return null;
      final ds = int.tryParse('${m['durationSeconds'] ?? 0}') ?? 0;
      return CallEventChatMessage(
        kind: kind,
        callId: callId,
        callType: callType == 'video' ? 'video' : 'audio',
        callStatus: callStatus,
        callerId: callerId,
        receiverId: receiverId,
        durationSeconds: ds < 0 ? 0 : ds,
        ringCause: '${m['ringCause'] ?? ''}'.trim(),
        createdAtIso: '${m['createdAt'] ?? ''}'.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  static CallEventChatMessage? _fromLegacyVcNotice(Map<String, dynamic> m) {
    final callId = '${m['callId'] ?? ''}'.trim();
    final callerId = '${m['callerId'] ?? ''}'.trim();
    final receiverId = '${m['receiverId'] ?? ''}'.trim();
    final cause = '${m['cause'] ?? ''}'.trim();
    if (callId.isEmpty || callerId.isEmpty || receiverId.isEmpty) return null;
    if (cause != 'timeout' && cause != 'caller_cancelled') return null;
    return CallEventChatMessage(
      kind: 'missed_voice_call',
      callId: callId,
      callType: 'audio',
      callStatus: cause == 'caller_cancelled' ? 'cancelled' : 'missed',
      callerId: callerId,
      receiverId: receiverId,
      durationSeconds: 0,
      ringCause: cause,
      createdAtIso: '',
    );
  }

  /// Primary line (bold in UI).
  String titleForViewer(String _) {
    if (isMissedKind) {
      if (isVideoKind) return 'Missed video call';
      return 'Missed voice call';
    }
    if (isVideoKind) return 'Video call';
    return 'Voice call';
  }

  /// Subtitle: duration, tap hint, or status line.
  String? subtitleForViewer(String myUserId) {
    final me = myUserId.trim();
    if (isMissedKind) {
      if (me == receiverId.trim()) {
        return 'Tap to call back';
      }
      if (ringCause == 'caller_cancelled') {
        return 'Cancelled';
      }
      return 'No answer';
    }
    if ((kind == 'voice_call' || kind == 'video_call') && callStatus == 'ended') {
      return formatCallDuration(durationSeconds);
    }
    return null;
  }

  /// Red missed style only for callee who missed (incoming missed row).
  bool missedCalleeStyle(String myUserId) =>
      isMissedKind && myUserId.trim() == receiverId.trim();

  static String formatCallDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0 sec';
    if (totalSeconds < 60) {
      return '$totalSeconds sec';
    }
    final m = totalSeconds ~/ 60;
    if (m < 60) {
      return m == 1 ? '1 min' : '$m min';
    }
    final h = m ~/ 60;
    final rem = m % 60;
    if (rem == 0) {
      return h == 1 ? '1 hr' : '$h hr';
    }
    return '$h hr $rem min';
  }
}
