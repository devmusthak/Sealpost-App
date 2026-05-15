import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:get/get.dart';

import '../app_branding.dart';
import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../push/pending_voice_call.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/session/session_storage.dart';
import '../../screens/home/controller/home_controller.dart';
import 'agora_call_service.dart';
import 'incoming_call_payload.dart';
import 'outgoing_ringback_service.dart';
import 'voice_call_navigation.dart';

/// WhatsApp-style incoming call UI via [flutter_callkit_incoming] + Agora for media.
///
/// - Android: CallKit incoming UI + system ringtone; outgoing ringback is [OutgoingRingbackService].
/// - iOS: CallKit; true background/killed requires **VoIP push** (see AppDelegate + PUSHKIT.md).
/// - FCM data push alone is not sufficient on iOS when the app is suspended; server must send VoIP.
class IncomingCallKitCoordinator {
  IncomingCallKitCoordinator._();

  static StreamSubscription<CallEvent?>? _eventSub;
  static bool _listenersAttached = false;
  static const MethodChannel _androidCallKitContentChannel =
      MethodChannel('com.sealpost.mail/call_kit_incoming');
  static bool _androidCallKitContentHandlerAttached = false;
  static Map<String, String>? _queuedAndroidCallKitContentTap;
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

  /// Register before [runApp] so cold-start notification taps are not dropped.
  static void registerAndroidCallKitContentChannelEarly() {
    if (!Platform.isAndroid) return;
    _attachAndroidCallKitContentChannelHandler();
  }

  /// Call after [PendingVoiceCall] is registered (e.g. end of app bootstrap).
  static void notifyAndroidCallKitDependenciesReady() {
    if (!Platform.isAndroid) return;
    final q = _queuedAndroidCallKitContentTap;
    if (q == null) return;
    _queuedAndroidCallKitContentTap = null;
    handleAndroidCallKitNotificationContent(q);
  }

  /// Call after [WidgetsFlutterBinding] + plugin registration (e.g. from [PushNotificationService]).
  static void attachListeners() {
    if (_listenersAttached) return;
    _listenersAttached = true;
    _attachAndroidCallKitContentChannelHandler();
    _eventSub = FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
    unawaited(syncVoipTokenToServer());
  }

  static void _attachAndroidCallKitContentChannelHandler() {
    if (!Platform.isAndroid || _androidCallKitContentHandlerAttached) return;
    _androidCallKitContentHandlerAttached = true;
    _androidCallKitContentChannel.setMethodCallHandler((call) async {
      if (call.method != 'onCallKitNotificationContent') return;
      final args = call.arguments;
      if (args is! Map) return;
      final raw = <String, String>{};
      for (final e in args.entries) {
        raw['${e.key}'] = '${e.value}';
      }
      handleAndroidCallKitNotificationContent(raw);
    });
  }

  /// Android: [CallKitIncomingRouteActivity] forwards notification / full-screen tap payload.
  static void handleAndroidCallKitNotificationContent(Map<String, String> raw) {
    if (!Platform.isAndroid) return;
    final cidEarly = (raw['callId'] ?? '').trim();
    if (cidEarly.isNotEmpty && PendingVoiceCall.isAndroidCallTerminal(cidEarly)) {
      return;
    }
    if (!IncomingCallPayload.isIncomingCall(raw)) return;
    final normalized = IncomingCallPayload.normalizeInviteStrings(raw);
    if (!Get.isRegistered<PendingVoiceCall>()) {
      _queuedAndroidCallKitContentTap = Map<String, String>.from(normalized);
      return;
    }
    final p = Get.find<PendingVoiceCall>();
    p.applyFromData(normalized);
    if (!p.hasPending) return;
    final resolved = (p.payload!['callId'] ?? '').trim();
    if (resolved.isNotEmpty && PendingVoiceCall.isAndroidCallTerminal(resolved)) {
      return;
    }
    p.androidShowRingUi = true;
    openPendingIncomingVoiceCallIfReady();
  }

  static void disposeListeners() {
    _eventSub?.cancel();
    _eventSub = null;
    _listenersAttached = false;
    if (Platform.isAndroid && _androidCallKitContentHandlerAttached) {
      _androidCallKitContentChannel.setMethodCallHandler(null);
      _androidCallKitContentHandlerAttached = false;
    }
  }

  static Future<void> presentFromFcmData(Map<String, String> data) async {
    if (!IncomingCallPayload.isIncomingCall(data)) return;
    final merged = IncomingCallPayload.normalizeInviteStrings(data);
    final callId = (merged['callId'] ?? '').trim();
    if (callId.isEmpty) return;
    _cleanupIgnoredEndedCallIds();
    if (_ignoredEndedCallIds.containsKey(callId)) return;
    if (Platform.isAndroid && PendingVoiceCall.isAndroidCallTerminal(callId)) {
      return;
    }
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
    final isVideo = IncomingCallPayload.isIncomingVideoCall(merged);
    final name =
        (merged['callerName'] ?? merged['fromName'] ?? '').trim();
    final displayName = name.isEmpty
        ? (isVideo ? 'Incoming video call' : 'Incoming call')
        : name;
    final handle =
        (merged['callerId'] ?? merged['fromUserId'] ?? merged['handle'] ?? '')
            .trim();
    final avatar = (merged['callerAvatar'] ?? merged['avatar'] ?? '').trim();
    final extra = Map<String, dynamic>.from(
      merged.map((k, v) => MapEntry(k, v)),
    );
    extra['callId'] = callId;
    extra['callKitId'] = callKitId;
    extra['callType'] = isVideo ? 'video' : 'audio';

    final params = CallKitParams(
      id: callKitId,
      nameCaller: displayName,
      appName: AppBranding.displayName,
      avatar: avatar.isEmpty ? null : avatar,
      // Android: plugin uses [handle] as the line under the name — show app name, not user id.
      handle: Platform.isAndroid
          ? (isVideo ? 'Incoming video call' : AppBranding.displayName)
          : handle,
      type: isVideo ? 1 : 0,
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
        isShowCallID: false,
        isShowFullLockedScreen: false,
        isImportant: true,
        ringtonePath: 'system_ringtone_default',
        incomingCallNotificationChannelName: '${AppBranding.displayName} incoming calls',
        missedCallNotificationChannelName: '${AppBranding.displayName} missed calls',
        backgroundColor: '#1a1a1a',
        actionColor: '#25D366',
        textColor: '#ffffff',
        isShowLogo: true,
      ),
      ios: IOSParams(
        handleType: 'generic',
        supportsVideo: isVideo,
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

  /// Native CallKit / Android calling UI for the **caller** while [AgoraAudioCallScreen] is shown.
  /// Does not replace the Flutter ring screen — both run together until the call connects or ends.
  static Future<void> startOutgoingCallkitIfSupported({
    required VoiceCallSession session,
  }) async {
    if (session.isIncoming) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;
    final callId = session.callId.trim();
    if (callId.isEmpty) return;

    attachListeners();

    final callKitId = _callKitIdByCallId.putIfAbsent(
      callId,
      () => _isUuid(callId) ? callId : _newUuidV4(),
    );

    final isVideo = session.isVideo;
    final calleeName =
        session.peerName.trim().isEmpty ? 'Contact' : session.peerName.trim();

    final extra = <String, dynamic>{
      'callId': callId,
      'callKitId': callKitId,
      '_outgoingSealpostLocal': '1',
      'channelName': session.channelName,
      'token': session.token ?? '',
      'uid': '${session.localUid}',
      'appId': session.effectiveAppId,
      'callerId': session.callerId,
      'receiverId': session.receiverId,
      'peerUserId': session.peerUserId,
      'conversationId': session.conversationId ?? '',
      'callType': isVideo ? 'video' : 'audio',
      'type': isVideo ? 'outgoing_video_call' : 'outgoing_voice_call',
      'notificationType': 'outgoing_call',
    };

    final params = CallKitParams(
      id: callKitId,
      nameCaller: calleeName,
      appName: AppBranding.displayName,
      // Android: second line under callee name — app label (ids stay in [extra]).
      handle: isVideo ? 'Video call' : AppBranding.displayName,
      type: isVideo ? 1 : 0,
      duration: 120000,
      callingNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Calling…',
        callbackText: 'Cancel',
      ),
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      extra: extra,
      android: const AndroidParams(
        isCustomNotification: true,
        isShowCallID: false,
        isShowFullLockedScreen: false,
        isImportant: true,
        ringtonePath: 'system_ringtone_default',
        incomingCallNotificationChannelName: '${AppBranding.displayName} incoming calls',
        missedCallNotificationChannelName: '${AppBranding.displayName} missed calls',
        backgroundColor: '#1a1a1a',
        actionColor: '#E11D48',
        textColor: '#ffffff',
        isShowLogo: true,
      ),
      ios: IOSParams(
        handleType: 'generic',
        supportsVideo: isVideo,
        ringtonePath: 'system_ringtone_default',
        audioSessionActive: true,
        audioSessionMode: 'default',
      ),
    );

    try {
      await FlutterCallkitIncoming.startCall(params);
      _presentedCallIds.add(callId);
      if (kDebugMode) {
        debugPrint(
          '[callkit] startOutgoing callId=$callId nativeId=$callKitId callee=$calleeName',
        );
      }
    } catch (e, st) {
      assert(() {
        FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
        return true;
      }());
    }
  }

  /// Updates native CallKit / Telecom state when media path is up (outgoing or mirrored UI).
  static Future<void> notifyOutgoingCallConnectedIfManaged(String callId) async {
    final id = callId.trim();
    if (id.isEmpty) return;
    final mapped = _callKitIdByCallId[id]?.trim();
    if (mapped == null || mapped.isEmpty) return;
    try {
      await FlutterCallkitIncoming.setCallConnected(mapped);
      if (kDebugMode) {
        debugPrint('[callkit] setCallConnected callId=$id nativeId=$mapped');
      }
    } catch (_) {}
  }

  static bool _isOutgoingLocalCallkit(dynamic body) {
    if (body is! Map) return false;
    final m = Map<String, dynamic>.from(body);
    dynamic ex = m['extra'];
    if (ex is String && ex.trim().isNotEmpty) {
      try {
        final d = jsonDecode(ex);
        if (d is Map) ex = d;
      } catch (_) {}
    }
    if (ex is Map && '${ex['_outgoingSealpostLocal'] ?? ''}' == '1') {
      return true;
    }
    return false;
  }

  static void _emitCallEndedToActiveUiIfNeeded(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return;
    if (!Get.isRegistered<AgoraCallService>()) return;
    final svc = Get.find<AgoraCallService>();
    if (svc.activeUiCallId != id) return;
    svc.emitCallSignal('call_ended', <String, dynamic>{
      'callId': id,
      'reason': 'callkit_native',
    });
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
            'Please allow notifications so ${AppBranding.displayName} can show incoming calls.',
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
    return ch.isNotEmpty && tok.isNotEmpty && uid > 0;
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
    var callType = 'audio';
    if (Get.isRegistered<PendingVoiceCall>()) {
      final pending = Get.find<PendingVoiceCall>().payload;
      final ct = (pending?['callType'] ?? '').trim().toLowerCase();
      if (ct == 'video') callType = 'video';
    }
    return IncomingCallPayload.normalizeInviteStrings({
      'callId': callId.trim(),
      'type': callType == 'video' ? 'incoming_video_call' : 'incoming_voice_call',
      'notificationType': 'incoming_call',
      'callType': callType,
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
      case Event.actionCallStart:
        if (_isOutgoingLocalCallkit(event.body)) {
          if (kDebugMode) {
            debugPrint('[callkit] Event.actionCallStart ignored (outgoing local)');
          }
        }
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
    if (Platform.isAndroid) {
      clearPendingIncomingVoiceNavigation();
      return;
    }
    openPendingIncomingVoiceCallIfReady();
  }

  static Future<void> _handleAccept(dynamic body) async {
    await OutgoingRingbackService.stop(reason: 'callkit_accept');
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
    await OutgoingRingbackService.stop(reason: 'callkit_decline');
    final invite = _parseEventToInvite(body);
    final callId = (invite?['callId'] ?? _callIdFromBody(body) ?? '').trim();
    if (callId.isNotEmpty) {
      _acceptHandledCallIds.remove(callId);
    }
    await dismissForCallId(callId);
    await _rejectViaRest(callId);
    if (Platform.isAndroid) {
      androidFinalizeVoiceCallDismissal(callId);
    }
  }

  static Future<void> _handleTimeout(dynamic body) async {
    await OutgoingRingbackService.stop(reason: 'callkit_timeout');
    final callId = (_callIdFromBody(body) ?? '').trim();
    if (callId.isNotEmpty) {
      _acceptHandledCallIds.remove(callId);
    }
    await dismissForCallId(callId);
    await _endViaRest(callId, reason: 'missed');
    if (Platform.isAndroid) {
      androidFinalizeVoiceCallDismissal(callId);
    }
  }

  static Future<void> _handleEnded(dynamic body) async {
    await OutgoingRingbackService.stop(reason: 'callkit_ended');
    final callId = (_callIdFromBody(body) ?? '').trim();
    if (callId.isNotEmpty) {
      _acceptHandledCallIds.remove(callId);
    }
    if (callId.isEmpty) {
      _clearCallTracking(callId);
      await _endViaRest(callId, reason: 'ended');
      if (Platform.isAndroid) {
        androidFinalizeVoiceCallDismissal(callId);
      }
      return;
    }
    await dismissForCallId(callId);
    _emitCallEndedToActiveUiIfNeeded(callId);
    _clearCallTracking(callId);
    await _endViaRest(callId, reason: 'ended');
    if (Platform.isAndroid) {
      androidFinalizeVoiceCallDismissal(callId);
    }
  }

  /// Android: after Decline/End/Timeout from CallKit, or remote call end over socket/FCM —
  /// drop stale pending + nav retries so reopening the app does not show the accept screen.
  static void androidFinalizeVoiceCallDismissal(String callId) {
    if (!Platform.isAndroid) return;
    final id = callId.trim();
    if (id.isNotEmpty) {
      PendingVoiceCall.markAndroidCallTerminal(id);
    }
    if (Get.isRegistered<PendingVoiceCall>()) {
      Get.find<PendingVoiceCall>().clear();
    }
    clearPendingIncomingVoiceNavigation();
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
