import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../core/network/api_endpoints.dart';
import '../auth/auth_repository.dart';
import 'chat_contact.dart';
import 'chat_group.dart';
import 'chat_message_dto.dart';
import 'chat_user.dart';

class ChatRepository {
  ChatRepository(this._dio);

  final Dio _dio;

  Future<List<ChatUser>> searchUsersByEmail(String query, {int limit = 20}) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final res = await _dio.get<dynamic>(
      ApiEndpoints.userSearch,
      queryParameters: {
        'q': q,
        'limit': limit,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );

    final raw = res.data;
    if (raw is! Map) return const [];
    final items = raw['items'];
    if (items is! List) return const [];
    final out = <ChatUser>[];
    for (final e in items) {
      if (e is! Map) continue;
      out.add(ChatUser.fromJson(Map<String, dynamic>.from(e)));
    }
    return out;
  }

  Future<String> sendFriendRequest(String targetUserId) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatFriendRequest,
      data: {'targetUserId': targetUserId},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is Map && raw['relationStatus'] != null) {
      return '${raw['relationStatus']}';
    }
    return 'request_sent';
  }

  Future<String> acceptFriendRequest(String targetUserId) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatAcceptFriendRequest,
      data: {'targetUserId': targetUserId},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is Map && raw['relationStatus'] != null) {
      return '${raw['relationStatus']}';
    }
    return 'friends';
  }

  Future<void> notifyFriendRequestUser(String targetUserId) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    await _dio.post<dynamic>(
      ApiEndpoints.chatNotifyFriendRequest,
      data: {'targetUserId': targetUserId},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  Future<List<ChatContact>> fetchContacts() async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.get<dynamic>(
      ApiEndpoints.chatContacts,
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) return const [];
    final items = raw['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => ChatContact.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<ChatMessageDto>> fetchChatMessages({
    required String peerId,
    String? before,
    int limit = 50,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.get<dynamic>(
      ApiEndpoints.chatMessages,
      queryParameters: {
        'peerId': peerId,
        'limit': limit,
        if (before != null && before.isNotEmpty) 'before': before,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) return const [];
    final items = raw['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => ChatMessageDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<ChatMessageDto>> fetchGroupMessages({
    required String groupId,
    String? before,
    int limit = 50,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.get<dynamic>(
      ApiEndpoints.chatGroupMessages,
      queryParameters: {
        'groupId': groupId,
        'limit': limit,
        if (before != null && before.isNotEmpty) 'before': before,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) return const [];
    final items = raw['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => ChatMessageDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<SendChatMessageResult> sendChatMessage({
    required String peerId,
    required String body,
    required String clientId,
    String? replyToMessageId,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final rt = replyToMessageId?.trim();
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatMessages,
      data: {
        'peerId': peerId,
        'body': body,
        'clientId': clientId,
        if (rt != null && rt.isNotEmpty) 'replyToMessageId': rt,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid send response');
    }
    final msgRaw = raw['message'];
    if (msgRaw is! Map) {
      throw StateError('Invalid send response');
    }
    return SendChatMessageResult(
      message: ChatMessageDto.fromJson(Map<String, dynamic>.from(msgRaw)),
      duplicate: raw['duplicate'] == true,
      peerOnline: raw['peerOnline'] == true,
    );
  }

  Future<SendChatMessageResult> sendGroupMessage({
    required String groupId,
    required String body,
    required String clientId,
    String? replyToMessageId,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final rt = replyToMessageId?.trim();
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatGroupMessages,
      data: {
        'groupId': groupId,
        'body': body,
        'clientId': clientId,
        if (rt != null && rt.isNotEmpty) 'replyToMessageId': rt,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid send response');
    }
    final msgRaw = raw['message'];
    if (msgRaw is! Map) {
      throw StateError('Invalid send response');
    }
    return SendChatMessageResult(
      message: ChatMessageDto.fromJson(Map<String, dynamic>.from(msgRaw)),
      duplicate: raw['duplicate'] == true,
      peerOnline: raw['peerOnline'] == true,
    );
  }

  Future<void> markChatMessagesRead({
    required String peerId,
    required String readUpToId,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    await _dio.post<dynamic>(
      ApiEndpoints.chatMessagesRead,
      data: {
        'peerId': peerId,
        'readUpToId': readUpToId,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  Future<void> markGroupMessagesRead({
    required String groupId,
    required String readUpToId,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    await _dio.post<dynamic>(
      ApiEndpoints.chatGroupMessagesRead,
      data: {
        'groupId': groupId,
        'readUpToId': readUpToId,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  /// Sets or removes your reaction. Empty [emoji] removes. Same emoji again toggles off (server).
  Future<ChatMessageDto> setChatMessageReaction({
    required String peerId,
    required String messageId,
    required String emoji,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatMessageReaction,
      data: {
        'peerId': peerId,
        'messageId': messageId,
        'emoji': emoji,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid reaction response');
    }
    final msgRaw = raw['message'];
    if (msgRaw is! Map) {
      throw StateError('Invalid reaction response');
    }
    return ChatMessageDto.fromJson(Map<String, dynamic>.from(msgRaw));
  }

  Future<ChatMessageDto> setGroupMessageReaction({
    required String groupId,
    required String messageId,
    required String emoji,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatGroupMessageReaction,
      data: {
        'groupId': groupId,
        'messageId': messageId,
        'emoji': emoji,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid reaction response');
    }
    final msgRaw = raw['message'];
    if (msgRaw is! Map) {
      throw StateError('Invalid reaction response');
    }
    return ChatMessageDto.fromJson(Map<String, dynamic>.from(msgRaw));
  }

  /// Sender-only; server rejects outside the edit window.
  Future<ChatMessageDto> editChatMessage({
    required String peerId,
    required String messageId,
    required String body,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.patch<dynamic>(
      ApiEndpoints.chatMessageEdit,
      data: {
        'peerId': peerId,
        'messageId': messageId,
        'body': body,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid edit response');
    }
    final msgRaw = raw['message'];
    if (msgRaw is! Map) {
      throw StateError('Invalid edit response');
    }
    return ChatMessageDto.fromJson(Map<String, dynamic>.from(msgRaw));
  }

  Future<ChatMessageDto> editGroupMessage({
    required String groupId,
    required String messageId,
    required String body,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.patch<dynamic>(
      ApiEndpoints.chatGroupMessageEdit,
      data: {
        'groupId': groupId,
        'messageId': messageId,
        'body': body,
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid edit response');
    }
    final msgRaw = raw['message'];
    if (msgRaw is! Map) {
      throw StateError('Invalid edit response');
    }
    return ChatMessageDto.fromJson(Map<String, dynamic>.from(msgRaw));
  }

  Future<String> createGroup({
    required String groupName,
    String? groupImage,
    String? description,
    required List<String> memberIds,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    try {
      final res = await _dio.post<dynamic>(
        ApiEndpoints.chatGroups,
        data: {
          'groupName': groupName,
          if (groupImage != null && groupImage.trim().isNotEmpty)
            'groupImage': groupImage.trim(),
          if (description != null && description.trim().isNotEmpty)
            'description': description.trim(),
          'memberIds': memberIds,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final raw = res.data;
      if (raw is! Map) throw StateError('Invalid create group response');
      final groupId = '${raw['groupId'] ?? raw['id'] ?? ''}'.trim();
      if (groupId.isEmpty) throw StateError('Missing group id');
      return groupId;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw StateError(
          'Group API is not available on server yet (POST ${ApiEndpoints.chatGroups}).',
        );
      }
      final data = e.response?.data;
      if (data is Map && data['message'] != null) {
        throw StateError('${data['message']}');
      }
      throw StateError('Could not create group. Please try again.');
    }
  }

  Future<void> respondGroupInvite({
    required String groupId,
    required bool accept,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    await _dio.post<dynamic>(
      ApiEndpoints.chatGroupInvites,
      data: {
        'groupId': groupId,
        'action': accept ? 'accept' : 'reject',
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  Future<ChatGroupInfo> fetchGroupInfo(String groupId) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.get<dynamic>(
      '${ApiEndpoints.chatGroups}/$groupId',
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) throw StateError('Invalid group info response');
    return ChatGroupInfo.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<ChatGroupInfo> updateGroupInfo({
    required String groupId,
    required String groupName,
    String? description,
    String? groupImage,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final res = await _dio.patch<dynamic>(
      '${ApiEndpoints.chatGroups}/$groupId',
      data: {
        'groupName': groupName.trim(),
        if (description != null) 'description': description.trim(),
        if (groupImage != null) 'groupImage': groupImage.trim(),
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final raw = res.data;
    if (raw is! Map) throw StateError('Invalid group update response');
    return ChatGroupInfo.fromJson(Map<String, dynamic>.from(raw));
  }
}
