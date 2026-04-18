import 'dart:async';

import 'package:get/get.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../../core/network/api_endpoints.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_repository.dart';

class ChatController extends GetxController {
  final contacts = <ChatContact>[].obs;
  final isLoading = false.obs;
  final error = RxnString();

  late final ChatRepository _repo = Get.find<ChatRepository>();
  io.Socket? _socket;
  String? _openConversationPeerId;

  /// Active socket for chat thread listeners (same connection as contacts).
  io.Socket? get chatSocket => _socket;

  @override
  void onInit() {
    super.onInit();
    unawaited(refreshContacts());
    _connectSocket();
  }

  @override
  void onClose() {
    _openConversationPeerId = null;
    _socket?.dispose();
    _socket = null;
    super.onClose();
  }

  /// Lets the server join a conversation room (re-sent on reconnect).
  void setConversationOpenPeer(String? peerId) {
    _openConversationPeerId =
        peerId != null && peerId.trim().isNotEmpty ? peerId.trim() : null;
    if (_openConversationPeerId == null) {
      _socket?.emit('chat:conversation:close');
    } else {
      _socket?.emit('chat:conversation:open', {'peerId': _openConversationPeerId});
    }
  }

  Future<void> refreshContacts() async {
    isLoading.value = true;
    error.value = null;
    try {
      final list = await _repo.fetchContacts();
      contacts.assignAll(list);
    } catch (e) {
      error.value = '$e';
    } finally {
      isLoading.value = false;
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
    _socket!.onConnect((_) {
      final peer = _openConversationPeerId;
      if (peer != null && peer.isNotEmpty) {
        _socket!.emit('chat:conversation:open', {'peerId': peer});
      }
    });
  }
}
