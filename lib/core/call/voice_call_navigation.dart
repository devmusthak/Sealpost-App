import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'agora_call_service.dart';
import '../../data/auth/auth_repository.dart';
import '../../screens/chat/view/agora_audio_call_screen.dart';
import '../../screens/home/controller/home_controller.dart';
import '../push/pending_voice_call.dart';

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

/// Opens the Agora voice call UI.
///
/// Note: avoid `deferred` imports for `agora_rtc_engine` on iOS — loading the split
/// library has been associated with `DartWorker` crashes; native Agora is already
/// registered at app start via the plugin.
Future<void> openVoiceCallScreen({
  required VoiceCallSession session,
  bool autoAcceptIncoming = false,
}) async {
  await Get.to<void>(
    () => AgoraAudioCallScreen(
      session: session,
      autoAcceptIncoming: autoAcceptIncoming,
    ),
  );
}

/// Opens [AgoraAudioCallScreen] when [PendingVoiceCall] has payload (FCM / CallKit Accept).
void openPendingIncomingVoiceCallIfReady() {
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

  final selfId = (Get.find<AuthRepository>().userId ?? '').trim();
  final svc = Get.find<AgoraCallService>();
  final callId = (data['callId'] ?? '').trim();
  if (callId.isNotEmpty && !svc.claimCallUi(callId)) {
    return;
  }

  try {
    final session = svc.sessionFromInvitePayload(
      Map<String, dynamic>.from(data),
      selfUserId: selfId,
    );
    pending.clear();
    _clearPendingIncomingRetry();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        openVoiceCallScreen(
          session: session,
          autoAcceptIncoming: autoAccept,
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
