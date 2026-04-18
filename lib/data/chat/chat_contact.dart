class ChatContact {
  const ChatContact({
    required this.id,
    required this.name,
    required this.email,
    required this.isOnline,
    this.lastSeenAt,
    required this.relationStatus,
    required this.lastMessage,
    required this.timeLabel,
    required this.unreadCount,
  });

  final String id;
  final String name;
  final String email;
  final bool isOnline;
  /// Set when the user last went offline (server `lastSeenAt`).
  final DateTime? lastSeenAt;
  final String relationStatus;
  final String lastMessage;
  final String timeLabel;
  final int unreadCount;

  /// Human-readable line for chat list when [isOnline] is false; null if unknown.
  String? get lastSeenSubtitle {
    if (isOnline || lastSeenAt == null) return null;
    return _formatLastSeen(lastSeenAt!);
  }

  factory ChatContact.fromJson(Map<String, dynamic> json) {
    return ChatContact(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      email: '${json['email'] ?? ''}',
      isOnline: _parseBool(json['isOnline']),
      lastSeenAt: _parseDateTime(json['lastSeenAt']),
      relationStatus: '${json['relationStatus'] ?? 'none'}',
      lastMessage: '${json['lastMessage'] ?? ''}',
      timeLabel: '${json['timeLabel'] ?? ''}',
      unreadCount: int.tryParse('${json['unreadCount'] ?? 0}') ?? 0,
    );
  }
}

DateTime? _parseDateTime(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  final s = '$v'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

String _two(int n) => n < 10 ? '0$n' : '$n';

/// e.g. `3:05 PM`, `12:00 AM`
String _formatTime12h(DateTime d) {
  final h24 = d.hour;
  final isPm = h24 >= 12;
  var h12 = h24 % 12;
  if (h12 == 0) h12 = 12;
  final suffix = isPm ? 'PM' : 'AM';
  return '$h12:${_two(d.minute)} $suffix';
}

String _formatLastSeen(DateTime at) {
  final local = at.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;
  final t = _formatTime12h(local);

  if (diffDays == 0) return 'Last seen today · $t';
  if (diffDays == 1) return 'Last seen yesterday · $t';
  if (diffDays < 7) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return 'Last seen ${wd[local.weekday - 1]} · $t';
  }
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return 'Last seen ${months[local.month - 1]} ${local.day}, ${local.year} · $t';
}

bool _parseBool(dynamic v) {
  if (v == true || v == 1) return true;
  if (v == false || v == 0) return false;
  if (v is String) {
    final s = v.trim().toLowerCase();
    return s == 'true' || s == '1';
  }
  return false;
}
