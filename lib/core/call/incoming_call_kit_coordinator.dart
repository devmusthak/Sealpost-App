import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:get/get.dart';

import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../push/pending_voice_call.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/session/session_storage.dart';
import '../../screens/home/controller/home_controller.dart';
import 'agora_call_service.dart';
import 'call_ringtone_service.dart';
import 'incoming_call_payload.dart';
import 'voice_call_navigation.dart';

/// WhatsApp-style incoming call UI via [flutter_callkit_incoming] + Agora for media.
///
/// - Android: full-screen incoming UI, ringtone, Accept / Decline.
/// - iOS: CallKit; true background/killed requires **VoIP push** (see AppDelegate + PUSHKIT.md).
/// - FCM data push alone is not sufficient on iOS when the app is suspended; server must send VoIP.
class IncomingCallKitCoordinator {
  IncomingCallKitCoordinator._();

  static StreamSubscription<CallEvent?>? _eventSub;
  static bool _listenersAttached = false;
  static final Map<String, String> _callKitIdByCallId = <String, String>{};
  static final Set<String> _presentedCallIds = <String>{};
  static final Map<String, DateTime> _ignoredEndedCallIds = <String, DateTime>{};
  static final Set<String> _acceptHandledCallIds = <String>{};
  static bool _isCallKitAudioSessionActive = false;

  /// Latest CallKit audio session activation flag (iOS); do not treat as sole gate for Agora join.
  static bool get isCallKitAudioSessionActive => _isCallKitAudioSessionActive;
  static Future<void>? _voipSyncInFlight;
  static String? _lastVoipTokenSynced;
  static DateTime? _lastVoipSyncAt;
  static final Random _random = Random.secure();
  static const Duration _ignoredCallTtl = Duration(minutes: 10);
  static const Duration _incomingCallMaxAge = Duration(seconds: 45);

  /// Call after [WidgetsFlutterBinding] + plugin registration (e.g. from [PushNotificationService]).
  static void attachListeners() {
    if (_listenersAttached) return;
    _listenersAttached = true;
    _eventSub = FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
    unawaited(syncVoipTokenToServer());
  }

  static void disposeListeners() {
    _eventSub?.cancel();
    _eventSub = null;
    _listenersAttached = false;
  }

  static Future<void> presentFromFcmData(Map<String, String> data) async {
    if (!IncomingCallPayload.isIncomingAudioCall(data)) return;
    final merged = IncomingCallPayload.normalizeInviteStrings(data);
    final callId = (merged['callId'] ?? '').trim();
    if (callId.isEmpty) return;
    _cleanupIgnoredEndedCallIds();
    if (_ignoredEndedCallIds.containsKey(callId)) return;
    if (_isLikelyStaleCallId(callId)) {
      _markCallAsEndedLocally(callId);
      return;
    }
    final status = await _fetchCallStatus(callId);
    if (status != null && status != 'ringing') {
      _markCallAsEndedLocally(callId);
      return;
    }
    if (_presentedCallIds.contains(callId)) return;
    if (await _hasActiveCallForCallId(callId)) {
      _presentedCallIds.add(callId);
      return;
    }
    final callKitId = _callKitIdByCallId.putIfAbsent(
      callId,
      () => _isUuid(callId) ? callId : _newUuidV4(),
    );

    if (Get.isRegistered<AgoraCallService>()) {
      final active = Get.find<AgoraCallService>().activeUiCallId;
      if (active != null && active == callId) return;
    }

    final timeoutSec = int.tryParse((merged['timeoutSeconds'] ?? '').trim()) ?? 45;
    final durationMs = (timeoutSec * 1000).clamp(15000, 120000);
    final name =
        (merged['callerName'] ?? merged['fromName'] ?? 'Incoming call').trim();
    final handle =
        (merged['callerId'] ?? merged['fromUserId'] ?? merged['handle'] ?? '')
            .trim();
    final avatar = (merged['callerAvatar'] ?? merged['avatar'] ?? '').trim();
    final extra = Map<String, dynamic>.from(
      merged.map((k, v) => MapEntry(k, v)),
    );
    extra['callId'] = callId;
    extra['callKitId'] = callKitId;

    final params = CallKitParams(
      id: callKitId,
      nameCaller: name.isEmpty ? 'Incoming call' : name,
      appName: 'Sealpost',
      avatar: avatar.isEmpty ? null : avatar,
      handle: handle,
      type: 0,
      duration: durationMs,
      textAccept: 'Accept',
      textDecline: 'Decline',
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      extra: extra,
      android: AndroidParams(
        isCustomNotification: false,
        isShowFullLockedScreen: false,
        isImportant: true,
        ringtonePath: 'system_ringtone_default',
        incomingCallNotificationChannelName: 'Sealpost incoming calls',
        missedCallNotificationChannelName: 'Sealpost missed calls',
        backgroundColor: '#1a1a1a',
        actionColor: '#25D366',
        textColor: '#ffffff',
        isShowLogo: true,
      ),
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: false,
        ringtonePath: 'system_ringtone_default',
        audioSessionActive: true,
        audioSessionMode: 'default',
      ),
    );

    try {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      _presentedCallIds.add(callId);
    } catch (e, st) {
      assert(() {
        FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
        return true;
      }());
    }
  }

  static Future<void> dismissForCallId(String callId) async {
    final id = callId.trim();
    if (id.isEmpty) {
      try {
        await FlutterCallkitIncoming.endAllCalls();
      } catch (_) {}
      _presentedCallIds.clear();
      _callKitIdByCallId.clear();
      _ignoredEndedCallIds.clear();
      return;
    }
    final mappedId = _callKitIdByCallId[id]?.trim();
    if (mappedId != null && mappedId.isNotEmpty) {
      try {
        await FlutterCallkitIncoming.endCall(mappedId);
      } catch (_) {}
      _callKitIdByCallId.remove(id);
      _presentedCallIds.remove(id);
      _markCallAsEndedLocally(id);
      return;
    }
    if (!_isUuid(id)) {
      await _dismissByServerCallId(id);
      _callKitIdByCallId.remove(id);
      _presentedCallIds.remove(id);
      _markCallAsEndedLocally(id);
      return;
    }
    // iOS plugin force-unwraps UUID(uuidString: id)! in native endCall.
    // If backend callId is not a UUID, calling endCall(id) crashes.
    if (Platform.isIOS && !_isUuid(id)) {
      try {
        await FlutterCallkitIncoming.endAllCalls();
      } catch (_) {}
      return;
    }
    try {
      await FlutterCallkitIncoming.endCall(id);
    } catch (_) {}
    _callKitIdByCallId.remove(id);
    _presentedCallIds.remove(id);
    _markCallAsEndedLocally(id);
  }

  static void _clearCallTracking(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return;
    _callKitIdByCallId.remove(id);
    _presentedCallIds.remove(id);
    _acceptHandledCallIds.remove(id);
    _markCallAsEndedLocally(id);
  }

  /// When socket opens in-app call UI, dismiss native CallKit for same [callId].
  static Future<void> dismissNativeIfSameCall(String callId) async {
    await dismissForCallId(callId);
  }

  static Future<void> requestAndroidCallPermissions() async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        'title': 'Notifications',
        'rationaleMessagePermission':
            'Incoming calls need notification permission to ring and show Accept / Decline.',
        'postNotificationMessageRequired':
            'Please allow notifications so Sealpost can show incoming calls.',
      });
    } catch (_) {}
    try {
      await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (_) {}
  }

  /// iOS PushKit VoIP token -> backend (used by server for native CallKit push path).
  static Future<void> syncVoipTokenToServer() async {
    if (!Platform.isIOS) return;
    if (_voipSyncInFlight != null) {
      await _voipSyncInFlight;
      return;
    }
    final completer = Completer<void>();
    _voipSyncInFlight = completer.future;
    try {
      if (!Get.isRegistered<AuthRepository>()) return;
      final auth = Get.find<AuthRepository>();
      final token = auth.accessToken;
      if (token == null || token.isEmpty) return;
      final voipToken = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      final normalized = (voipToken ?? '').trim();
      if (kDebugMode) {
        debugPrint('[voip-ios] token: $normalized');
      }
      if (normalized.isEmpty) return;
      final now = DateTime.now();
      final recentlySyncedSameToken =
          _lastVoipTokenSynced == normalized &&
          _lastVoipSyncAt != null &&
          now.difference(_lastVoipSyncAt!) < const Duration(minutes: 2);
      if (recentlySyncedSameToken) return;
      await auth.registerVoipToken(normalized);
      _lastVoipTokenSynced = normalized;
      _lastVoipSyncAt = now;
      if (kDebugMode) {
        debugPrint('[voip-ios] token synced to backend');
      }
    } catch (_) {
    } finally {
      completer.complete();
      _voipSyncInFlight = null;
    }
  }

  static Future<void> syncAcceptedCallFromNativeIfNeeded() async {
    if (!Get.isRegistered<AuthRepository>()) return;
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) return;
    if (!Get.isRegistered<HomeController>()) return;
    if (!Get.isRegistered<AgoraCallService>()) return;

    try {
      final raw = await FlutterCallkitIncoming.activeCalls();
      if (raw is! List || raw.isEmpty) return;
      final first = raw.first;
      if (first is! Map) return;
      final accepted = first['isAccepted'] == true;
      if (!accepted) return;
      Map<String, String>? invite =
          _inviteStringsFromDynamicExtra(first['extra'] ?? first);
      final callIdFromNative = _callIdFromBody(first) ?? '';
      if (invite == null && callIdFromNative.isNotEmpty) {
        if (kDebugMode && Platform.isIOS) {
          debugPrint(
            '[callkit-ios] syncAccepted: extra incomplete, rebuilding callId=$callIdFromNative',
          );
        }
        invite = _minimalInviteForCallId(callIdFromNative);
        await _hydrateInviteFromAcceptIfNeeded(invite, callIdFromNative);
      } else if (invite != null && !_inviteRtcReadyForSession(invite)) {
        final cid = (invite['callId'] ?? callIdFromNative).trim();
        if (cid.isNotEmpty) {
          await _hydrateInviteFromAcceptIfNeeded(invite, cid);
        }
      }
      if (invite == null || !_inviteRtcReadyForSession(invite)) {
        if (kDebugMode && Platform.isIOS) {
          debugPrint(
            '[callkit-ios] syncAccepted: skip invite incomplete after hydrate',
          );
        }
        return;
      }
      invite['_autoAccept'] = '1';
      invite['_acceptedFromCallkit'] = '1';
      if (!Get.isRegistered<PendingVoiceCall>()) return;
      Get.find<PendingVoiceCall>().applyFromData(invite);
      openPendingIncomingVoiceCallIfReady();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[callkit] sync accepted: $e');
      }
    }
  }

  /// iOS only: CallKit should activate audio session before Agora joins.
  /// Returns true when active, false on bounded wait timeout.
  static Future<bool> waitForAudioSessionActivation({
    Duration retryDelay = const Duration(milliseconds: 300),
    int maxRetries = 8,
  }) async {
    if (!Platform.isIOS) return true;
    if (_isCallKitAudioSessionActive) return true;
    for (var i = 0; i < maxRetries; i++) {
      await Future<void>.delayed(retryDelay);
      if (_isCallKitAudioSessionActive) return true;
    }
    return false;
  }

  static void _mergeAcceptBodyIntoInviteStrings(
    Map<String, String> invite,
    Map<String, dynamic> body,
  ) {
    for (final e in body.entries) {
      if (e.value == null) continue;
      final s = '${e.value}'.trim();
      if (s.isNotEmpty) {
        invite[e.key] = s;
      }
    }
    final merged = IncomingCallPayload.normalizeInviteStrings(
      Map<String, String>.from(invite),
    );
    invite
      ..clear()
      ..addAll(merged);
  }

  static bool _inviteHasCoreRtcFields(Map<String, String> invite) {
    final ch = (invite['channelName'] ?? '').trim();
    final tok = (invite['token'] ?? '').trim();
    final uid = int.tryParse((invite['uid'] ?? '').trim()) ?? -1;
    return ch.isNotEmpty && tok.isNotEmpty && uid >= 0;
  }

  static bool _inviteRtcReadyForSession(Map<String, String> invite) {
    if (!_inviteHasCoreRtcFields(invite)) return false;
    if (!Get.isRegistered<AuthRepository>()) return false;
    final selfId = (Get.find<AuthRepository>().userId ?? '').trim();
    final callerId = (invite['callerId'] ?? invite['fromUserId'] ?? '').trim();
    final receiverId = (invite['receiverId'] ?? '').trim();
    final peerId = callerId.isNotEmpty
        ? callerId
        : (receiverId.isNotEmpty && receiverId != selfId ? receiverId : '');
    return peerId.isNotEmpty;
  }

  static Map<String, String> _minimalInviteForCallId(String callId) {
    return IncomingCallPayload.normalizeInviteStrings({
      'callId': callId.trim(),
      'type': 'incoming_voice_call',
      'notificationType': 'incoming_call',
      'callType': 'audio',
    });
  }

  static Future<void> _hydrateInviteFromAcceptIfNeeded(
    Map<String, String> invite,
    String callId,
  ) async {
    if (_inviteRtcReadyForSession(invite)) return;
    if (!Get.isRegistered<AgoraCallService>()) return;
    if (callId.isEmpty) return;
    if (kDebugMode && Platform.isIOS) {
      debugPrint(
        '[callkit-ios] hydrating invite via POST /call/accept callId=$callId',
      );
    }
    final body =
        await Get.find<AgoraCallService>().postVoiceCallAcceptForHydration(callId);
    if (body == null || body.isEmpty) {
      if (Get.isRegistered<PendingVoiceCall>()) {
        final prev = Get.find<PendingVoiceCall>().payload;
        if (prev != null && (prev['callId'] ?? '').trim() == callId) {
          if (kDebugMode && Platform.isIOS) {
            debugPrint(
              '[callkit-ios] hydrate: merging pending payload for callId=$callId',
            );
          }
          for (final e in prev.entries) {
            if (e.value.trim().isEmpty) continue;
            if ((invite[e.key] ?? '').trim().isEmpty) {
              invite[e.key] = e.value;
            }
          }
          final merged = IncomingCallPayload.normalizeInviteStrings(
            Map<String, String>.from(invite),
          );
          invite
            ..clear()
            ..addAll(merged);
        }
      }
      return;
    }
    _mergeAcceptBodyIntoInviteStrings(invite, body);
    invite['_incomingAcceptAlreadyPosted'] = '1';
  }

  static Map<String, String>? _inviteStringsFromDynamicExtra(dynamic extra) {
    Map<String, String> out = {};
    if (extra is String && extra.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(extra);
        if (decoded is Map) {
          extra = decoded;
        }
      } catch (_) {
        return null;
      }
    }
    if (extra is Map) {
      for (final e in extra.entries) {
        out['${e.key}'] = '${e.value ?? ''}';
      }
    } else {
      return null;
    }
    out = IncomingCallPayload.normalizeInviteStrings(out);
    if ((out['callId'] ?? '').trim().isEmpty) return null;
    if ((out['channelName'] ?? '').trim().isEmpty) return null;
    if ((out['token'] ?? '').trim().isEmpty) return null;
    final uid = int.tryParse((out['uid'] ?? '').trim()) ?? -1;
    if (uid < 0) return null;
    return out;
  }

  static void _onCallKitEvent(CallEvent? event) {
    if (event == null) return;
    switch (event.event) {
      case Event.actionCallIncoming:
        // User tapped the CallKit incoming banner/screen; open app call UI promptly.
        unawaited(_handleIncoming(event.body));
        break;
      case Event.actionDidUpdateDevicePushTokenVoip:
        unawaited(syncVoipTokenToServer());
        break;
      case Event.actionCallToggleAudioSession:
        final body = event.body;
        bool isActivate = false;
        if (body is Map) {
          final raw = '${body['isActivate'] ?? ''}'.trim().toLowerCase();
          isActivate = raw == 'true' || raw == '1';
        }
        _isCallKitAudioSessionActive = isActivate;
        if (kDebugMode && Platform.isIOS) {
          debugPrint('[callkit-ios] audio session activate=$isActivate');
        }
        break;
      case Event.actionCallAccept:
        unawaited(_handleAccept(event.body));
        break;
      case Event.actionCallDecline:
        unawaited(_handleDecline(event.body));
        break;
      case Event.actionCallTimeout:
        unawaited(_handleTimeout(event.body));
        break;
      case Event.actionCallEnded:
        unawaited(_handleEnded(event.body));
        break;
      default:
        break;
    }
  }

  static Future<void> _handleIncoming(dynamic body) async {
    final invite = _parseEventToInvite(body);
    if (invite == null) return;
    if (!Get.isRegistered<PendingVoiceCall>()) return;
    Get.find<PendingVoiceCall>().applyFromData(invite);
    openPendingIncomingVoiceCallIfReady();
  }

  static Future<void> _handleAccept(dynamic body) async {
    await CallRingtoneService.stop();
    if (kDebugMode && Platform.isIOS) {
      debugPrint('[callkit-ios] Event.actionCallAccept body=$body');
    }
    Map<String, String>? invite = _parseEventToInvite(body);
    final callIdRaw =
        (invite?['callId'] ?? _callIdFromBody(body) ?? '').trim();
    if (invite == null && callIdRaw.isNotEmpty) {
      if (kDebugMode && Platform.isIOS) {
        debugPrint(
          '[callkit-ios] accept: using minimal invite (parse returned null) callId=$callIdRaw',
        );
      }
      invite = _minimalInviteForCallId(callIdRaw);
    }
    if (invite == null) {
      if (kDebugMode && Platform.isIOS) {
        debugPrint('[callkit-ios] accept: abort no callId / payload');
      }
      return;
    }
    final callId = (invite['callId'] ?? callIdRaw).trim();
    if (callId.isNotEmpty && _acceptHandledCallIds.contains(callId)) {
      if (kDebugMode && Platform.isIOS) {
        debugPrint('[callkit-ios] accept duplicate suppressed callId=$callId');
      }
      return;
    }

    await _hydrateInviteFromAcceptIfNeeded(invite, callId);
    if (!_inviteRtcReadyForSession(invite)) {
      if (kDebugMode && Platform.isIOS) {
        debugPrint(
          '[callkit-ios] accept: still incomplete after hydrate callId=$callId '
          'channel=${(invite['channelName'] ?? '').isNotEmpty} token=${(invite['token'] ?? '').isNotEmpty} '
          'uid=${invite['uid']}',
        );
      }
      return;
    }

    if (callId.isNotEmpty) {
      _acceptHandledCallIds.add(callId);
    }
    if (kDebugMode && Platform.isIOS) {
      debugPrint('[callkit-ios] accept stored pending callId=$callId');
    }
    invite['_autoAccept'] = '1';
    invite['_acceptedFromCallkit'] = '1';
    if (!Get.isRegistered<PendingVoiceCall>()) {
      if (kDebugMode && Platform.isIOS) {
        debugPrint('[callkit-ios] accept: PendingVoiceCall not registered');
      }
      return;
    }
    Get.find<PendingVoiceCall>().applyFromData(invite);
    if (kDebugMode && Platform.isIOS) {
      final p = Get.find<PendingVoiceCall>();
      debugPrint(
        '[callkit-ios] pending applied autoAccept=${p.autoAccept} '
        'acceptedFromCallkit=${p.acceptedFromCallkit} '
        'incomingAcceptAlreadyPosted=${p.incomingAcceptAlreadyPosted}',
      );
    }
    openPendingIncomingVoiceCallIfReady();
  }

  static Future<void> _handleDecline(dynamic body) async {
    await CallRingtoneService.stop();
    final invite = _parseEventToInvite(body);
    final callId = (invite?['callId'] ?? _callIdFromBody(body) ?? '').trim();
    if (callId.isNotEmpty) {
      _acceptHandledCallIds.remove(callId);
    }
    await dismissForCallId(callId);
    await _rejectViaRest(callId);
  }

  static Future<void> _handleTimeout(dynamic body) async {
    await CallRingtoneService.stop();
    final callId = (_callIdFromBody(body) ?? '').trim();
    if (callId.isNotEmpty) {
      _acceptHandledCallIds.remove(callId);
    }
    await dismissForCallId(callId);
    await _endViaRest(callId, reason: 'missed');
  }

  static Future<void> _handleEnded(dynamic body) async {
    await CallRingtoneService.stop();
    final callId = (_callIdFromBody(body) ?? '').trim();
    if (callId.isNotEmpty) {
      _acceptHandledCallIds.remove(callId);
    }
    // iOS ACTION_CALL_ENDED is emitted after native CallKit already ended the call.
    // Calling endCall() again can trigger CallKit request transaction errors.
    _clearCallTracking(callId);
    await _endViaRest(callId, reason: 'ended');
  }

  static void _markCallAsEndedLocally(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return;
    _ignoredEndedCallIds[id] = DateTime.now();
    _cleanupIgnoredEndedCallIds();
  }

  static void _cleanupIgnoredEndedCallIds() {
    final now = DateTime.now();
    _ignoredEndedCallIds.removeWhere(
      (_, at) => now.difference(at) > _ignoredCallTtl,
    );
  }

  static bool _isLikelyStaleCallId(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return false;
    final parts = id.split('_');
    if (parts.length < 3) return false;
    final maybeEpochMs = int.tryParse(parts[parts.length - 2]);
    if (maybeEpochMs == null || maybeEpochMs <= 0) return false;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(maybeEpochMs);
    final age = DateTime.now().difference(createdAt);
    return age > _incomingCallMaxAge;
  }

  static Future<String?> _fetchCallStatus(String callId) async {
    try {
      final storage = await SessionStorage.create();
      final session = await storage.load();
      if (session == null || session.token.trim().isEmpty) return null;
      final dio = createDio();
      final res = await dio.get<dynamic>(
        ApiEndpoints.voiceCallStatus,
        queryParameters: {'callId': callId},
        options: Options(
          headers: {'Authorization': 'Bearer ${session.token.trim()}'},
        ),
      );
      final raw = res.data;
      if (raw is Map && raw['callStatus'] != null) {
        return '${raw['callStatus']}'.trim().toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  static Map<String, String>? _parseEventToInvite(dynamic body) {
    if (body is! Map) return null;
    final map = Map<String, dynamic>.from(body);
    dynamic extra = map['extra'];
    if (extra is String && extra.trim().isNotEmpty) {
      try {
        final d = jsonDecode(extra);
        if (d is Map) extra = d;
      } catch (_) {}
    }
    Map<String, String> strings;
    if (extra is Map) {
      strings = extra.map((k, v) => MapEntry('$k', '${v ?? ''}'));
    } else {
      strings = map.map((k, v) => MapEntry(k, '${v ?? ''}'));
    }
    // `map['id']` is native CallKit UUID on iOS; backend APIs need original callId.
    // Prefer extra.callId and only fallback to map.id when callId is missing.
    final callIdFromExtra = (strings['callId'] ?? '').trim();
    final nativeId = '${map['id'] ?? ''}'.trim();
    if (callIdFromExtra.isEmpty && nativeId.isNotEmpty) {
      strings['callId'] = nativeId;
    }
    return IncomingCallPayload.normalizeInviteStrings(strings);
  }

  static String? _callIdFromBody(dynamic body) {
    if (body is! Map) return null;
    final m = Map<String, dynamic>.from(body);
    dynamic ex = m['extra'];
    if (ex is String) {
      try {
        final d = jsonDecode(ex);
        if (d is Map) ex = d;
      } catch (_) {}
    }
    if (ex is Map) {
      final extraCallId = '${ex['callId'] ?? ex['id'] ?? ''}'.trim();
      if (extraCallId.isNotEmpty) return extraCallId;
    }
    final id = '${m['id'] ?? ''}'.trim();
    if (id.isNotEmpty) return id;
    return null;
  }

  static Future<void> _dismissByServerCallId(String callId) async {
    try {
      final raw = await FlutterCallkitIncoming.activeCalls();
      if (raw is! List || raw.isEmpty) {
        await FlutterCallkitIncoming.endAllCalls();
        return;
      }
      for (final item in raw) {
        if (item is! Map) continue;
        final row = Map<String, dynamic>.from(item);
        final id = '${row['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        dynamic ex = row['extra'];
        if (ex is String && ex.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(ex);
            if (decoded is Map) ex = decoded;
          } catch (_) {}
        }
        String extraCallId = '';
        if (ex is Map) {
          extraCallId = '${ex['callId'] ?? ex['id'] ?? ''}'.trim();
        }
        if (extraCallId == callId) {
          if (_isUuid(id)) {
            await FlutterCallkitIncoming.endCall(id);
          } else {
            await FlutterCallkitIncoming.endAllCalls();
          }
          return;
        }
      }
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }

  static Future<bool> _hasActiveCallForCallId(String callId) async {
    try {
      final raw = await FlutterCallkitIncoming.activeCalls();
      if (raw is! List || raw.isEmpty) return false;
      for (final item in raw) {
        if (item is! Map) continue;
        final row = Map<String, dynamic>.from(item);
        dynamic ex = row['extra'];
        if (ex is String && ex.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(ex);
            if (decoded is Map) ex = decoded;
          } catch (_) {}
        }
        if (ex is Map) {
          final activeCallId = '${ex['callId'] ?? ex['id'] ?? ''}'.trim();
          if (activeCallId == callId) return true;
        }
        final mapped = _callKitIdByCallId[callId];
        if (mapped != null && '${row['id'] ?? ''}'.trim() == mapped) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static bool _isUuid(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{12}$',
    );
    return uuidPattern.hasMatch(v);
  }

  static String _newUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hexByte(int b) => b.toRadixString(16).padLeft(2, '0');
    final hex = bytes.map(hexByte).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  static Future<void> _rejectViaRest(String callId) async {
    if (callId.isEmpty) return;
    try {
      final storage = await SessionStorage.create();
      final session = await storage.load();
      if (session == null || session.token.trim().isEmpty) return;
      final dio = createDio();
      await dio.post<dynamic>(
        ApiEndpoints.voiceCallReject,
        data: {'callId': callId},
        options: Options(
          headers: {'Authorization': 'Bearer ${session.token.trim()}'},
        ),
      );
    } catch (_) {}
  }

  static Future<void> _endViaRest(String callId, {required String reason}) async {
    if (callId.isEmpty) return;
    try {
      final storage = await SessionStorage.create();
      final session = await storage.load();
      if (session == null || session.token.trim().isEmpty) return;
      final dio = createDio();
      await dio.post<dynamic>(
        ApiEndpoints.voiceCallEnd,
        data: {'callId': callId, 'reason': reason},
        options: Options(
          headers: {'Authorization': 'Bearer ${session.token.trim()}'},
        ),
      );
    } catch (_) {}
  }
}
