import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../core/network/api_endpoints.dart';
import '../auth/auth_repository.dart';
import 'chat_contact.dart';
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
}
