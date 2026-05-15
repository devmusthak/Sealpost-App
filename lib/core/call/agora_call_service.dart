import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
    required this.callerId,
    required this.receiverId,
    required this.isIncoming,
    this.conversationId,
    this.outgoingCalleeRingingHint = false,
    this.incomingAcceptAlreadyPosted = false,
    this.callType = 'audio',
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
  /// Server caller id (outgoing: same as [selfUserId]).
  final String callerId;
  /// Server callee id (outgoing: same as [peerUserId] when calling a peer).
  final String receiverId;
  final bool isIncoming;
  final String? conversationId;

  /// Outgoing: server says callee had an active socket — show "Ringing…" immediately (avoids missing socket race).
  final bool outgoingCalleeRingingHint;

  /// True when POST /call/accept was already sent (e.g. CallKit accept hydration) so the call screen must not repeat it.
  final bool incomingAcceptAlreadyPosted;

  /// `audio` (default) or `video`.
  final String callType;

  bool get isVideo => callType.trim().toLowerCase() == 'video';

  /// Agora tokens are bound to a specific UID; `0` is only valid when the server issued uid 0.
  bool get hasRtcCredentials =>
      channelName.trim().isNotEmpty &&
      (token ?? '').trim().isNotEmpty &&
      localUid > 0;

  String get effectiveAppId =>
      agoraAppId.trim().isNotEmpty ? agoraAppId.trim() : AgoraCallConfig.appId;

  /// Placeholder while POST /call/agora-invite is in flight (UI shows immediately).
  factory VoiceCallSession.outgoingConnecting({
    required String peerId,
    required String peerName,
    required String conversationId,
    required String selfUserId,
    String callType = 'video',
  }) {
    return VoiceCallSession(
      callId: '',
      channelName: '',
      token: '',
      localUid: 0,
      agoraAppId: '',
      peerName: peerName.trim().isEmpty ? 'Contact' : peerName.trim(),
      peerUserId: peerId,
      selfUserId: selfUserId,
      callerId: selfUserId,
      receiverId: peerId,
      isIncoming: false,
      conversationId: conversationId,
      callType: callType,
    );
  }

  VoiceCallSession copyWith({
    String? callId,
    String? channelName,
    String? token,
    int? localUid,
    String? agoraAppId,
    bool? outgoingCalleeRingingHint,
    bool? incomingAcceptAlreadyPosted,
  }) {
    return VoiceCallSession(
      callId: callId ?? this.callId,
      channelName: channelName ?? this.channelName,
      token: token ?? this.token,
      localUid: localUid ?? this.localUid,
      agoraAppId: agoraAppId ?? this.agoraAppId,
      peerName: peerName,
      peerUserId: peerUserId,
      selfUserId: selfUserId,
      callerId: callerId,
      receiverId: receiverId,
      isIncoming: isIncoming,
      conversationId: conversationId,
      outgoingCalleeRingingHint:
          outgoingCalleeRingingHint ?? this.outgoingCalleeRingingHint,
      incomingAcceptAlreadyPosted:
          incomingAcceptAlreadyPosted ?? this.incomingAcceptAlreadyPosted,
      callType: callType,
    );
  }
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

  /// POST /call/accept and return callee token + uid (authoritative for incoming join).
  Future<VoiceCallSession?> refreshIncomingSessionFromAccept(
    VoiceCallSession partial,
  ) async {
    final callId = partial.callId.trim();
    if (callId.isEmpty) return null;
    final body = await postVoiceCallAcceptForHydration(callId);
    if (body == null || body.isEmpty) {
      return hydrateIncomingRtcSession(
        partial,
        selfUserId: partial.selfUserId,
      );
    }
    final merged = <String, dynamic>{
      'callId': callId,
      'callerId': partial.callerId,
      'receiverId': partial.receiverId,
      'callerName': partial.peerName,
      'callType': partial.callType,
      if (partial.conversationId != null) 'conversationId': partial.conversationId,
      'channelName': body['channelName'] ?? partial.channelName,
      'token': body['token'] ?? partial.token,
      'uid': body['uid'] ?? partial.localUid,
      'appId': body['appId'] ?? partial.agoraAppId,
    };
    try {
      return sessionFromInvitePayload(
        merged,
        selfUserId: partial.selfUserId,
        incomingAcceptAlreadyPosted: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fills missing Agora token/channel/uid via POST /call/accept (CallKit partial payloads).
  Future<VoiceCallSession?> hydrateIncomingRtcSession(
    VoiceCallSession partial, {
    required String selfUserId,
  }) async {
    if (partial.hasRtcCredentials) return partial;
    final callId = partial.callId.trim();
    if (callId.isEmpty) return null;
    final body = await postVoiceCallAcceptForHydration(callId);
    if (body == null || body.isEmpty) return null;
    final merged = Map<String, dynamic>.from(body);
    merged['callId'] = callId;
    merged['callerId'] ??= partial.callerId;
    merged['receiverId'] ??= partial.receiverId;
    merged['callerName'] ??= partial.peerName;
    merged['callType'] ??= partial.callType;
    try {
      return sessionFromInvitePayload(
        merged,
        selfUserId: selfUserId,
        incomingAcceptAlreadyPosted: true,
        allowIncompleteRtc: false,
      );
    } catch (_) {
      return null;
    }
  }

  VoiceCallSession sessionFromInvitePayload(
    Map<String, dynamic> payload, {
    required String selfUserId,
    bool incomingAcceptAlreadyPosted = false,
    bool allowIncompleteRtc = false,
  }) {
    final channelName = '${payload['channelName'] ?? ''}'.trim();
    final token =
        '${payload['token'] ?? payload['agoraToken'] ?? ''}'.trim();
    var uidRaw = '${payload['uid'] ?? ''}'.trim();
    if (uidRaw.contains('.')) {
      final asDouble = double.tryParse(uidRaw);
      if (asDouble != null) {
        uidRaw = asDouble.toInt().toString();
      }
    }
    final uid = int.tryParse(uidRaw) ?? -1;
    final callId = '${payload['callId'] ?? ''}'.trim();
    final appIdRaw = '${payload['appId'] ?? ''}'.trim();
    final callerIdRaw =
        '${payload['callerId'] ?? payload['fromUserId'] ?? ''}'.trim();
    final receiverIdRaw = '${payload['receiverId'] ?? ''}'.trim();
    final name =
        '${payload['callerName'] ?? payload['fromName'] ?? 'Caller'}'.trim();
    final conversationId = '${payload['conversationId'] ?? ''}'.trim();
    final callTypeRaw =
        '${payload['callType'] ?? payload['mediaType'] ?? 'audio'}'.trim().toLowerCase();
    final callType = callTypeRaw == 'video' ? 'video' : 'audio';
    if (!allowIncompleteRtc && (channelName.isEmpty || token.isEmpty || uid < 0)) {
      throw StateError('Invalid incoming call payload');
    }
    if (allowIncompleteRtc && callId.isEmpty) {
      throw StateError('Invalid incoming call payload');
    }
    final resolvedChannel = channelName.isNotEmpty ? channelName : callId;
    final resolvedToken = token.isNotEmpty ? token : null;
    final resolvedUid = uid > 0 ? uid : 0;
    final peerId = callerIdRaw.isNotEmpty
        ? callerIdRaw
        : (receiverIdRaw.isNotEmpty && receiverIdRaw != selfUserId
              ? receiverIdRaw
              : '');
    if (peerId.isEmpty) {
      throw StateError('Invalid caller id');
    }
    final resolvedCaller =
        callerIdRaw.isNotEmpty ? callerIdRaw : peerId;
    final resolvedReceiver =
        receiverIdRaw.isNotEmpty ? receiverIdRaw : selfUserId;
    return VoiceCallSession(
      callId: callId.isNotEmpty ? callId : resolvedChannel,
      channelName: resolvedChannel,
      token: resolvedToken,
      localUid: resolvedUid,
      agoraAppId: appIdRaw,
      peerName: name.isEmpty
          ? (callType == 'video' ? 'Incoming video call' : 'Incoming call')
          : name,
      peerUserId: peerId,
      selfUserId: selfUserId,
      callerId: resolvedCaller,
      receiverId: resolvedReceiver,
      isIncoming: true,
      conversationId: conversationId.isNotEmpty ? conversationId : null,
      outgoingCalleeRingingHint: false,
      incomingAcceptAlreadyPosted: incomingAcceptAlreadyPosted,
      callType: callType,
    );
  }

  Future<VoiceCallSession> createAndInviteAudioSession({
    required String peerId,
    required String peerName,
    required String conversationId,
    required String callerName,
  }) =>
      createAndInviteSession(
        peerId: peerId,
        peerName: peerName,
        conversationId: conversationId,
        callerName: callerName,
        callType: 'audio',
      );

  Future<VoiceCallSession> createAndInviteVideoSession({
    required String peerId,
    required String peerName,
    required String conversationId,
    required String callerName,
  }) =>
      createAndInviteSession(
        peerId: peerId,
        peerName: peerName,
        conversationId: conversationId,
        callerName: callerName,
        callType: 'video',
      );

  Future<VoiceCallSession> createAndInviteSession({
    required String peerId,
    required String peerName,
    required String conversationId,
    required String callerName,
    required String callType,
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
        'callType': callType.trim().toLowerCase() == 'video' ? 'video' : 'audio',
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
      callerId: selfId,
      receiverId: normalizedPeer,
      isIncoming: false,
      conversationId: conversationId,
      outgoingCalleeRingingHint: calleeOnline,
      incomingAcceptAlreadyPosted: false,
      callType: '${body['callType'] ?? callType}'.trim().toLowerCase() == 'video'
          ? 'video'
          : 'audio',
    );
  }

  /// POST /call/accept — used to hydrate a partial CallKit payload. Returns parsed JSON on 2xx, null otherwise.
  Future<Map<String, dynamic>?> postVoiceCallAcceptForHydration(String callId) async {
    if (!Get.isRegistered<Dio>()) return null;
    final id = callId.trim();
    if (id.isEmpty) return null;
    final dio = Get.find<Dio>();
    try {
      final res = await dio.post<dynamic>(
        ApiEndpoints.voiceCallAccept,
        data: {'callId': id},
      );
      if ((res.statusCode ?? 500) >= 400) return null;
      return _toMap(res.data);
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (kDebugMode) {
        debugPrint(
          '[callkit-ios] accept hydrate failed status=$code data=${e.response?.data}',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
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

  Future<void> endCall(
    String callId, {
    String reason = 'ended',
    int? durationSeconds,
  }) async {
    if (!Get.isRegistered<Dio>()) return;
    final dio = Get.find<Dio>();
    try {
      final data = <String, dynamic>{
        'callId': callId,
        'reason': reason,
      };
      if (durationSeconds != null && durationSeconds >= 0) {
        data['durationSeconds'] = durationSeconds;
      }
      await dio.post(
        ApiEndpoints.voiceCallEnd,
        data: data,
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
