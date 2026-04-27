import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../../core/call/agora_call_service.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_repository.dart';
import '../view/agora_audio_call_screen.dart';

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
  bool _incomingDialogVisible = false;

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
    if (_socket == null || _socket!.disconnected) {
      _connectSocket();
    }
  }

  void _connectSocket() {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) return;
    _socket?.dispose();
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
    _socket!.on('call:invite', _onIncomingCallInvite);
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

  void _onIncomingCallInvite(dynamic data) {
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    if (_incomingDialogVisible) return;
    final fromName = '${map['fromName'] ?? 'Incoming caller'}'.trim();

    _incomingDialogVisible = true;
    Get.dialog<void>(
      AlertDialog(
        title: const Text('Incoming audio call'),
        content: Text('$fromName is calling you.'),
        actions: [
          TextButton(
            onPressed: () {
              _incomingDialogVisible = false;
              if (Get.isDialogOpen == true) {
                Get.back<void>();
              }
            },
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () async {
              _incomingDialogVisible = false;
              if (Get.isDialogOpen == true) {
                Get.back<void>();
              }
              try {
                final session = Get.find<AgoraCallService>()
                    .sessionFromInvitePayload(map);
                await Get.to<void>(
                  () => AgoraAudioCallScreen(
                    appId: Get.find<AgoraCallService>().appId,
                    peerName: fromName.isEmpty ? 'Incoming caller' : fromName,
                    session: session,
                  ),
                );
              } catch (_) {
                /* ignore invalid incoming payload */
              }
            },
            child: const Text('Accept'),
          ),
        ],
      ),
      barrierDismissible: false,
    ).whenComplete(() {
      _incomingDialogVisible = false;
    });
  }
}
