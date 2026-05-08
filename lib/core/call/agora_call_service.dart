import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../network/api_endpoints.dart';
import 'agora_call_config.dart';
import '../../data/auth/auth_repository.dart';

/// Server-driven 1:1 voice call session (Agora RTC).
class VoiceCallSession {
  const VoiceCallSession({
    required this.callId,
    required this.channelName,
    required this.token,
    required this.localUid,
    required this.agoraAppId,
    required this.peerName,
    required this.peerUserId,
    required this.selfUserId,
    required this.isIncoming,
    this.conversationId,
    this.outgoingCalleeRingingHint = false,
  });

  final String callId;
  final String channelName;
  final String? token;
  final int localUid;

  /// Prefer token from server invite; fallback to local env [AgoraCallConfig.appId] only if empty.
  final String agoraAppId;
  final String peerName;
  final String peerUserId;
  final String selfUserId;
  final bool isIncoming;
  final String? conversationId;

  /// Outgoing: server says callee had an active socket — show "Ringing…" immediately (avoids missing socket race).
  final bool outgoingCalleeRingingHint;

  String get effectiveAppId =>
      agoraAppId.trim().isNotEmpty ? agoraAppId.trim() : AgoraCallConfig.appId;
}

/// Realtime call signaling (socket + optional FCM wake).
class AgoraCallService extends GetxService {
  final _callEvents = StreamController<Map<String, dynamic>>.broadcast();

  /// Payload includes `_event` (socket name) plus server fields.
  Stream<Map<String, dynamic>> get callEvents => _callEvents.stream;

  /// Deduplicate overlapping socket + push for the same [callId].
  String? _activeUiCallId;

  String? get activeUiCallId => _activeUiCallId;

  bool claimCallUi(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return true;
    if (_activeUiCallId != null) {
      return false;
    }
    _activeUiCallId = id;
    return true;
  }

  void releaseCallUi([String? callId]) {
    final id = callId?.trim();
    if (id == null || id.isEmpty) {
      _activeUiCallId = null;
      return;
    }
    if (_activeUiCallId == id) _activeUiCallId = null;
  }

  void emitCallSignal(String eventName, dynamic data) {
    final Map<String, dynamic> base = <String, dynamic>{};
    if (data is Map) {
      for (final e in data.entries) {
        base['${e.key}'] = e.value;
      }
    }
    base['_event'] = eventName;
    if (!_callEvents.isClosed) {
      _callEvents.add(base);
    }
  }

  String get fallbackAppId => AgoraCallConfig.appId;

  VoiceCallSession sessionFromInvitePayload(
    Map<String, dynamic> payload, {
    required String selfUserId,
  }) {
    final channelName = '${payload['channelName'] ?? ''}'.trim();
    final token =
        '${payload['token'] ?? payload['agoraToken'] ?? ''}'.trim();
    final uid = int.tryParse('${payload['uid'] ?? ''}') ?? -1;
    final callId = '${payload['callId'] ?? ''}'.trim();
    final appIdRaw = '${payload['appId'] ?? ''}'.trim();
    final callerId =
        '${payload['callerId'] ?? payload['fromUserId'] ?? ''}'.trim();
    final receiverId = '${payload['receiverId'] ?? ''}'.trim();
    final name =
        '${payload['callerName'] ?? payload['fromName'] ?? 'Caller'}'.trim();
    final conversationId = '${payload['conversationId'] ?? ''}'.trim();
    if (channelName.isEmpty || token.isEmpty || uid < 0) {
      throw StateError('Invalid incoming call payload');
    }
    final peerId = callerId.isNotEmpty
        ? callerId
        : (receiverId.isNotEmpty && receiverId != selfUserId
              ? receiverId
              : '');
    if (peerId.isEmpty) {
      throw StateError('Invalid caller id');
    }
    return VoiceCallSession(
      callId: callId.isNotEmpty ? callId : channelName,
      channelName: channelName,
      token: token,
      localUid: uid,
      agoraAppId: appIdRaw,
      peerName: name.isEmpty ? 'Incoming call' : name,
      peerUserId: peerId,
      selfUserId: selfUserId,
      isIncoming: true,
      conversationId: conversationId.isNotEmpty ? conversationId : null,
      outgoingCalleeRingingHint: false,
    );
  }

  Future<VoiceCallSession> createAndInviteAudioSession({
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
    final auth = Get.find<AuthRepository>();
    final selfId = (auth.userId ?? '').trim();
    if (selfId.isEmpty) {
      throw StateError('Not signed in');
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
    final callId = '${body['callId'] ?? ''}'.trim();
    final appIdRaw = '${body['appId'] ?? ''}'.trim();
    if (token.isEmpty || channelName.isEmpty || uid < 0) {
      throw StateError(
        'Call invite returned invalid session details. Got keys: ${body.keys.join(', ')}',
      );
    }
    final calleeOnline = body['calleeSocketOnline'] == true ||
        '${body['calleeSocketOnline'] ?? ''}'.trim().toLowerCase() == 'true';
    return VoiceCallSession(
      callId: callId.isNotEmpty ? callId : channelName,
      channelName: channelName,
      token: token,
      localUid: uid,
      agoraAppId: appIdRaw,
      peerName: peerName.trim().isEmpty ? 'Contact' : peerName.trim(),
      peerUserId: normalizedPeer,
      selfUserId: selfId,
      isIncoming: false,
      conversationId: conversationId,
      outgoingCalleeRingingHint: calleeOnline,
    );
  }

  Future<void> acceptCall(String callId) async {
    if (!Get.isRegistered<Dio>()) return;
    final dio = Get.find<Dio>();
    await dio.post(ApiEndpoints.voiceCallAccept, data: {'callId': callId});
  }

  Future<void> rejectCall(String callId) async {
    if (!Get.isRegistered<Dio>()) return;
    final dio = Get.find<Dio>();
    try {
      await dio.post(ApiEndpoints.voiceCallReject, data: {'callId': callId});
    } catch (_) {
      /* non-fatal */
    }
  }

  Future<void> endCall(String callId, {String reason = 'ended'}) async {
    if (!Get.isRegistered<Dio>()) return;
    final dio = Get.find<Dio>();
    try {
      await dio.post(
        ApiEndpoints.voiceCallEnd,
        data: {'callId': callId, 'reason': reason},
      );
    } catch (_) {
      /* non-fatal */
    }
  }

  String _normalizeId(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    final cleaned = v.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
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

  @override
  void onClose() {
    unawaited(_callEvents.close());
    super.onClose();
  }
}
