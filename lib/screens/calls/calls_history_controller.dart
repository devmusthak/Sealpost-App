import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../core/call/agora_call_service.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/calls/call_history_entry.dart';
import '../../data/calls/calls_repository.dart';
import '../chat/controller/chat_controller.dart';

/// Keeps call history in sync (API + local cache) and refreshes on call / chat events.
class CallsHistoryController extends GetxService {
  static const _prefsKeyPrefix = 'sealpost_call_history_json_v1_';

  final rows = <CallHistoryDisplayRow>[].obs;
  final isLoading = false.obs;
  final error = RxnString();

  StreamSubscription<Map<String, dynamic>>? _callEventsSub;
  Timer? _debounceRefresh;
  Timer? _followUpRefresh;
  Timer? _contactsDebounce;
  Timer? _socketBindRetry;
  io.Socket? _socketBound;
  void Function(dynamic)? _chatMessageHandler;
  void Function(dynamic)? _contactsUpdateHandler;
  bool _stopped = false;

  @override
  void onInit() {
    super.onInit();
    unawaited(_bootstrap());
  }

  @override
  void onClose() {
    _stopped = true;
    _debounceRefresh?.cancel();
    _followUpRefresh?.cancel();
    _contactsDebounce?.cancel();
    _socketBindRetry?.cancel();
    _unbindChatMessage();
    _callEventsSub?.cancel();
    _callEventsSub = null;
    super.onClose();
  }

  Future<void> _bootstrap() async {
    await _loadFromDisk();
    _subscribeCallEvents();
    // Eagerly create chat socket (lazyPut) so call-history listeners attach before user opens Chat.
    try {
      Get.find<ChatController>();
    } catch (_) {
      /* not registered yet — retry via _tryBindChatMessageListener */
    }
    _tryBindChatMessageListener();
    await refresh(silent: rows.isNotEmpty);
  }

  void _subscribeCallEvents() {
    if (!Get.isRegistered<AgoraCallService>()) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (!_stopped) _subscribeCallEvents();
      });
      return;
    }
    if (_callEventsSub != null) return;
    _callEventsSub = Get.find<AgoraCallService>().callEvents.listen((map) {
      final ev = '${map['_event'] ?? ''}'.trim();
      if (ev == 'call_ended' ||
          ev == 'call_missed' ||
          ev == 'call_rejected' ||
          ev == 'call_failed') {
        _scheduleRefresh();
      }
    });
  }

  void _scheduleRefresh() {
    if (_stopped) return;
    _debounceRefresh?.cancel();
    _followUpRefresh?.cancel();
    _debounceRefresh = Timer(const Duration(milliseconds: 400), () {
      if (_stopped) return;
      unawaited(refresh(silent: true));
      // Server may write CallHistory slightly after socket events; second pull catches it.
      _followUpRefresh = Timer(const Duration(milliseconds: 2200), () {
        if (_stopped) return;
        unawaited(refresh(silent: true));
      });
    });
  }

  String _cacheKey() {
    final id = (Get.find<AuthRepository>().userId ?? '').trim();
    return '$_prefsKeyPrefix${id.isEmpty ? 'anon' : id}';
  }

  Future<void> _loadFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey());
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = decoded
          .whereType<Map>()
          .map((e) => CallHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.callId.isNotEmpty && e.peerId.isNotEmpty)
          .toList();
      if (items.isEmpty) return;
      rows.assignAll(groupCallHistoryRows(items));
      rows.refresh();
    } catch (_) {
      /* ignore corrupt cache */
    }
  }

  Future<void> _saveToDisk(List<CallHistoryEntry> flat) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(flat.map((e) => e.toJson()).toList());
      await prefs.setString(_cacheKey(), encoded);
    } catch (_) {
      /* non-fatal */
    }
  }

  void _tryBindChatMessageListener() {
    ChatController? chat;
    try {
      chat = Get.find<ChatController>();
    } catch (_) {
      _socketBindRetry?.cancel();
      _socketBindRetry = Timer(const Duration(milliseconds: 600), _tryBindChatMessageListener);
      return;
    }
    final s = chat.chatSocket;
    if (s == null) {
      _unbindChatMessage();
      _socketBindRetry?.cancel();
      _socketBindRetry = Timer(const Duration(milliseconds: 600), _tryBindChatMessageListener);
      return;
    }
    _socketBindRetry?.cancel();
    if (_socketBound == s &&
        _chatMessageHandler != null &&
        _contactsUpdateHandler != null) {
      return;
    }
    _unbindChatMessage();
    _socketBound = s;
    _chatMessageHandler = (dynamic data) {
      if (!_isCallEventChatPayload(data)) return;
      _scheduleRefresh();
    };
    _contactsUpdateHandler = (_) {
      if (_stopped) return;
      _contactsDebounce?.cancel();
      _contactsDebounce = Timer(const Duration(milliseconds: 1800), () {
        if (_stopped) return;
        unawaited(refresh(silent: true));
      });
    };
    s.on('chat:message', _chatMessageHandler!);
    s.on('chat:contacts:update', _contactsUpdateHandler!);
  }

  void _unbindChatMessage() {
    final h = _chatMessageHandler;
    final cu = _contactsUpdateHandler;
    final sock = _socketBound;
    if (sock != null) {
      if (h != null) sock.off('chat:message', h);
      if (cu != null) sock.off('chat:contacts:update', cu);
    }
    _socketBound = null;
    _chatMessageHandler = null;
    _contactsUpdateHandler = null;
  }

  static bool _isCallEventChatPayload(dynamic data) {
    final m = data is Map ? Map<String, dynamic>.from(data) : null;
    if (m == null) return false;
    final msg = m['message'];
    if (msg is! Map) return false;
    final body = '${msg['body'] ?? ''}'.trim();
    if (body.isEmpty || !body.startsWith('{')) return false;
    try {
      final inner = jsonDecode(body);
      if (inner is! Map) return false;
      return '${inner['t'] ?? ''}'.trim() == 'call_event';
    } catch (_) {
      return false;
    }
  }

  /// Refetch from server; persists flat list for offline / cold start (WhatsApp-style cache).
  Future<void> refresh({bool silent = false}) async {
    if (!Get.isRegistered<CallsRepository>()) {
      isLoading.value = false;
      error.value = 'Calls are not available.';
      return;
    }
    if (!silent && rows.isEmpty) {
      isLoading.value = true;
    }
    error.value = null;
    try {
      final raw = await Get.find<CallsRepository>().fetchHistory(limit: 80);
      await _saveToDisk(raw);
      rows.assignAll(groupCallHistoryRows(raw));
      rows.refresh();
    } catch (e) {
      error.value = '$e';
      if (rows.isEmpty) {
        rows.clear();
      }
    } finally {
      isLoading.value = false;
    }
    _tryBindChatMessageListener();
  }
}
