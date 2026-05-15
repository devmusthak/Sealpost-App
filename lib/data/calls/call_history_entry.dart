/// One row from GET /api/chat/call/history (before optional client-side missed grouping).
class CallHistoryEntry {
  const CallHistoryEntry({
    required this.callId,
    required this.peerId,
    required this.peerName,
    required this.peerEmail,
    required this.peerAvatar,
    required this.callType,
    required this.direction,
    required this.status,
    required this.durationSeconds,
    required this.createdAt,
  });

  final String callId;
  final String peerId;
  final String peerName;
  final String peerEmail;
  final String peerAvatar;
  /// `audio` | `video`
  final String callType;
  /// `incoming` | `outgoing`
  final String direction;
  /// `missed` | `rejected` | `ended` (server maps `cancelled` per viewer)
  final String status;
  final int durationSeconds;
  final DateTime createdAt;

  bool get isVideo => callType.toLowerCase() == 'video';
  bool get isOutgoing => direction.toLowerCase() == 'outgoing';
  bool get isMissed => status.toLowerCase() == 'missed';
  bool get isRejected => status.toLowerCase() == 'rejected';
  bool get isEnded => status.toLowerCase() == 'ended';

  Map<String, dynamic> toJson() => {
        'callId': callId,
        'peerId': peerId,
        'peerName': peerName,
        'peerEmail': peerEmail,
        'peerAvatar': peerAvatar,
        'callType': callType,
        'direction': direction,
        'status': status,
        'durationSeconds': durationSeconds,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory CallHistoryEntry.fromJson(Map<String, dynamic> json) {
    final createdRaw = '${json['createdAt'] ?? ''}'.trim();
    DateTime created;
    try {
      created = DateTime.parse(createdRaw).toLocal();
    } catch (_) {
      created = DateTime.now();
    }
    return CallHistoryEntry(
      callId: '${json['callId'] ?? ''}'.trim(),
      peerId: '${json['peerId'] ?? ''}'.trim(),
      peerName: '${json['peerName'] ?? ''}'.trim(),
      peerEmail: '${json['peerEmail'] ?? ''}'.trim(),
      peerAvatar: '${json['peerAvatar'] ?? ''}'.trim(),
      callType: '${json['callType'] ?? 'audio'}'.trim().toLowerCase(),
      direction: '${json['direction'] ?? 'incoming'}'.trim().toLowerCase(),
      status: '${json['status'] ?? ''}'.trim().toLowerCase(),
      durationSeconds: int.tryParse('${json['durationSeconds'] ?? 0}') ?? 0,
      createdAt: created,
    );
  }
}

/// Display row after grouping consecutive peer misses.
class CallHistoryDisplayRow {
  const CallHistoryDisplayRow({
    required this.representative,
    this.missedCount = 1,
  });

  final CallHistoryEntry representative;
  final int missedCount;

  bool get hasGroupedMisses => missedCount > 1;
}

/// Groups consecutive incoming missed rows per peer (WhatsApp-style).
List<CallHistoryDisplayRow> groupCallHistoryRows(List<CallHistoryEntry> apiOrder) {
  final sorted = List<CallHistoryEntry>.from(apiOrder)
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final out = <CallHistoryDisplayRow>[];
  var i = 0;
  while (i < sorted.length) {
    final e = sorted[i];
    if (e.isMissed && !e.isOutgoing) {
      var j = i + 1;
      var count = 1;
      while (j < sorted.length) {
        final e2 = sorted[j];
        if (!e2.isMissed || e2.isOutgoing || e2.peerId != e.peerId) break;
        count++;
        j++;
      }
      out.add(CallHistoryDisplayRow(representative: e, missedCount: count));
      i = j;
    } else {
      out.add(CallHistoryDisplayRow(representative: e));
      i++;
    }
  }
  return out;
}
