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

class ChatMessageDto {
  const ChatMessageDto({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.body,
    this.clientId,
    required this.createdAt,
    this.readAt,
    this.replyTo,
  });

  final String id;
  final String senderId;
  final String recipientId;
  final String body;
  final String? clientId;
  final DateTime createdAt;
  final DateTime? readAt;
  final ChatReplyQuote? replyTo;

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  factory ChatMessageDto.fromJson(Map<String, dynamic> json) {
    return ChatMessageDto(
      id: '${json['id'] ?? ''}',
      senderId: '${json['senderId'] ?? ''}',
      recipientId: '${json['recipientId'] ?? ''}',
      body: '${json['body'] ?? ''}',
      clientId: json['clientId'] != null && '${json['clientId']}'.trim().isNotEmpty
          ? '${json['clientId']}'.trim()
          : null,
      createdAt: _parseDate(json['createdAt']) ?? DateTime.now().toUtc(),
      readAt: _parseDate(json['readAt']),
      replyTo: ChatReplyQuote.fromJson(json['replyTo']),
    );
  }
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
