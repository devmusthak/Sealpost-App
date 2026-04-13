import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../../core/network/api_endpoints.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/mail/mail_list_item.dart';
import '../../../data/mail/mail_repository.dart';
import '../../login/view/login_view.dart';

/// API `folder` query values (must match server / IMAP mailbox names).
abstract final class HomeFolder {
  static const String inbox = 'INBOX';
  static const String sent = 'Sent';
  static const String spam = 'Spam';
  static const String trash = 'Trash';
}

/// Home: mail list by folder + Socket.IO for new mail in INBOX.
class HomeController extends GetxController {
  final mails = <MailListItem>[].obs;
  final isLoading = true.obs;
  final RxnString errorMessage = RxnString();

  /// Currently selected mailbox (see [HomeFolder]).
  final selectedFolder = HomeFolder.inbox.obs;

  late final MailRepository _mailRepo = Get.find<MailRepository>();

  io.Socket? _socket;

  @override
  void onInit() {
    super.onInit();
    _loadMails();
    _connectSocket();
  }

  @override
  void onClose() {
    _socket?.dispose();
    _socket = null;
    super.onClose();
  }

  Future<void> refreshInbox() => _loadMails();

  /// Uppercase section title under the search bar (e.g. INBOX, SENT).
  String get folderSectionLabel {
    switch (selectedFolder.value) {
      case HomeFolder.inbox:
        return 'INBOX';
      case HomeFolder.sent:
        return 'SENT';
      case HomeFolder.spam:
        return 'SPAM';
      case HomeFolder.trash:
        return 'TRASH';
      default:
        return selectedFolder.value.toUpperCase();
    }
  }

  Future<void> selectFolder(String folder) async {
    if (selectedFolder.value == folder) return;
    selectedFolder.value = folder;
    await _loadMails();
  }

  Future<void> logout() async {
    _socket?.dispose();
    _socket = null;
    await Get.find<AuthRepository>().logout();
    Get.offAll(() => const LoginScreen());
  }

  /// Server-side search in the current [selectedFolder] (subject, body, addresses).
  Future<List<MailListItem>> searchMailsInFolder(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final result = await _mailRepo.fetchMails(
      folder: selectedFolder.value,
      limit: 50,
      search: q,
    );
    return result.items;
  }

  Future<void> _loadMails() async {
    isLoading.value = true;
    errorMessage.value = null;
    try {
      final result = await _mailRepo.fetchMails(folder: selectedFolder.value);
      mails.assignAll(result.items);
    } on DioException catch (e) {
      errorMessage.value =
          e.response?.data is Map && (e.response!.data as Map)['message'] != null
              ? '${(e.response!.data as Map)['message']}'
              : (e.message ?? 'Could not load inbox');
    } catch (e) {
      errorMessage.value = '$e';
    } finally {
      isLoading.value = false;
    }
  }

  void _connectSocket() {
    final auth = Get.find<AuthRepository>().session;
    final token = auth?.token;
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

    _socket!.on('mail:new', (data) {
      if (selectedFolder.value != HomeFolder.inbox) return;
      if (data is! Map) return;
      final raw = data['mail'];
      if (raw is! Map) return;
      final map = Map<String, dynamic>.from(raw);
      final item = MailListItem.fromJson(map);
      if (item.id.isEmpty) return;
      if (mails.any((m) => m.id == item.id)) return;
      mails.insert(0, item);
    });

    _socket!.onConnect((_) {
      debugPrint('[socket] connected');
    });
    _socket!.onConnectError((dynamic err) {
      debugPrint('[socket] connect_error: $err');
    });
  }
}
