import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:get/get.dart';

import '../call/incoming_call_payload.dart';

/// Holds FCM / local-notification payload until [HomeScreen] can open the call UI.
class PendingVoiceCall extends GetxController {
  Map<String, String>? payload;

  /// When true, [AgoraAudioCallScreen] auto-accepts (notification "Accept" action).
  bool autoAccept = false;

  /// User accepted from iOS CallKit (vs in-app ringing UI).
  bool acceptedFromCallkit = false;

  /// POST /call/accept was already sent while resolving CallKit payload (avoid duplicate accept).
  bool incomingAcceptAlreadyPosted = false;

  bool get hasPending => payload != null && (payload!['callId'] ?? '').trim().isNotEmpty;

  void setFromMessage(RemoteMessage message) {
    applyFromData(
      Map<String, String>.from(message.data.map((k, v) => MapEntry(k, '$v'))),
    );
  }

  void applyFromData(Map<String, String> d) {
    if (!IncomingCallPayload.isIncomingAudioCall(d)) return;
    final next = IncomingCallPayload.normalizeInviteStrings(d);
    final prev = payload;
    if (prev != null) {
      final prevCallId = (prev['callId'] ?? '').trim();
      final nextCallId = (next['callId'] ?? '').trim();
      final sameCall =
          prevCallId.isNotEmpty && nextCallId.isNotEmpty && prevCallId == nextCallId;
      if (sameCall) {
        // CallKit action events can carry partial payloads; keep previously
        // known non-empty session fields so accept flow can still join Agora.
        payload = Map<String, String>.from(prev);
        next.forEach((key, value) {
          if (value.trim().isNotEmpty) {
            payload![key] = value;
          }
        });
      } else {
        payload = next;
      }
    } else {
      payload = next;
    }
    autoAccept = autoAccept || d['_autoAccept'] == '1';
    acceptedFromCallkit = acceptedFromCallkit || d['_acceptedFromCallkit'] == '1';
    incomingAcceptAlreadyPosted =
        incomingAcceptAlreadyPosted || d['_incomingAcceptAlreadyPosted'] == '1';
  }

  void clear() {
    payload = null;
    autoAccept = false;
    acceptedFromCallkit = false;
    incomingAcceptAlreadyPosted = false;
  }
}
