import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../data/session/session_storage.dart';
import '../network/api_endpoints.dart';
import '../network/dio_client.dart';
import '../push/pending_voice_call.dart';
import 'agora_call_service.dart';
import '../../data/auth/auth_repository.dart';
import '../../screens/chat/view/agora_audio_call_screen.dart';
import '../../screens/chat/view/agora_video_call_screen.dart';
import '../../screens/home/controller/home_controller.dart';

Timer? _pendingIncomingRetryTimer;
int _pendingIncomingRetryAttempts = 0;
const int _maxPendingIncomingRetryAttempts = 24;

void _schedulePendingIncomingRetry() {
  if (_pendingIncomingRetryTimer != null) return;
  if (_pendingIncomingRetryAttempts >= _maxPendingIncomingRetryAttempts) return;
  _pendingIncomingRetryAttempts += 1;
  _pendingIncomingRetryTimer = Timer(const Duration(milliseconds: 350), () {
    _pendingIncomingRetryTimer = null;
    openPendingIncomingVoiceCallIfReady();
  });
}

void _clearPendingIncomingRetry() {
  _pendingIncomingRetryTimer?.cancel();
  _pendingIncomingRetryTimer = null;
  _pendingIncomingRetryAttempts = 0;
}

/// Clears pending-call navigation retries (e.g. after Android CallKit Decline).
void clearPendingIncomingVoiceNavigation() {
  _clearPendingIncomingRetry();
}

Future<String?> _fetchVoiceCallStatusForOpen(String callId) async {
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

/// Opens the Agora voice call UI.
///
/// Note: avoid `deferred` imports for `agora_rtc_engine` on iOS — loading the split
/// library has been associated with `DartWorker` crashes; native Agora is already
/// registered at app start via the plugin.
Future<void> openVoiceCallScreen({
  required VoiceCallSession session,
  bool autoAcceptIncoming = false,
  bool acceptedFromCallkit = false,
}) async {
  await Get.to<void>(
    () => AgoraAudioCallScreen(
      session: session,
      autoAcceptIncoming: autoAcceptIncoming,
      acceptedFromCallkit: acceptedFromCallkit,
    ),
  );
}

/// Opens the Agora video call UI (same session + signaling as voice).
Future<void> openVideoCallScreen({
  required VoiceCallSession session,
  Future<VoiceCallSession>? outgoingInviteFuture,
  bool autoAcceptIncoming = false,
  bool acceptedFromCallkit = false,
}) async {
  await Get.to<void>(
    () => AgoraVideoCallScreen(
      session: session,
      outgoingInviteFuture: outgoingInviteFuture,
      autoAcceptIncoming: autoAcceptIncoming,
      acceptedFromCallkit: acceptedFromCallkit,
    ),
    transition: Transition.fadeIn,
    duration: const Duration(milliseconds: 120),
  );
}

Future<void> _openPendingIncomingVoiceCallAndroidAsync() async {
  if (!Get.isRegistered<PendingVoiceCall>()) return;
  final pending = Get.find<PendingVoiceCall>();
  if (!pending.hasPending) {
    _clearPendingIncomingRetry();
    return;
  }
  if (!Get.isRegistered<AuthRepository>()) {
    _schedulePendingIncomingRetry();
    return;
  }
  final token = Get.find<AuthRepository>().accessToken;
  if (token == null || token.isEmpty) {
    _schedulePendingIncomingRetry();
    return;
  }
  if (!Get.isRegistered<HomeController>()) {
    _schedulePendingIncomingRetry();
    return;
  }
  if (!Get.isRegistered<AgoraCallService>()) {
    _schedulePendingIncomingRetry();
    return;
  }

  if (!pending.autoAccept && !pending.androidShowRingUi) {
    _clearPendingIncomingRetry();
    return;
  }

  final callId = (pending.payload!['callId'] ?? '').trim();
  if (callId.isNotEmpty && PendingVoiceCall.isAndroidCallTerminal(callId)) {
    if (kDebugMode) {
      debugPrint(
        '[callkit-android] skip open pending: call marked terminal locally callId=$callId',
      );
    }
    pending.clear();
    _clearPendingIncomingRetry();
    return;
  }

  if (callId.isNotEmpty && !pending.autoAccept) {
    final status = await _fetchVoiceCallStatusForOpen(callId);
    if (status != null &&
        status != 'ringing' &&
        status != 'accepted') {
      if (kDebugMode) {
        debugPrint(
          '[callkit-android] skip open pending: backend status=$status callId=$callId',
        );
      }
      pending.clear();
      _clearPendingIncomingRetry();
      PendingVoiceCall.markAndroidCallTerminal(callId);
      return;
    }
  }

  _openPendingIncomingVoiceCallIfReadyCore();
}

/// Opens [AgoraAudioCallScreen] when [PendingVoiceCall] has payload (FCM / CallKit Accept).
void openPendingIncomingVoiceCallIfReady() {
  if (Platform.isAndroid) {
    unawaited(_openPendingIncomingVoiceCallAndroidAsync());
    return;
  }
  _openPendingIncomingVoiceCallIfReadyCore();
}

void _openPendingIncomingVoiceCallIfReadyCore() {
  if (!Get.isRegistered<PendingVoiceCall>()) return;
  final pending = Get.find<PendingVoiceCall>();
  if (!pending.hasPending) {
    _clearPendingIncomingRetry();
    return;
  }
  if (!Get.isRegistered<AuthRepository>()) {
    _schedulePendingIncomingRetry();
    return;
  }
  final token = Get.find<AuthRepository>().accessToken;
  if (token == null || token.isEmpty) {
    _schedulePendingIncomingRetry();
    return;
  }
  if (!Get.isRegistered<HomeController>()) {
    _schedulePendingIncomingRetry();
    return;
  }
  if (!Get.isRegistered<AgoraCallService>()) {
    _schedulePendingIncomingRetry();
    return;
  }

  final data = Map<String, String>.from(pending.payload!);
  final autoAccept = pending.autoAccept;

  if (Platform.isAndroid && !autoAccept && !pending.androidShowRingUi) {
    _clearPendingIncomingRetry();
    return;
  }

  final selfId = (Get.find<AuthRepository>().userId ?? '').trim();
  final svc = Get.find<AgoraCallService>();
  final callId = (data['callId'] ?? '').trim();
  if (callId.isNotEmpty && !svc.claimCallUi(callId)) {
    if (kDebugMode) {
      debugPrint(
        '[callkit] openPendingIncomingVoiceCallIfReady: claimCallUi failed callId=$callId active=${svc.activeUiCallId}',
      );
    }
    return;
  }

  try {
    final session = svc.sessionFromInvitePayload(
      Map<String, dynamic>.from(data),
      selfUserId: selfId,
      incomingAcceptAlreadyPosted: pending.incomingAcceptAlreadyPosted,
      allowIncompleteRtc: autoAccept,
    );
    final acceptedFromCallkit = pending.acceptedFromCallkit;
    pending.clear();
    _clearPendingIncomingRetry();
    if (kDebugMode) {
      debugPrint(
        '[callkit] navigation: scheduling AgoraAudioCallScreen callId=$callId autoAccept=$autoAccept acceptedFromCallkit=$acceptedFromCallkit',
      );
    }
    scheduleMicrotask(() {
      final open = session.isVideo ? openVideoCallScreen : openVoiceCallScreen;
      unawaited(
        open(
          session: session,
          autoAcceptIncoming: autoAccept,
          acceptedFromCallkit: acceptedFromCallkit,
        ),
      );
    });
  } catch (_) {
    // CallKit accept callbacks may arrive with partial data first.
    // Keep pending payload and retry while services/native state settle.
    if (autoAccept && _pendingIncomingRetryAttempts < _maxPendingIncomingRetryAttempts) {
      _schedulePendingIncomingRetry();
      if (callId.isNotEmpty) {
        svc.releaseCallUi(callId);
      }
      return;
    }
    pending.clear();
    _clearPendingIncomingRetry();
    if (callId.isNotEmpty) {
      svc.releaseCallUi(callId);
    }
  }
}
