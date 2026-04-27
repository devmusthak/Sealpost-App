import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../network/api_endpoints.dart';
import 'agora_call_config.dart';

class AgoraCallSession {
  const AgoraCallSession({
    required this.channelName,
    required this.token,
    required this.localUid,
  });

  final String channelName;
  final String? token;
  final int localUid;
}

class AgoraCallService extends GetxService {
  String get appId => AgoraCallConfig.appId;

  AgoraCallSession sessionFromInvitePayload(Map<String, dynamic> payload) {
    final channelName = '${payload['channelName'] ?? ''}'.trim();
    final token = '${payload['token'] ?? ''}'.trim();
    final uid = int.tryParse('${payload['uid'] ?? ''}') ?? -1;
    if (channelName.isEmpty || token.isEmpty || uid < 0) {
      throw StateError('Invalid incoming call payload');
    }
    return AgoraCallSession(
      channelName: channelName,
      token: token,
      localUid: uid,
    );
  }

  Future<AgoraCallSession> createAudioSession({
    required String peerId,
    required String conversationId,
  }) async {
    final normalizedPeer = _normalizeId(peerId);
    final normalizedConversation = _normalizeId(conversationId);
    if (normalizedPeer.isEmpty || normalizedConversation.isEmpty) {
      throw StateError('Invalid call target');
    }

    final channelName = 'sealpost_audio_$normalizedConversation';
    final localUid = DateTime.now().millisecondsSinceEpoch % 2147483000;
    final token = await _tryFetchRtcToken(channelName: channelName, uid: localUid);

    return AgoraCallSession(
      channelName: channelName,
      token: token,
      localUid: localUid,
    );
  }

  Future<AgoraCallSession> createAndInviteAudioSession({
    required String peerId,
    required String peerName,
    required String conversationId,
    required String callerName,
  }) async {
    final normalizedPeer = _normalizeId(peerId);
    final normalizedConversation = _normalizeId(conversationId);
    if (normalizedPeer.isEmpty || normalizedConversation.isEmpty) {
      throw StateError('Invalid call target');
    }
    if (!Get.isRegistered<Dio>()) {
      throw StateError('Network is not ready');
    }
    final callerUid = DateTime.now().millisecondsSinceEpoch % 2147483000;
    final dio = Get.find<Dio>();
    final res = await dio.post(
      ApiEndpoints.agoraCallInvite,
      data: {
        'peerId': peerId,
        'peerName': peerName,
        'conversationId': conversationId,
        'callerUid': callerUid,
        'callerName': callerName,
        'expireSeconds': 3600,
      },
    );
    final body = _toMap(res.data);
    if ((res.statusCode ?? 500) >= 400) {
      final msg = '${body['message'] ?? 'Call invite failed'}'.trim();
      throw StateError(msg.isEmpty ? 'Call invite failed' : msg);
    }
    if (body.isEmpty) {
      throw StateError(
        'Invalid call invite response (empty). Check API_BASE_URL and backend route /api/chat/call/agora-invite.',
      );
    }
    final token = '${body['token'] ?? ''}'.trim();
    final channelName = '${body['channelName'] ?? ''}'.trim();
    final uid = int.tryParse('${body['uid'] ?? ''}') ?? -1;
    if (token.isEmpty || channelName.isEmpty || uid < 0) {
      throw StateError(
        'Call invite returned invalid session details. Got keys: ${body.keys.join(', ')}',
      );
    }
    return AgoraCallSession(
      channelName: channelName,
      token: token,
      localUid: uid,
    );
  }

  String _normalizeId(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    final cleaned = v.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }

  Future<String?> _tryFetchRtcToken({
    required String channelName,
    required int uid,
  }) async {
    if (!Get.isRegistered<Dio>()) return null;
    final dio = Get.find<Dio>();
    try {
      final res = await dio.post(
        ApiEndpoints.agoraRtcToken,
        data: {
          'channelName': channelName,
          'uid': uid,
          'role': 'publisher',
          'expireSeconds': 3600,
        },
      );
      final body = res.data;
      if (body is Map && body['token'] != null) {
        final token = '${body['token']}'.trim();
        return token.isEmpty ? null : token;
      }
    } catch (_) {
      // If server token API is not available yet, continue with null token.
    }
    return null;
  }

  Map<String, dynamic> _toMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      final s = data.trim();
      if (s.isEmpty) return const {};
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return {'message': s};
      }
      return const {};
    }
    return const {};
  }
}
