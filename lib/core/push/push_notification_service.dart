import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../data/auth/auth_repository.dart';
import '../../data/chat/chat_contact.dart';
import '../../data/mail/mail_list_item.dart';
import '../../screens/chat/controller/chat_controller.dart';
import '../../screens/chat/view/chat_thread_view.dart';
import '../../screens/home/controller/home_controller.dart';
import '../../screens/mail_detail/view/mail_detail_view.dart';
import 'local_notification_service.dart';

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
    final id = (d['fromUserId'] ?? d['peerId'] ?? '').trim();
    if (id.isEmpty) return;
    final name = (d['fromName'] ?? '').trim();
    final email = (d['fromEmail'] ?? '').trim();
    contact = ChatContact(
      id: id,
      name: name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Chat'),
      email: email.isNotEmpty ? email : '',
      isOnline: false,
      lastSeenAt: null,
      relationStatus: 'friends',
      lastMessage: '',
      timeLabel: '',
      unreadCount: 0,
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
        alert: true,
        badge: true,
        sound: true,
      );
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
    );
    await LocalNotificationService.consumeLaunchNotification();

    if (_listenersReady) return;
    _listenersReady = true;

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (kDebugMode) {
        debugPrint('[fcm] foreground ${message.notification?.title}');
      }
      // Android: FCM does not show a heads-up while app is open; use local notifs.
      // iOS/macOS: [setForegroundNotificationPresentationOptions] shows the system banner.
      if (defaultTargetPlatform == TargetPlatform.android) {
        final d = message.data;
        if (d['type'] == 'new_chat_message') {
          final from = '${d['fromUserId'] ?? ''}'.trim();
          if (from.isNotEmpty &&
              Get.isRegistered<ChatController>() &&
              Get.find<ChatController>().openConversationPeerId == from) {
            unawaited(
              LocalNotificationService.clearChatNotificationsForPeer(from),
            );
            return;
          }
        }
        unawaited(
          LocalNotificationService.showForegroundRemoteMessage(message),
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpened);

    final initial = await _fm.getInitialMessage();
    if (initial != null) {
      _handleMessageOpened(initial);
    }
  }

  static void _handleMessageOpened(RemoteMessage message) {
    final d = Map<String, String>.from(
      message.data.map((k, v) => MapEntry(k, '$v')),
    );
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
      final token = await _fm.getToken();
      if (token != null && token.isNotEmpty) {
        await auth.registerFcmToken(token);
      }
      if (!_tokenRefreshHooked) {
        _tokenRefreshHooked = true;
        _fm.onTokenRefresh.listen((t) {
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
