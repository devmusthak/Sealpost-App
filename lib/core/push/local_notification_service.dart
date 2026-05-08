import 'dart:ui';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';

import '../../core/network/api_endpoints.dart';
import '../../core/network/dio_client.dart';
import '../../core/call/incoming_call_kit_coordinator.dart';
import '../../core/call/incoming_call_payload.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/session/session_storage.dart';
import '../../data/chat/chat_repository.dart';

/// Must match [MainActivity] + server FCM `channelId` + `res/raw/notification.wav`.
const String kMailNotificationChannelId = 'sealpost_mail_custom';
const String kChatNotificationChannelId = 'sealpost_chat_messages';
const String kIncomingCallNotificationChannelId = 'sealpost_incoming_calls';

const String _chatReplyActionId = 'chat_reply';
const String _chatOpenActionId = 'chat_open';
const String _voiceCallAcceptActionId = 'voice_call_accept';
const String _voiceCallRejectActionId = 'voice_call_reject';
const String _chatDarwinCategory = 'chat_message_actions';
const String _incomingCallDarwinCategory = 'incoming_voice_call_actions';
const String _chatGroupKey = 'sealpost_chat_group';
const int _chatGroupSummaryId = 0x51A1B0;
const int _chatReplyStatusNotificationId = 0x51A1B1;

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
  static void Function(Map<String, String> data)? _onVoiceCallTap;

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
    void Function(Map<String, String> data)? onVoiceCallNotificationTap,
  }) async {
    if (_initialized) return;
    _initialized = true;
    _onMailTap = onMailNotificationTap;
    _onChatTap = onChatNotificationTap;
    _onVoiceCallTap = onVoiceCallNotificationTap;

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
        DarwinNotificationCategory(
          _incomingCallDarwinCategory,
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(_voiceCallAcceptActionId, 'Accept'),
            DarwinNotificationAction.plain(_voiceCallRejectActionId, 'Decline'),
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
    await android?.createNotificationChannel(
      AndroidNotificationChannel(
        kIncomingCallNotificationChannelId,
        'Incoming calls',
        description: 'Voice call alerts — ringtone and vibration',
        importance: Importance.max,
        playSound: true,
        sound: const RawResourceAndroidNotificationSound('notification'),
        enableVibration: true,
        vibrationPattern: Int64List.fromList([
          0,
          700,
          400,
          700,
          400,
          700,
          400,
          700,
        ]),
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
    final payload = response.payload;
    final input = (response.input ?? '').trim();
    if (payload != null &&
        payload.isNotEmpty &&
        (actionId == _voiceCallAcceptActionId ||
            actionId == _voiceCallRejectActionId)) {
      unawaited(_handleVoiceCallNotificationAction(
        actionId: actionId ?? '',
        payload: payload,
      ));
      return;
    }
    // Some Android builds/plugins may not return the exact custom action id.
    // If user typed inline input, treat it as chat quick reply.
    if (input.isNotEmpty && payload != null && payload.isNotEmpty) {
      unawaited(_handleReplyAction(payload: payload, replyText: input));
      return;
    }
    if (payload == null || payload.isEmpty) return;
    if (kDebugMode) {
      debugPrint(
        '[local notif] tap actionId="$actionId" inputLen=${input.length}',
      );
    }
    _dispatchPayload(payload);
  }

  static Future<void> handleBackgroundNotificationResponse(
    NotificationResponse response,
  ) async {
    final actionId = response.actionId;
    final payload = response.payload;
    if (payload != null &&
        payload.isNotEmpty &&
        (actionId == _voiceCallAcceptActionId ||
            actionId == _voiceCallRejectActionId)) {
      await _handleVoiceCallNotificationAction(
        actionId: actionId ?? '',
        payload: payload,
      );
      return;
    }
    final input = (response.input ?? '').trim();
    if (input.isNotEmpty && payload != null && payload.isNotEmpty) {
      await _handleReplyAction(payload: payload, replyText: input);
      return;
    }
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
      } else if (IncomingCallPayload.isIncomingAudioCall(data)) {
        _onVoiceCallTap?.call(data);
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

    final endMap = Map<String, String>.from(
      d.map((k, v) => MapEntry(k, '$v')),
    );
    if (IncomingCallPayload.isVoiceCallEnded(endMap)) {
      final callId = (d['callId'] ?? '').trim();
      if (callId.isNotEmpty) {
        await IncomingCallKitCoordinator.dismissForCallId(callId);
        await cancelIncomingCallNotification(callId);
      }
      return;
    }

    final stringData = Map<String, String>.from(
      d.map((k, v) => MapEntry(k, '$v')),
    );
    if (IncomingCallPayload.isIncomingAudioCall(stringData)) {
      if (Get.isRegistered<AuthRepository>()) {
        final active = Get.find<AuthRepository>().activeAccountId;
        if (active != null && active.trim().isNotEmpty) {
          stringData['accountId'] = active.trim();
        }
      }
      await IncomingCallKitCoordinator.presentFromFcmData(stringData);
      return;
    }

    if (d['type'] == 'new_chat_message') {
      final messageId = (d['messageId'] ?? '').trim();
      final groupId = (d['groupId'] ?? '').trim();
      final isGroupConversation =
          (d['isGroupConversation'] ?? '').trim().toLowerCase() == 'true' ||
          groupId.isNotEmpty;
      final conversationId =
          (isGroupConversation ? groupId : (d['fromUserId'] ?? d['peerId'] ?? ''))
              .trim();
      if (messageId.isEmpty || conversationId.isEmpty) return;
      final title = _chatSenderTitle(d);
      final body = _chatPreviewText(d, fallback: message.notification?.body);
      final payloadMap = d.map((k, v) => MapEntry(k, '$v'));
      payloadMap['conversationId'] = conversationId;
      payloadMap['chatType'] = isGroupConversation ? 'group' : 'personal';
      payloadMap['receiverId'] = isGroupConversation
          ? ''
          : (d['fromUserId'] ?? d['peerId'] ?? '').trim();
      payloadMap['groupId'] = groupId;
      payloadMap['notificationId'] = messageId;
      if (Get.isRegistered<AuthRepository>()) {
        final active = Get.find<AuthRepository>().activeAccountId;
        if (active != null && active.trim().isNotEmpty) {
          payloadMap['accountId'] = active.trim();
        }
      }
      await _plugin.show(
        id: _idForChatPeer(conversationId),
        title: title,
        body: body,
        notificationDetails: _chatChannelDetails(
          senderName: title,
          preview: body,
          isGroupConversation: isGroupConversation,
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
    final isGroupConversation =
        (data['isGroupConversation'] ?? '').toString().trim().toLowerCase() ==
            'true' ||
        (data['groupId'] ?? '').toString().trim().isNotEmpty;
    if (isGroupConversation) {
      final groupName = (data['groupName'] ?? data['conversationName'] ?? '')
          .toString()
          .trim();
      if (groupName.isNotEmpty) return groupName;
      return 'Group message';
    }
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
    final isGroupConversation =
        (data['isGroupConversation'] ?? '').toString().trim().toLowerCase() ==
            'true' ||
        (data['groupId'] ?? '').toString().trim().isNotEmpty;
    if (isGroupConversation && body.isNotEmpty) {
      final sender = (data['fromName'] ?? data['fromEmail'] ?? '')
          .toString()
          .trim();
      if (sender.isNotEmpty) return '$sender: $body';
    }
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
      final resolved = _resolveReplyContext(data);
      final peerId = resolved.peerId;
      final isGroupConversation = resolved.isGroupConversation;
      if (kDebugMode) {
        debugPrint(
          '[local notif] quick reply action '
          'isGroup=$isGroupConversation peerId="$peerId" '
          'conversationId="${resolved.conversationId}" '
          'payloadType="${data['type'] ?? ''}"',
        );
      }
      if (peerId.isEmpty) {
        await _showReplyStatusNotification(success: false, message: 'Reply failed');
        return;
      }
      final text = replyText.trim();
      if (text.isEmpty) {
        await _showReplyStatusNotification(success: false, message: 'Reply failed');
        return;
      }
      final sent = await _sendQuickReply(
        peerId: peerId,
        body: text,
        isGroupConversation: isGroupConversation,
        accountId: (data['accountId'] ?? '').trim(),
      );
      if (!sent) {
        await _showReplyStatusNotification(success: false, message: 'Reply failed. Try again');
        return;
      }
      await clearChatNotificationsForPeer((resolved.conversationId).trim().isNotEmpty
          ? resolved.conversationId
          : peerId);
      await _showReplyStatusNotification(success: true, message: 'Reply sent');
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
    required bool isGroupConversation,
    required String accountId,
  }) async {
    try {
      if (Get.isRegistered<ChatRepository>()) {
        if (isGroupConversation) {
          await Get.find<ChatRepository>().sendGroupMessage(
            groupId: peerId,
            body: body,
            clientId: _quickReplyClientId(),
          );
        } else {
          await Get.find<ChatRepository>().sendChatMessage(
            peerId: peerId,
            body: body,
            clientId: _quickReplyClientId(),
          );
        }
        return true;
      }
      return await _sendQuickReplyViaRest(
        peerId: peerId,
        body: body,
        isGroupConversation: isGroupConversation,
        accountId: accountId,
      );
    } catch (_) {
      return false;
    }
  }

  static String _quickReplyClientId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    return 'notif-$ms';
  }

  static ({String peerId, String conversationId, bool isGroupConversation}) _resolveReplyContext(
    Map<String, String> data,
  ) {
    final chatType = (data['chatType'] ?? data['conversationType'] ?? '')
        .trim()
        .toLowerCase();
    final explicitGroup = chatType == 'group';
    final explicitPersonal = chatType == 'personal' || chatType == 'direct';
    final groupId = (data['groupId'] ?? '').trim();
    final conversationId = (data['conversationId'] ?? '').trim();
    final isGroupConversation = explicitGroup ||
        (!explicitPersonal &&
            ((data['isGroupConversation'] ?? '').trim().toLowerCase() == 'true' ||
                groupId.isNotEmpty));
    final peerId = isGroupConversation
        ? (groupId.isNotEmpty ? groupId : conversationId)
        : ((data['receiverId'] ??
                    data['fromUserId'] ??
                    data['senderId'] ??
                    data['peerId'] ??
                    conversationId)
                .trim());
    return (
      peerId: peerId.trim(),
      conversationId: conversationId,
      isGroupConversation: isGroupConversation,
    );
  }

  static Future<bool> _sendQuickReplyViaRest({
    required String peerId,
    required String body,
    required bool isGroupConversation,
    required String accountId,
  }) async {
    final storage = await SessionStorage.create();
    final session = accountId.isNotEmpty
        ? await storage.loadByAccountId(accountId)
        : await storage.load();
    if (session == null || session.token.trim().isEmpty) return false;
    final dio = createDio();
    final endpoint = isGroupConversation
        ? ApiEndpoints.chatGroupMessages
        : ApiEndpoints.chatMessages;
    final res = await dio.post<dynamic>(
      endpoint,
      data: {
        ...(isGroupConversation
            ? <String, dynamic>{'groupId': peerId}
            : <String, dynamic>{'peerId': peerId}),
        'body': body,
        'clientId': _quickReplyClientId(),
      },
      options: Options(
        headers: {'Authorization': 'Bearer ${session.token.trim()}'},
      ),
    );
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      if (kDebugMode) {
        debugPrint(
          '[local notif] quick reply REST failed code=$code '
          'isGroup=$isGroupConversation peerId=$peerId bodyLen=${body.length} '
          'resp=${res.data}',
        );
      }
      return false;
    }
    final raw = res.data;
    final ok = raw is Map && raw['message'] is Map;
    if (!ok && kDebugMode) {
      debugPrint(
        '[local notif] quick reply REST invalid response '
        'isGroup=$isGroupConversation peerId=$peerId resp=$raw',
      );
    }
    return ok;
  }

  static int _idForIncomingCall(String callId) {
    final id = callId.trim();
    if (id.isEmpty) return 0xC0110001;
    return id.hashCode & 0x7fffffff;
  }

  /// Dismiss ringing UI on device when the remote party ends the call.
  static Future<void> cancelIncomingCallNotification(String callId) async {
    if (!_initialized) return;
    final id = callId.trim();
    if (id.isEmpty) return;
    await _plugin.cancel(id: _idForIncomingCall(id));
  }

  static Future<void> _handleVoiceCallNotificationAction({
    required String actionId,
    required String payload,
  }) async {
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map) return;
      final data = Map<String, String>.from(
        raw.map((k, v) => MapEntry(k.toString(), '${v ?? ''}')),
      );
      if (!IncomingCallPayload.isIncomingAudioCall(data)) return;
      final callId = (data['callId'] ?? '').trim();
      await cancelIncomingCallNotification(callId);
      if (actionId == _voiceCallRejectActionId) {
        await _rejectVoiceCallViaRest(
          callId: callId,
          accountId: (data['accountId'] ?? '').trim(),
        );
        return;
      }
      if (actionId == _voiceCallAcceptActionId) {
        data['_autoAccept'] = '1';
        _onVoiceCallTap?.call(data);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[local notif] voice call action failed: $e');
      }
    }
  }

  static Future<void> _rejectVoiceCallViaRest({
    required String callId,
    required String accountId,
  }) async {
    if (callId.isEmpty) return;
    final storage = await SessionStorage.create();
    final session = accountId.isNotEmpty
        ? await storage.loadByAccountId(accountId)
        : await storage.load();
    if (session == null || session.token.trim().isEmpty) return;
    final dio = createDio();
    try {
      await dio.post<dynamic>(
        ApiEndpoints.voiceCallReject,
        data: {'callId': callId},
        options: Options(
          headers: {'Authorization': 'Bearer ${session.token.trim()}'},
        ),
      );
    } catch (_) {
      /* ignore */
    }
  }

  static Future<void> _showReplyStatusNotification({
    required bool success,
    required String message,
  }) async {
    if (!_initialized) return;
    await _plugin.show(
      id: _chatReplyStatusNotificationId,
      title: success ? 'Sealpost' : 'Sealpost',
      body: message,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          kChatNotificationChannelId,
          'Chat messages',
          channelDescription: 'Chat conversation notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
