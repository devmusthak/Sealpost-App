import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Must match [MainActivity] + server FCM `channelId` + `res/raw/notification.wav`.
const String kMailNotificationChannelId = 'sealpost_mail_custom';

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

  static Future<void> init({
    required void Function(Map<String, String> data) onMailNotificationTap,
    void Function(Map<String, String> data)? onChatNotificationTap,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _onMailTap = onMailNotificationTap;
    _onChatTap = onChatNotificationTap;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
    );

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
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
    await android?.requestNotificationsPermission();

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static void _onNotificationResponse(NotificationResponse response) {
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

  static int _idForChatMessage(String messageId) => messageId.hashCode & 0x7fffffff;

  /// Shows a local notification for FCM while the app is in the foreground on Android.
  /// Handles `new_mail` and test/other payloads that include a [RemoteMessage.notification].
  static Future<void> showForegroundRemoteMessage(RemoteMessage message) async {
    if (!_initialized) return;
    final d = message.data;

    if (d['type'] == 'new_chat_message') {
      final messageId = (d['messageId'] ?? '').trim();
      if (messageId.isEmpty) return;
      final title = message.notification?.title ??
          ((d['fromName'] ?? '').trim().isNotEmpty
              ? d['fromName']!
              : ((d['fromEmail'] ?? '').trim().isNotEmpty ? d['fromEmail']! : 'New message'));
      final body = message.notification?.body ??
          ((d['body'] ?? '').trim().isNotEmpty ? d['body']! : 'You have a new chat message');
      final payloadMap = d.map((k, v) => MapEntry(k, '$v'));
      await _plugin.show(
        id: _idForChatMessage(messageId),
        title: title,
        body: body,
        notificationDetails: _mailChannelDetails,
        payload: jsonEncode(payloadMap),
      );
      return;
    }

    if (d['type'] == 'new_mail') {
      final mailId = (d['mailId'] ?? '').trim();
      if (mailId.isEmpty) return;
      final title = message.notification?.title ??
          ((d['fromName'] ?? '').trim().isNotEmpty ? d['fromName']! : 'New mail');
      final body = message.notification?.body ??
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
}
