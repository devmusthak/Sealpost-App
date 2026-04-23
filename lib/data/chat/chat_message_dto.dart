/// Inline quote for a reply (mirrors server `replyTo`).
class ChatReplyQuote {
  const ChatReplyQuote({
    required this.messageId,
    required this.senderId,
    required this.bodyPreview,
  });

  final String messageId;
  final String senderId;
  final String bodyPreview;

  bool get isEmpty => messageId.isEmpty;

  static ChatReplyQuote? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = '${m['id'] ?? m['messageId'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    return ChatReplyQuote(
      messageId: id,
      senderId: '${m['senderId'] ?? ''}'.trim(),
      bodyPreview: '${m['bodyPreview'] ?? ''}'.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': messageId,
        'senderId': senderId,
        'bodyPreview': bodyPreview,
      };
}

class ChatReactionEntry {
  const ChatReactionEntry({
    required this.userId,
    required this.emoji,
  });

  final String userId;
  final String emoji;

  static ChatReactionEntry? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final uid = '${m['userId'] ?? ''}'.trim();
    final em = '${m['emoji'] ?? ''}'.trim();
    if (uid.isEmpty || em.isEmpty) return null;
    return ChatReactionEntry(userId: uid, emoji: em);
  }

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'emoji': emoji,
      };
}

class ChatMessageDto {
  const ChatMessageDto({
    required this.id,
    required this.senderId,
    required this.recipientId,
    this.groupId,
    this.senderName,
    this.conversationType = 'direct',
    required this.body,
    this.clientId,
    required this.createdAt,
    this.readAt,
    this.editedAt,
    this.replyTo,
    this.reactions = const [],
  });

  final String id;
  final String senderId;
  final String recipientId;
  final String? groupId;
  final String? senderName;
  final String conversationType;
  final String body;
  final String? clientId;
  final DateTime createdAt;
  final DateTime? readAt;
  /// Server sets on first successful edit (sender-only, time window).
  final DateTime? editedAt;
  final ChatReplyQuote? replyTo;
  final List<ChatReactionEntry> reactions;

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  static List<ChatReactionEntry> _reactionsFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final out = <ChatReactionEntry>[];
    for (final e in raw) {
      final r = ChatReactionEntry.fromJson(e);
      if (r != null) out.add(r);
    }
    return out;
  }

  factory ChatMessageDto.fromJson(Map<String, dynamic> json) {
    return ChatMessageDto(
      id: '${json['id'] ?? ''}',
      senderId: '${json['senderId'] ?? ''}',
      recipientId: '${json['recipientId'] ?? ''}',
      groupId: _maybeString(json['groupId'] ?? json['conversationId']),
      senderName: _maybeString(json['senderName'] ?? json['fromName']),
      conversationType: '${json['conversationType'] ?? (json['groupId'] != null ? 'group' : 'direct')}'
          .trim()
          .toLowerCase(),
      body: '${json['body'] ?? ''}',
      clientId: json['clientId'] != null && '${json['clientId']}'.trim().isNotEmpty
          ? '${json['clientId']}'.trim()
          : null,
      createdAt: _parseDate(json['createdAt']) ?? DateTime.now().toUtc(),
      readAt: _parseDate(json['readAt']),
      editedAt: _parseDate(json['editedAt']),
      replyTo: ChatReplyQuote.fromJson(json['replyTo']),
      reactions: _reactionsFromJson(json['reactions']),
    );
  }
}

String? _maybeString(dynamic v) {
  if (v == null) return null;
  final s = '$v'.trim();
  if (s.isEmpty) return null;
  return s;
}

class SendChatMessageResult {
  const SendChatMessageResult({
    required this.message,
    required this.duplicate,
    required this.peerOnline,
  });

  final ChatMessageDto message;
  final bool duplicate;
  final bool peerOnline;
}
