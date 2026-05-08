import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../data/auth/auth_repository.dart';
import '../../data/chat/chat_contact.dart';
import '../../data/mail/mail_list_item.dart';
import '../call/incoming_call_kit_coordinator.dart';
import '../call/incoming_call_payload.dart';
import '../call/voice_call_navigation.dart';
import '../../screens/chat/controller/chat_controller.dart';
import '../../screens/chat/view/chat_thread_view.dart';
import '../../screens/home/controller/home_controller.dart';
import '../../screens/mail_detail/view/mail_detail_view.dart';
import 'local_notification_service.dart';
import 'pending_voice_call.dart';

/// Holds a notification tap until [HomeScreen] is ready to navigate.
class PendingMailNotification extends GetxController {
  String? mailId;
  MailListItem? preview;
  String folderKey = 'INBOX';

  bool get hasPending =>
      mailId != null && mailId!.isNotEmpty && preview != null;

  void setFromMessage(RemoteMessage message) {
    applyFromData(
      Map<String, String>.from(message.data.map((k, v) => MapEntry(k, '$v'))),
    );
  }

  void applyFromData(Map<String, String> d) {
    if (d['type'] != 'new_mail') return;
    final id = (d['mailId'] ?? '').trim();
    if (id.isEmpty) return;
    mailId = id;
    final f = (d['folder'] ?? '').trim();
    folderKey = f.isNotEmpty ? f : 'INBOX';
    final sub = (d['subject'] ?? '').trim();
    final fn = (d['fromName'] ?? '').trim();
    final snippet = d['snippet'] ?? '';
    final dateStr = (d['date'] ?? '').trim();
    final addrRaw = (d['fromAddress'] ?? '').trim();
    final mtRaw = (d['messageType'] ?? '').trim();
    preview = MailListItem(
      id: id,
      subject: sub.isEmpty ? null : sub,
      snippet: snippet,
      date: dateStr.isEmpty ? null : dateStr,
      fromName: fn.isEmpty ? 'Unknown' : fn,
      fromAddress: addrRaw.isEmpty ? null : addrRaw,
      flagged: d['flagged'] == '1' || d['flagged'] == 'true',
      messageType: mtRaw.isEmpty ? null : mtRaw,
    );
  }

  void clear() {
    mailId = null;
    preview = null;
    folderKey = 'INBOX';
  }
}

/// FCM / local notification tap for opening a 1:1 chat thread.
class PendingChatNotification extends GetxController {
  ChatContact? contact;

  bool get hasPending => contact != null;

  void setFromMessage(RemoteMessage message) {
    applyFromData(
      Map<String, String>.from(message.data.map((k, v) => MapEntry(k, '$v'))),
    );
  }

  void applyFromData(Map<String, String> d) {
    if (d['type'] != 'new_chat_message') return;
    final groupId = (d['groupId'] ?? '').trim();
    final isGroup =
        (d['isGroupConversation'] ?? '').trim().toLowerCase() == 'true' ||
        groupId.isNotEmpty;
    final id = (isGroup ? groupId : (d['fromUserId'] ?? d['peerId'] ?? '')).trim();
    if (id.isEmpty) return;
    final name = (d['fromName'] ?? '').trim();
    final groupName = (d['groupName'] ?? d['conversationName'] ?? '').trim();
    final email = (d['fromEmail'] ?? '').trim();
    contact = ChatContact(
      id: id,
      name: isGroup
          ? (groupName.isNotEmpty ? groupName : 'Group')
          : (name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Chat')),
      email: email.isNotEmpty ? email : '',
      isOnline: false,
      lastSeenAt: null,
      relationStatus: 'friends',
      lastMessage: '',
      timeLabel: '',
      unreadCount: 0,
      conversationType: isGroup ? 'group' : 'direct',
      groupId: isGroup ? id : null,
      groupImage: (d['groupImage'] ?? '').trim(),
    );
  }

  void clear() {
    contact = null;
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final FirebaseMessaging _fm = FirebaseMessaging.instance;
  static bool _listenersReady = false;
  static bool _tokenRefreshHooked = false;

  static Future<void> requestPermissionAndSetupListeners() async {
    await _fm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      await _fm.setForegroundNotificationPresentationOptions(
        // Foreground alerts must be enabled for iOS normal chat/mail pushes.
        // CallKit/VoIP call flow is handled separately.
        alert: true,
        badge: true,
        sound: true,
      );
    }

    // iOS-only debug telemetry for troubleshooting normal push flow.
    if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
      final settings = await _fm.getNotificationSettings();
      debugPrint(
        '[fcm-ios] notification settings: '
        'authorized=${settings.authorizationStatus} alert=${settings.alert} sound=${settings.sound} badge=${settings.badge}',
      );
      try {
        final apnsToken = await _fm.getAPNSToken();
        debugPrint('[fcm-ios] apns token: ${(apnsToken ?? '').trim()}');
      } catch (e) {
        debugPrint('[fcm-ios] apns token read failed: $e');
      }
    }

    await LocalNotificationService.init(
      onMailNotificationTap: (data) {
        Get.find<PendingMailNotification>().applyFromData(data);
        tryNavigateToMailDetail();
      },
      onChatNotificationTap: (data) {
        Get.find<PendingChatNotification>().applyFromData(data);
        tryNavigateToChatThread();
      },
      onVoiceCallNotificationTap: (data) {
        Get.find<PendingVoiceCall>().applyFromData(data);
        openPendingIncomingVoiceCallIfReady();
      },
    );
    await LocalNotificationService.consumeLaunchNotification();

    IncomingCallKitCoordinator.attachListeners();
    unawaited(IncomingCallKitCoordinator.requestAndroidCallPermissions());

    if (_listenersReady) return;
    _listenersReady = true;

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final isIos = defaultTargetPlatform == TargetPlatform.iOS;
      if (kDebugMode) {
        debugPrint('[fcm] foreground ${message.notification?.title}');
      }
      final d = Map<String, String>.from(
        message.data.map((k, v) => MapEntry(k, '$v')),
      );
      final isCallEnded = IncomingCallPayload.isVoiceCallEnded(d);
      final isIncomingCall = IncomingCallPayload.isIncomingAudioCall(d);

      if (isIos && kDebugMode) {
        debugPrint(
          "[fcm-ios] onMessage type=${d['type'] ?? ''} notificationType=${d['notificationType'] ?? ''} "
          "filter: isCallEnded=$isCallEnded isIncomingCall=$isIncomingCall",
        );
      }

      if (isCallEnded) {
        final id = (d['callId'] ?? '').trim();
        if (id.isNotEmpty) {
          unawaited(IncomingCallKitCoordinator.dismissForCallId(id));
          unawaited(LocalNotificationService.cancelIncomingCallNotification(id));
        }
        return;
      }
      if (isIncomingCall) {
        unawaited(IncomingCallKitCoordinator.presentFromFcmData(d));
        return;
      }
      if (d['type'] == 'new_chat_message') {
        final groupId = (d['groupId'] ?? '').trim();
        final isGroup =
            (d['isGroupConversation'] ?? '').trim().toLowerCase() == 'true' ||
            groupId.isNotEmpty;
        final conversationId = isGroup
            ? groupId
            : (d['fromUserId'] ?? d['peerId'] ?? '').trim();
        // Temporary rollback for iOS: do not suppress foreground chat banners
        // based on active chat matching.
        final shouldSuppressSameChat = !isIos &&
            conversationId.isNotEmpty &&
            Get.isRegistered<ChatController>() &&
            Get.find<ChatController>().openConversationPeerId ==
                conversationId;
        if (shouldSuppressSameChat) {
          unawaited(
            LocalNotificationService.clearChatNotificationsForPeer(
              conversationId,
            ),
          );
          return;
        }
      }
      unawaited(LocalNotificationService.showForegroundRemoteMessage(message));
    });

    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpened);

    final initial = await _fm.getInitialMessage();
    if (initial != null) {
      if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
        final d = Map<String, String>.from(
          initial.data.map((k, v) => MapEntry(k, '$v')),
        );
        debugPrint(
          "[fcm-ios] getInitialMessage type=${d['type'] ?? ''} notificationType=${d['notificationType'] ?? ''}",
        );
      }
      _handleMessageOpened(initial);
    }
  }

  static void _handleMessageOpened(RemoteMessage message) {
    final d = Map<String, String>.from(
      message.data.map((k, v) => MapEntry(k, '$v')),
    );
    if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
      debugPrint(
        "[fcm-ios] onMessageOpenedApp type=${d['type'] ?? ''} notificationType=${d['notificationType'] ?? ''}",
      );
    }
    if (IncomingCallPayload.isVoiceCallEnded(d)) {
      final id = (d['callId'] ?? '').trim();
      if (id.isNotEmpty) {
        unawaited(IncomingCallKitCoordinator.dismissForCallId(id));
        unawaited(LocalNotificationService.cancelIncomingCallNotification(id));
      }
      return;
    }
    if (IncomingCallPayload.isIncomingAudioCall(d)) {
      Get.find<PendingVoiceCall>().applyFromData(
        IncomingCallPayload.normalizeInviteStrings(d),
      );
      openPendingIncomingVoiceCallIfReady();
      return;
    }
    if (d['type'] == 'new_chat_message') {
      Get.find<PendingChatNotification>().setFromMessage(message);
      tryNavigateToChatThread();
      return;
    }
    Get.find<PendingMailNotification>().setFromMessage(message);
    tryNavigateToMailDetail();
  }

  /// After login / home visible.
  static Future<void> syncFcmTokenToServer() async {
    if (!Get.isRegistered<AuthRepository>()) return;
    final auth = Get.find<AuthRepository>();
    if (auth.accessToken == null || auth.accessToken!.isEmpty) return;

    try {
      if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
        try {
          final apns = (await _fm.getAPNSToken())?.trim() ?? '';
          debugPrint('[fcm-ios] APNs token before fcm sync: $apns');
          if (apns.isEmpty) {
            // Some iOS devices may provide APNs token slightly after first launch.
            await Future<void>.delayed(const Duration(seconds: 1));
            final apns2 = (await _fm.getAPNSToken())?.trim() ?? '';
            debugPrint('[fcm-ios] APNs token after retry: $apns2');
          }
        } catch (e) {
          debugPrint('[fcm-ios] APNs token read failed: $e');
        }
      }

      final token = await _fm.getToken();
      if (token != null && token.isNotEmpty) {
        if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
          debugPrint('[fcm-ios] FCM token: ${token.trim()}');
        }
        await auth.registerFcmToken(token);
      }
      unawaited(IncomingCallKitCoordinator.syncVoipTokenToServer());
      if (!_tokenRefreshHooked) {
        _tokenRefreshHooked = true;
        _fm.onTokenRefresh.listen((t) {
          if (defaultTargetPlatform == TargetPlatform.iOS && kDebugMode) {
            debugPrint('[fcm-ios] FCM token refreshed: ${t.trim()}');
          }
          unawaited(auth.registerFcmToken(t));
        });
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[fcm] token sync failed: $e');
      }
    }
  }

  /// Call from [HomeScreen] after first frame (and when resuming with pending tap).
  static void tryNavigateToMailDetail() {
    if (!Get.isRegistered<PendingMailNotification>()) return;
    final pending = Get.find<PendingMailNotification>();
    if (!pending.hasPending) return;
    if (!Get.isRegistered<AuthRepository>()) return;
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) return;
    if (!Get.isRegistered<HomeController>()) return;

    final id = pending.mailId!;
    final preview = pending.preview!;
    final folder = pending.folderKey;
    pending.clear();

    unawaited(_openMailDetail(id, preview, folder));
  }

  static Future<void> _openMailDetail(
    String id,
    MailListItem preview,
    String folder,
  ) async {
    if (Get.isRegistered<HomeController>()) {
      final home = Get.find<HomeController>();
      if (home.selectedFolder.value != folder) {
        await home.selectFolder(folder);
      }
    }
    await Future<void>.delayed(Duration.zero);
    Get.to<void>(
      () => MailDetailScreen(mailId: id, preview: preview, folderKey: folder),
    );
  }

  /// Opens the Agora voice UI when user taps an incoming-call notification / Accept.
  static void tryNavigateToIncomingCall() {
    openPendingIncomingVoiceCallIfReady();
  }

  /// Call from [HomeScreen] after [HomeController] exists (same timing as mail).
  static void tryNavigateToChatThread() {
    if (!Get.isRegistered<PendingChatNotification>()) return;
    final pending = Get.find<PendingChatNotification>();
    if (!pending.hasPending) return;
    if (!Get.isRegistered<AuthRepository>()) return;
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) return;
    if (!Get.isRegistered<HomeController>()) return;

    final contact = pending.contact!;
    pending.clear();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openChatThread(contact));
    });
  }

  static Future<void> _openChatThread(ChatContact contact) async {
    await LocalNotificationService.clearChatNotificationsForPeer(contact.id);
    await Future<void>.delayed(Duration.zero);
    Get.to<void>(() => ChatThreadScreen(contact: contact));
  }
}
