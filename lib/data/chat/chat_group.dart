class ChatGroupMember {
  const ChatGroupMember({
    required this.userId,
    required this.name,
    required this.email,
    required this.status,
    required this.isAdmin,
    this.isOnline = false,
    this.avatarUrl = '',
  });

  final String userId;
  final String name;
  final String email;
  final String status;
  final bool isAdmin;
  final bool isOnline;
  final String avatarUrl;

  bool get isAccepted => status.toLowerCase() == 'accepted';

  factory ChatGroupMember.fromJson(Map<String, dynamic> json) {
    final status = '${json['status'] ?? 'pending'}'.trim().toLowerCase();
    return ChatGroupMember(
      userId: '${json['userId'] ?? json['id'] ?? ''}'.trim(),
      name: '${json['name'] ?? ''}'.trim(),
      email: '${json['email'] ?? ''}'.trim(),
      status: status.isEmpty ? 'pending' : status,
      isAdmin: json['isAdmin'] == true || json['role'] == 'admin',
      isOnline: json['isOnline'] == true || json['online'] == true,
      avatarUrl: '${json['avatarUrl'] ?? json['image'] ?? ''}'.trim(),
    );
  }
}

class ChatGroupInfo {
  const ChatGroupInfo({
    required this.groupId,
    required this.groupName,
    required this.groupImage,
    required this.description,
    required this.createdBy,
    this.createdAt,
    this.memberCount = 0,
    this.inviteLink = '',
    required this.members,
  });

  final String groupId;
  final String groupName;
  final String groupImage;
  final String description;
  final String createdBy;
  final DateTime? createdAt;
  final int memberCount;
  final String inviteLink;
  final List<ChatGroupMember> members;

  factory ChatGroupInfo.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'];
    final members = <ChatGroupMember>[];
    if (rawMembers is List) {
      for (final e in rawMembers) {
        if (e is! Map) continue;
        members.add(ChatGroupMember.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return ChatGroupInfo(
      groupId: '${json['groupId'] ?? json['id'] ?? ''}'.trim(),
      groupName: '${json['groupName'] ?? json['name'] ?? ''}'.trim(),
      groupImage: '${json['groupImage'] ?? json['image'] ?? ''}'.trim(),
      description: '${json['description'] ?? ''}'.trim(),
      createdBy: '${json['createdBy'] ?? ''}'.trim(),
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      memberCount: int.tryParse('${json['memberCount'] ?? members.where((m) => m.isAccepted).length}') ??
          members.where((m) => m.isAccepted).length,
      inviteLink: '${json['inviteLink'] ?? ''}'.trim(),
      members: members,
    );
  }
}

class ChatGroupSharedItem {
  const ChatGroupSharedItem({
    required this.id,
    required this.type,
    required this.body,
    required this.createdAt,
    required this.senderId,
  });

  final String id;
  final String type;
  final String body;
  final DateTime? createdAt;
  final String senderId;

  factory ChatGroupSharedItem.fromJson(Map<String, dynamic> json) {
    return ChatGroupSharedItem(
      id: '${json['id'] ?? ''}'.trim(),
      type: '${json['type'] ?? ''}'.trim(),
      body: '${json['body'] ?? ''}',
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      senderId: '${json['senderId'] ?? ''}'.trim(),
    );
  }
}
