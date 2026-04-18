class ChatUser {
  const ChatUser({
    required this.id,
    required this.email,
    required this.name,
    required this.relationStatus,
    required this.isOnline,
  });

  final String id;
  final String email;
  final String name;
  final String relationStatus;
  final bool isOnline;

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: '${json['id'] ?? ''}'.trim(),
      email: '${json['email'] ?? ''}'.trim(),
      name: '${json['name'] ?? ''}'.trim(),
      relationStatus: '${json['relationStatus'] ?? 'none'}'.trim(),
      isOnline: _parseBool(json['isOnline']),
    );
  }
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
