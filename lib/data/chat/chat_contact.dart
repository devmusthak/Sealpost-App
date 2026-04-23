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
    this.lastMessageAt,
    required this.unreadCount,
    this.conversationType = 'direct',
    this.groupId,
    this.groupImage = '',
    this.groupDescription = '',
    this.createdBy = '',
    this.memberNames = const [],
    this.memberStatus = 'accepted',
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

  /// UTC from API; when set, [chatHomeTimeLabel] uses device local timezone.
  final DateTime? lastMessageAt;
  final int unreadCount;
  final String conversationType;
  final String? groupId;
  final String groupImage;
  final String groupDescription;
  final String createdBy;
  final List<String> memberNames;
  final String memberStatus;

  bool get isGroupConversation =>
      conversationType == 'group' || (groupId != null && groupId!.isNotEmpty);
  bool get isGroupInvitePending =>
      isGroupConversation && memberStatus.toLowerCase() == 'pending';
  String get conversationId =>
      isGroupConversation ? (groupId?.trim().isNotEmpty == true ? groupId!.trim() : id) : id;

  /// Chat list row time — prefers [lastMessageAt] formatted locally over server [timeLabel].
  String get chatHomeTimeLabel {
    if (lastMessageAt != null) {
      return _chatListRowTime(lastMessageAt!);
    }
    return timeLabel;
  }

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
      lastMessageAt: _parseDateTime(json['lastMessageAt']),
      unreadCount: int.tryParse('${json['unreadCount'] ?? 0}') ?? 0,
      conversationType: '${json['conversationType'] ?? (json['groupId'] != null ? 'group' : 'direct')}'
          .trim()
          .toLowerCase(),
      groupId: _asNullableString(json['groupId'] ?? json['conversationId']),
      groupImage: '${json['groupImage'] ?? json['image'] ?? ''}'.trim(),
      groupDescription: '${json['groupDescription'] ?? json['description'] ?? ''}'.trim(),
      createdBy: '${json['createdBy'] ?? ''}'.trim(),
      memberNames: _parseMemberNames(json['memberNames'] ?? json['members']),
      memberStatus: '${json['memberStatus'] ?? json['inviteStatus'] ?? 'accepted'}'
          .trim()
          .toLowerCase(),
    );
  }
}

String? _asNullableString(dynamic v) {
  if (v == null) return null;
  final s = '$v'.trim();
  if (s.isEmpty) return null;
  return s;
}

List<String> _parseMemberNames(dynamic v) {
  if (v is! List) return const [];
  final out = <String>[];
  for (final e in v) {
    if (e is String) {
      final s = e.trim();
      if (s.isNotEmpty) out.add(s);
      continue;
    }
    if (e is Map) {
      final m = Map<String, dynamic>.from(e);
      final n = '${m['name'] ?? ''}'.trim();
      if (n.isNotEmpty) out.add(n);
    }
  }
  return out;
}

DateTime? _parseDateTime(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  final s = '$v'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

String _two(int n) => n < 10 ? '0$n' : '$n';

/// Same rules as server `chatListTimeLabel`, in the device's local timezone.
String _chatListRowTime(DateTime at) {
  final d = at.toLocal();
  final now = DateTime.now();
  final sameDay =
      d.year == now.year && d.month == now.month && d.day == now.day;
  if (sameDay) {
    return _formatTime12h(d);
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
    'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}';
}

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
