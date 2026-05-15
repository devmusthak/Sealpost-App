import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../../core/call/agora_call_service.dart';
import '../../../core/call/incoming_call_kit_coordinator.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/push/local_notification_service.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_repository.dart';

/// Chat home: most recent conversation first (matches server `listContacts` ordering).
int _compareChatContactsForHome(ChatContact a, ChatContact b) {
  final ta = a.lastMessageAt;
  final tb = b.lastMessageAt;
  if (ta != null || tb != null) {
    if (ta == null) return 1;
    if (tb == null) return -1;
    final byTime = tb.compareTo(ta);
    if (byTime != 0) return byTime;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

class ChatController extends GetxController {
  final contacts = <ChatContact>[].obs;
  final typingPeerIds = <String>{}.obs;
  final isLoading = false.obs;
  final error = RxnString();

  late final ChatRepository _repo = Get.find<ChatRepository>();
  io.Socket? _socket;
  String? _openConversationPeerId;
  bool _openConversationIsGroup = false;
  final Map<String, Timer> _typingTimers = {};
  /// Active socket for chat thread listeners (same connection as contacts).
  io.Socket? get chatSocket => _socket;

  /// Peer id for the open 1:1 thread, if any (used to suppress duplicate chat push banners).
  String? get openConversationPeerId => _openConversationPeerId;
  bool isPeerTyping(String peerId) => typingPeerIds.contains(peerId);

  @override
  void onInit() {
    super.onInit();
    unawaited(refreshContacts());
    _connectSocket();
  }

  @override
  void onClose() {
    _openConversationPeerId = null;
    _openConversationIsGroup = false;
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    typingPeerIds.clear();
    _socket?.dispose();
    _socket = null;
    super.onClose();
  }

  /// Lets the server join a conversation room (re-sent on reconnect).
  /// For group chats, [conversationId] is the `groupId`.
  void setConversationOpenPeer(
    String? conversationId, {
    bool isGroupConversation = false,
  }) {
    _openConversationPeerId =
        conversationId != null && conversationId.trim().isNotEmpty
        ? conversationId.trim()
        : null;
    _openConversationIsGroup =
        _openConversationPeerId != null && isGroupConversation;
    if (_openConversationPeerId == null) {
      _socket?.emit('chat:conversation:close');
    } else {
      _socket?.emit(
        'chat:conversation:open',
        isGroupConversation
            ? {'groupId': _openConversationPeerId}
            : {'peerId': _openConversationPeerId},
      );
    }
  }

  Future<void> refreshContacts() async {
    _ensureSocketConnected();
    isLoading.value = true;
    error.value = null;
    try {
      final list = await _repo.fetchContacts();
      list.sort(_compareChatContactsForHome);
      contacts.assignAll(list);
    } catch (e) {
      error.value = '$e';
    } finally {
      isLoading.value = false;
    }
  }

  void _ensureSocketConnected() {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) return;
    if (_socket == null) {
      _connectSocket();
      return;
    }
    if (_socket!.disconnected) {
      _socket!.connect();
    }
  }

  void _connectSocket() {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) return;
    if (_socket != null) return;
    _socket = io.io(
      ApiEndpoints.socketOrigin,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .setTimeout(20000)
          .build(),
    );
    _socket!.on('chat:contacts:update', (_) {
      unawaited(refreshContacts());
    });
    _socket!.on('chat:typing', _onTyping);
    _socket!.on('chat:voice:recording', _onTyping);
    _socket!.on('voice_recording', _onTyping);
    _socket!.on('call:invite', _onIncomingCallInvite);
    _socket!.on('call_ringing', _onIncomingCallInvite);
    _socket!.on('call_accepted', (d) => _pipeCallEvent('call_accepted', d));
    _socket!.on('call_rejected', (d) => _pipeCallEvent('call_rejected', d));
    _socket!.on('call_ended', (d) => _pipeCallEvent('call_ended', d));
    _socket!.on('call_missed', (d) => _pipeCallEvent('call_missed', d));
    _socket!.on('call_failed', (d) => _pipeCallEvent('call_failed', d));
    _socket!.on('call_initiated', (d) => _pipeCallEvent('call_initiated', d));
    _socket!.on('call_remote_ringing', (d) => _pipeCallEvent('call_remote_ringing', d));
    _socket!.onConnect((_) {
      final peer = _openConversationPeerId;
      if (peer != null && peer.isNotEmpty) {
        _socket!.emit(
          'chat:conversation:open',
          _openConversationIsGroup ? {'groupId': peer} : {'peerId': peer},
        );
      }
    });
  }

  void _onTyping(dynamic data) {
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    final peerId = '${map['fromUserId'] ?? map['peerId'] ?? ''}'.trim();
    if (peerId.isEmpty) return;
    if (peerId == (Get.find<AuthRepository>().userId ?? '')) return;

    final typing = map['typing'] == true;
    _typingTimers[peerId]?.cancel();
    if (!typing) {
      typingPeerIds.remove(peerId);
      _typingTimers.remove(peerId);
      return;
    }

    typingPeerIds.add(peerId);
    _typingTimers[peerId] = Timer(const Duration(seconds: 6), () {
      typingPeerIds.remove(peerId);
      _typingTimers.remove(peerId);
    });
  }

  void _pipeCallEvent(String eventName, dynamic data) {
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    if (eventName == 'call_ended' ||
        eventName == 'call_missed' ||
        eventName == 'call_rejected' ||
        eventName == 'call_failed') {
      final id = '${map['callId'] ?? ''}'.trim();
      if (id.isNotEmpty) {
        unawaited(IncomingCallKitCoordinator.dismissForCallId(id));
        unawaited(LocalNotificationService.cancelIncomingCallNotification(id));
        if (Platform.isAndroid) {
          IncomingCallKitCoordinator.androidFinalizeVoiceCallDismissal(id);
        }
      }
    }
    if (Get.isRegistered<AgoraCallService>()) {
      Get.find<AgoraCallService>().emitCallSignal(eventName, map);
    }
  }

  void _onIncomingCallInvite(dynamic data) {
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    final svc = Get.find<AgoraCallService>();
    final callId = '${map['callId'] ?? ''}'.trim();
    if (callId.isNotEmpty && !svc.claimCallUi(callId)) {
      return;
    }
    _pipeCallEvent('call_ringing', map);
    unawaited(() async {
      try {
        if (Platform.isIOS || Platform.isAndroid) {
          final callTypeRaw =
              '${map['callType'] ?? map['mediaType'] ?? 'audio'}'.trim().toLowerCase();
          final isVideo = callTypeRaw == 'video';
          final payload = <String, String>{
            ...map.map((k, v) => MapEntry(k.toString(), '$v')),
            'type': isVideo ? 'incoming_video_call' : 'incoming_voice_call',
            'notificationType': 'incoming_call',
            'callType': isVideo ? 'video' : 'audio',
          };
          try {
            await IncomingCallKitCoordinator.presentFromFcmData(payload);
          } finally {
            // Socket path claims UI to dedupe; native incoming UI until Accept.
            // Release so notification/CallKit Accept can claim and open in-app call UI.
            if (callId.isNotEmpty) {
              svc.releaseCallUi(callId);
            }
          }
          return;
        }
      } catch (_) {
        if (callId.isNotEmpty) {
          svc.releaseCallUi(callId);
        } else {
          svc.releaseCallUi();
        }
      }
    }());
  }
}
