class ChatGroupMember {
  const ChatGroupMember({
    required this.userId,
    required this.name,
    required this.email,
    required this.status,
    required this.isAdmin,
  });

  final String userId;
  final String name;
  final String email;
  final String status;
  final bool isAdmin;

  bool get isAccepted => status.toLowerCase() == 'accepted';

  factory ChatGroupMember.fromJson(Map<String, dynamic> json) {
    final status = '${json['status'] ?? 'pending'}'.trim().toLowerCase();
    return ChatGroupMember(
      userId: '${json['userId'] ?? json['id'] ?? ''}'.trim(),
      name: '${json['name'] ?? ''}'.trim(),
      email: '${json['email'] ?? ''}'.trim(),
      status: status.isEmpty ? 'pending' : status,
      isAdmin: json['isAdmin'] == true || json['role'] == 'admin',
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
    required this.members,
  });

  final String groupId;
  final String groupName;
  final String groupImage;
  final String description;
  final String createdBy;
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
      members: members,
    );
  }
}
