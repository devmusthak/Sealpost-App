import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../core/call/incoming_call_kit_coordinator.dart';
import '../core/call/incoming_call_payload.dart';
import '../firebase_options.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
    final d = Map<String, String>.from(
      message.data.map((k, v) => MapEntry(k, '$v')),
    );
    debugPrint(
      "[fcm-ios] background handler messageId=${message.messageId} type=${d['type'] ?? ''} notificationType=${d['notificationType'] ?? ''} isCallEnded=${IncomingCallPayload.isVoiceCallEnded(d)} isIncomingCall=${IncomingCallPayload.isIncomingAudioCall(d)}",
    );
  }

  final d = Map<String, String>.from(
    message.data.map((k, v) => MapEntry(k, '$v')),
  );

  if (IncomingCallPayload.isVoiceCallEnded(d)) {
    final id = (d['callId'] ?? '').trim();
    if (id.isNotEmpty) {
      await IncomingCallKitCoordinator.dismissForCallId(id);
    }
    return;
  }

  if (IncomingCallPayload.isIncomingAudioCall(d)) {
    await IncomingCallKitCoordinator.presentFromFcmData(d);
    return;
  }

  if (kDebugMode) {
    debugPrint('[fcm] background message ${message.messageId}');
  }
}
