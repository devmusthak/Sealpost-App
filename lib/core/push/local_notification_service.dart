import 'dart:ui';
import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';

import '../../data/chat/chat_repository.dart';

/// Must match [MainActivity] + server FCM `channelId` + `res/raw/notification.wav`.
const String kMailNotificationChannelId = 'sealpost_mail_custom';
const String kChatNotificationChannelId = 'sealpost_chat_messages';

const String _chatReplyActionId = 'chat_reply';
const String _chatOpenActionId = 'chat_open';
const String _chatDarwinCategory = 'chat_message_actions';
const String _chatGroupKey = 'sealpost_chat_group';
const int _chatGroupSummaryId = 0x51A1B0;

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  // Required for background notification action isolates.
  DartPluginRegistrant.ensureInitialized();
  await LocalNotificationService.handleBackgroundNotificationResponse(response);
}

/// Foreground FCM → local notification (Android does not show FCM heads-up while app is open).
class LocalNotificationService {
  LocalNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static void Function(Map<String, String> data)? _onMailTap;
  static void Function(Map<String, String> data)? _onChatTap;

  static const NotificationDetails _mailChannelDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      kMailNotificationChannelId,
      'Mail',
      channelDescription: 'New message notifications',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification'),
      audioAttributesUsage: AudioAttributesUsage.notification,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'notification.wav',
    ),
    macOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'notification.wav',
    ),
  );

  static const NotificationDetails _chatSummaryDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      kChatNotificationChannelId,
      'Chat messages',
      channelDescription: 'Chat conversation notifications',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification'),
      audioAttributesUsage: AudioAttributesUsage.notification,
      groupKey: _chatGroupKey,
      setAsGroupSummary: true,
      styleInformation: DefaultStyleInformation(true, true),
    ),
  );

  static Future<void> init({
    required void Function(Map<String, String> data) onMailNotificationTap,
    void Function(Map<String, String> data)? onChatNotificationTap,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _onMailTap = onMailNotificationTap;
    _onChatTap = onChatNotificationTap;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          _chatDarwinCategory,
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.text(
              _chatReplyActionId,
              'Reply',
              buttonTitle: 'Send',
              placeholder: 'Type a message',
            ),
            DarwinNotificationAction.plain(_chatOpenActionId, 'Open'),
          ],
        ),
      ],
    );
    final initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
    );

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        kMailNotificationChannelId,
        'Mail',
        description: 'New message notifications',
        importance: Importance.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('notification'),
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        kChatNotificationChannelId,
        'Chat messages',
        description: 'Chat conversation notifications',
        importance: Importance.high,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('notification'),
        enableVibration: true,
      ),
    );
    await android?.requestNotificationsPermission();

    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static void _onNotificationResponse(NotificationResponse response) {
    final actionId = response.actionId;
    if (actionId == _chatReplyActionId) {
      final payload = response.payload;
      final input = (response.input ?? '').trim();
      if (payload != null && payload.isNotEmpty && input.isNotEmpty) {
        unawaited(_handleReplyAction(payload: payload, replyText: input));
      }
      return;
    }
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    _dispatchPayload(payload);
  }

  static Future<void> handleBackgroundNotificationResponse(
    NotificationResponse response,
  ) async {
    if (response.actionId == _chatReplyActionId) {
      final payload = response.payload;
      final input = (response.input ?? '').trim();
      if (payload != null && payload.isNotEmpty && input.isNotEmpty) {
        await _handleReplyAction(payload: payload, replyText: input);
      }
      return;
    }
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    _dispatchPayload(payload);
  }

  static void _dispatchPayload(String payload) {
    try {
      final raw = jsonDecode(payload) as Map<String, dynamic>;
      final data = raw.map((k, v) => MapEntry(k.toString(), '${v ?? ''}'));
      final t = data['type'] ?? '';
      if (t == 'new_mail') {
        _onMailTap?.call(data);
      } else if (t == 'new_chat_message') {
        _onChatTap?.call(data);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[local notif] bad payload: $e');
      }
    }
  }

  /// Cold start: user opened the app by tapping a local notification.
  static Future<void> consumeLaunchNotification() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final payload = details!.notificationResponse?.payload;
    if (payload == null || payload.isEmpty) return;
    _dispatchPayload(payload);
  }

  static int _idForMail(String mailId) => mailId.hashCode & 0x7fffffff;

  static int _idForChatPeer(String peerId) => peerId.hashCode & 0x7fffffff;

  /// Shows a local notification for FCM while the app is in the foreground on Android.
  /// Handles `new_mail` and test/other payloads that include a [RemoteMessage.notification].
  static Future<void> showForegroundRemoteMessage(RemoteMessage message) async {
    if (!_initialized) return;
    final d = message.data;

    if (d['type'] == 'new_chat_message') {
      final messageId = (d['messageId'] ?? '').trim();
      final peerId = (d['fromUserId'] ?? d['peerId'] ?? '').trim();
      if (messageId.isEmpty || peerId.isEmpty) return;
      final title = _chatSenderTitle(d);
      final body = _chatPreviewText(d, fallback: message.notification?.body);
      final payloadMap = d.map((k, v) => MapEntry(k, '$v'));
      await _plugin.show(
        id: _idForChatPeer(peerId),
        title: title,
        body: body,
        notificationDetails: _chatChannelDetails(
          senderName: title,
          preview: body,
          isGroupConversation: false,
        ),
        payload: jsonEncode(payloadMap),
      );
      await _showChatGroupSummary();
      return;
    }

    if (d['type'] == 'new_mail') {
      final mailId = (d['mailId'] ?? '').trim();
      if (mailId.isEmpty) return;
      final title =
          message.notification?.title ??
          ((d['fromName'] ?? '').trim().isNotEmpty
              ? d['fromName']!
              : 'New mail');
      final body =
          message.notification?.body ??
          ((d['subject'] ?? '').trim().isNotEmpty
              ? d['subject']!
              : ((d['snippet'] ?? '').trim().isNotEmpty
                    ? d['snippet']!
                    : 'New message'));
      final payloadMap = d.map((k, v) => MapEntry(k, '$v'));
      await _plugin.show(
        id: _idForMail(mailId),
        title: title,
        body: body,
        notificationDetails: _mailChannelDetails,
        payload: jsonEncode(payloadMap),
      );
      return;
    }

    // e.g. server test-fcm: type=fcm_test + notification title/body
    final n = message.notification;
    if (n == null) return;
    final title = (n.title ?? '').trim();
    final body = (n.body ?? '').trim();
    if (title.isEmpty && body.isEmpty) return;

    final payloadMap = Map<String, String>.from(
      d.map((k, v) => MapEntry(k, '$v')),
    );
    final id = d['type'] == 'fcm_test'
        ? (DateTime.now().millisecondsSinceEpoch % 0x3fffffff)
        : ((title + body).hashCode & 0x7fffffff);

    await _plugin.show(
      id: id,
      title: title.isEmpty ? 'Sealpost' : title,
      body: body.isEmpty ? '—' : body,
      notificationDetails: _mailChannelDetails,
      payload: jsonEncode(payloadMap),
    );
  }

  static AndroidNotificationDetails _chatAndroidDetails({
    required String senderName,
    required String preview,
    required bool isGroupConversation,
  }) {
    return AndroidNotificationDetails(
      kChatNotificationChannelId,
      'Chat messages',
      channelDescription: 'Chat conversation notifications',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('notification'),
      audioAttributesUsage: AudioAttributesUsage.notification,
      groupKey: _chatGroupKey,
      category: AndroidNotificationCategory.message,
      styleInformation: MessagingStyleInformation(
        Person(name: 'You'),
        conversationTitle: isGroupConversation ? senderName : null,
        groupConversation: isGroupConversation,
        messages: [Message(preview, DateTime.now(), Person(name: senderName))],
      ),
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          _chatReplyActionId,
          'Reply',
          showsUserInterface: false,
          inputs: <AndroidNotificationActionInput>[
            AndroidNotificationActionInput(label: 'Type a message'),
          ],
        ),
        const AndroidNotificationAction(_chatOpenActionId, 'Open'),
      ],
    );
  }

  static NotificationDetails _chatChannelDetails({
    required String senderName,
    required String preview,
    required bool isGroupConversation,
  }) {
    return NotificationDetails(
      android: _chatAndroidDetails(
        senderName: senderName,
        preview: preview,
        isGroupConversation: isGroupConversation,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'notification.wav',
        categoryIdentifier: _chatDarwinCategory,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'notification.wav',
        categoryIdentifier: _chatDarwinCategory,
      ),
    );
  }

  static String _chatSenderTitle(Map<String, dynamic> data) {
    final fromName = (data['fromName'] ?? '').trim();
    if (fromName.isNotEmpty) return fromName;
    final fromEmail = (data['fromEmail'] ?? '').trim();
    if (fromEmail.isNotEmpty) return fromEmail;
    return 'New message';
  }

  static String _chatPreviewText(
    Map<String, dynamic> data, {
    String? fallback,
  }) {
    final kind =
        (data['messageType'] ?? data['kind'] ?? data['contentType'] ?? '')
            .trim()
            .toLowerCase();
    switch (kind) {
      case 'image':
      case 'photo':
        return '📷 Photo';
      case 'audio':
      case 'voice':
      case 'voice_note':
      case 'voice_message':
        return '🎤 Voice message';
      case 'video':
        return '🎥 Video';
      case 'file':
      case 'document':
      case 'attachment':
        return '📎 Attachment';
    }
    final body = (data['bodyPreview'] ?? data['body'] ?? fallback ?? '').trim();
    if (body.isNotEmpty) return body;
    return 'You have a new chat message';
  }

  static Future<void> _showChatGroupSummary() async {
    await _plugin.show(
      id: _chatGroupSummaryId,
      title: 'Sealpost',
      body: 'New chat messages',
      notificationDetails: _chatSummaryDetails,
      payload: jsonEncode(<String, String>{'type': 'new_chat_message'}),
    );
  }

  static Future<void> clearChatNotificationsForPeer(String peerId) async {
    final p = peerId.trim();
    if (p.isEmpty) return;
    await _plugin.cancel(id: _idForChatPeer(p));
  }

  static Future<void> clearAllChatNotifications() async {
    final active = await _plugin.getActiveNotifications();
    for (final n in active) {
      final p = n.payload;
      if (p == null || p.isEmpty) continue;
      try {
        final raw = jsonDecode(p);
        if (raw is! Map) continue;
        final t = '${raw['type'] ?? ''}';
        if (t == 'new_chat_message') {
          final id = n.id;
          if (id != null) {
            await _plugin.cancel(id: id);
          }
        }
      } catch (_) {
        // Ignore malformed payloads.
      }
    }
    await _plugin.cancel(id: _chatGroupSummaryId);
  }

  static Future<void> _handleReplyAction({
    required String payload,
    required String replyText,
  }) async {
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map) return;
      final data = raw.map((k, v) => MapEntry(k.toString(), '${v ?? ''}'));
      if ((data['type'] ?? '') != 'new_chat_message') return;
      final peerId = (data['fromUserId'] ?? data['peerId'] ?? '').trim();
      if (peerId.isEmpty) return;
      final text = replyText.trim();
      if (text.isEmpty) return;
      final sent = await _sendQuickReply(peerId: peerId, body: text);
      if (!sent) return;
      await clearChatNotificationsForPeer(peerId);
      if (_onChatTap != null) {
        // Keep existing routing state coherent when app later opens.
        _onChatTap!.call(data);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[local notif] reply action failed: $e');
      }
    }
  }

  static Future<bool> _sendQuickReply({
    required String peerId,
    required String body,
  }) async {
    try {
      if (Get.isRegistered<ChatRepository>()) {
        await Get.find<ChatRepository>().sendChatMessage(
          peerId: peerId,
          body: body,
          clientId: _quickReplyClientId(),
        );
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static String _quickReplyClientId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    return 'notif-$ms';
  }
}
