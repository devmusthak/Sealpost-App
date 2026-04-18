import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;

import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_message_dto.dart';
import '../../../data/chat/chat_repository.dart';
import '../../../data/chat/chat_thread_local_store.dart';
import '../../../theme/app_theme.dart';
import '../controller/chat_controller.dart';

enum OutboundDelivery {
  sending,
  sent,
  delivered,
  seen,
  failed,
}

class _UiMsg {
  const _UiMsg({
    required this.id,
    required this.clientId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.outbound,
    this.replyTo,
    this.reactions = const [],
  });

  final String id;
  final String clientId;
  final String senderId;
  final String body;
  final DateTime createdAt;
  final OutboundDelivery? outbound;
  final ChatReplyQuote? replyTo;
  final List<ChatReactionEntry> reactions;

  _UiMsg copyWith({
    String? id,
    String? senderId,
    String? body,
    DateTime? createdAt,
    OutboundDelivery? outbound,
    ChatReplyQuote? replyTo,
    List<ChatReactionEntry>? reactions,
  }) {
    return _UiMsg(
      id: id ?? this.id,
      clientId: clientId,
      senderId: senderId ?? this.senderId,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      outbound: outbound ?? this.outbound,
      replyTo: replyTo ?? this.replyTo,
      reactions: reactions ?? this.reactions,
    );
  }

  /// Snapshot for restoring when re-opening the thread (no flicker).
  _UiMsg clone() {
    return _UiMsg(
      id: id,
      clientId: clientId,
      senderId: senderId,
      body: body,
      createdAt: createdAt,
      outbound: outbound,
      replyTo: replyTo,
      reactions: List<ChatReactionEntry>.from(reactions),
    );
  }
}

/// Last conversation snapshot per peer (memory only).
class _ChatThreadMemoryCache {
  _ChatThreadMemoryCache._();
  static final _ChatThreadMemoryCache instance = _ChatThreadMemoryCache._();

  final Map<String, ({List<_UiMsg> messages, Set<String> serverIds})> _map = {};

  void save(String peerId, List<_UiMsg> messages, Set<String> serverIds) {
    if (peerId.isEmpty) return;
    _map[peerId] = (
      messages: messages.map((m) => m.clone()).toList(),
      serverIds: Set<String>.from(serverIds),
    );
  }

  ({List<_UiMsg> messages, Set<String> serverIds})? peek(String peerId) {
    if (peerId.isEmpty) return null;
    final e = _map[peerId];
    if (e == null) return null;
    return (
      messages: e.messages.map((m) => m.clone()).toList(),
      serverIds: Set<String>.from(e.serverIds),
    );
  }
}

/// One-to-one chat: optimistic send, socket delivery, typing, read receipts.
class ChatThreadScreen extends StatefulWidget {
  const ChatThreadScreen({super.key, required this.contact});

  final ChatContact contact;

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_UiMsg> _messages = [];
  final Set<String> _serverIds = {};
  OverlayEntry? _reactionOverlayEntry;

  late final ChatRepository _repo = Get.find<ChatRepository>();
  String _myId = '';

  bool _viewingOlderMessages = false;
  bool _peerTyping = false;
  Timer? _peerTypingClear;

  Timer? _typingEmitDebounce;
  Timer? _typingStopTimer;

  /// Message user is replying to (swipe); cleared after send or dismiss.
  _UiMsg? _replyTarget;

  /// Scroll-to-quote: one [GlobalKey] per loaded message id.
  final Map<String, GlobalKey> _messageAnchorKeys = {};

  /// First server history fetch finished (success or error).
  bool _initialHistorySyncDone = false;

  String? _historyError;
  final List<ChatMessageDto> _pendingDuringHistory = [];

  /// Upgrades single-tick when peer comes online (socket or contacts presence).
  Worker? _contactsEver;

  @override
  void initState() {
    super.initState();
    _myId = Get.find<AuthRepository>().userId?.trim() ?? '';
    final cached = _ChatThreadMemoryCache.instance.peek(widget.contact.id);
    if (cached != null) {
      _messages.addAll(cached.messages);
      _serverIds.addAll(cached.serverIds);
    }
    _scroll.addListener(_onScroll);
    _input.addListener(_onInputChanged);
    if (Get.isRegistered<ChatController>()) {
      _contactsEver = ever<List<ChatContact>>(
        Get.find<ChatController>().contacts,
        (_) => _maybeUpgradeDeliveryFromPeerPresence(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(Get.find<ChatController>().refreshContacts());
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_startThread());
      }
    });
  }

  /// Disk cache (cold start) → socket → background sync. No blocking loader.
  Future<void> _startThread() async {
    if (_messages.isEmpty) {
      final disk = await ChatThreadLocalStore.load(widget.contact.id);
      if (!mounted) return;
      if (disk != null && disk.rows.isNotEmpty) {
        setState(() {
          _messages
            ..clear()
            ..addAll(disk.rows.map(_fromPersistedRow));
          _serverIds
            ..clear()
            ..addAll(disk.serverIds);
        });
      }
    }
    _bindSocket();
    unawaited(_syncHistoryWithServer());
  }

  Map<String, dynamic> _toPersistedRow(_UiMsg m) {
    return {
      'id': m.id,
      'clientId': m.clientId,
      'senderId': m.senderId,
      'body': m.body,
      'createdAt': m.createdAt.toUtc().toIso8601String(),
      'outbound': m.outbound?.name,
      if (m.replyTo != null) 'replyTo': m.replyTo!.toJson(),
      if (m.reactions.isNotEmpty)
        'reactions': m.reactions.map((e) => e.toJson()).toList(),
    };
  }

  _UiMsg _fromPersistedRow(Map<String, dynamic> e) {
    OutboundDelivery? ob;
    final oRaw = e['outbound'];
    if (oRaw != null && '$oRaw'.isNotEmpty) {
      try {
        ob = OutboundDelivery.values.byName('$oRaw');
      } catch (_) {
        ob = null;
      }
    }
    final created = DateTime.tryParse('${e['createdAt'] ?? ''}') ?? DateTime.now();
    final rtRaw = e['replyTo'];
    ChatReplyQuote? replyTo;
    if (rtRaw is Map) {
      replyTo = ChatReplyQuote.fromJson(Map<String, dynamic>.from(rtRaw));
    }
    final rxRaw = e['reactions'];
    final reactions = <ChatReactionEntry>[];
    if (rxRaw is List) {
      for (final x in rxRaw) {
        if (x is Map) {
          final r = ChatReactionEntry.fromJson(Map<String, dynamic>.from(x));
          if (r != null) reactions.add(r);
        }
      }
    }
    return _UiMsg(
      id: '${e['id'] ?? ''}',
      clientId: '${e['clientId'] ?? ''}',
      senderId: '${e['senderId'] ?? ''}',
      body: '${e['body'] ?? ''}',
      createdAt: created.isUtc ? created.toLocal() : created,
      outbound: ob,
      replyTo: replyTo,
      reactions: reactions,
    );
  }

  static String _oneLinePreview(String body) {
    final t = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= 120) return t;
    return '${t.substring(0, 119)}…';
  }

  ChatReplyQuote? _replyQuoteFromTarget(_UiMsg m) {
    if (m.id.startsWith('local:')) return null;
    return ChatReplyQuote(
      messageId: m.id,
      senderId: m.senderId,
      bodyPreview: _oneLinePreview(m.body),
    );
  }

  void _syncMessageAnchorKeys() {
    final valid = _messages.map((m) => m.id).toSet();
    _messageAnchorKeys.removeWhere((id, _) => !valid.contains(id));
  }

  GlobalKey _anchorKeyForMessageId(String id) =>
      _messageAnchorKeys.putIfAbsent(id, () => GlobalKey());

  /// Match [raw] to a row in [_messages] (handles Mongo ObjectId case drift).
  String? _resolveQuoteTargetId(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    for (final m in _messages) {
      if (m.id == s) return m.id;
    }
    if (s.length == 24) {
      final sl = s.toLowerCase();
      for (final m in _messages) {
        if (m.id.length == 24 && m.id.toLowerCase() == sl) return m.id;
      }
    }
    return null;
  }

  /// [ListView.builder] does not keep off-screen items built, so [GlobalKey.currentContext]
  /// is often null for quoted messages. Scroll near the target first, then [ensureVisible].
  void _scrollToQuotedMessage(String targetId) {
    final resolved = _resolveQuoteTargetId(targetId);
    if (resolved == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'That message is not in this chat yet',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();

    var didRoughJump = false;

    void tick(int attempt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _messageAnchorKeys[resolved]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.12,
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutCubic,
          );
          return;
        }

        final mIdx = _messages.indexWhere((m) => m.id == resolved);
        if (mIdx < 0) return;

        if (!didRoughJump && _scroll.hasClients) {
          didRoughJump = true;
          final pos = _scroll.position;
          final min = pos.minScrollExtent;
          final max = pos.maxScrollExtent;
          final span = max - min;
          final len = _messages.length;
          // reverse: true — newest at [min], older toward [max]. Map index so oldest≈max.
          if (len > 1 && span > 1) {
            final t = mIdx / (len - 1);
            final guess = min + span * (1.0 - t);
            _scroll.jumpTo(guess.clamp(min, max));
          }
        }

        if (attempt < 28) {
          tick(attempt + 1);
        }
      });
    }

    tick(0);
  }

  void _bindSocket() {
    if (!Get.isRegistered<ChatController>()) return;
    final c = Get.find<ChatController>();
    c.setConversationOpenPeer(widget.contact.id);
    final s = c.chatSocket;
    if (s == null) return;
    s.on('chat:message', _onSocketMessage);
    s.on('chat:message:delivered', _onDelivered);
    s.on('chat:message:seen', _onSeen);
    s.on('chat:typing', _onTyping);
    s.on('chat:peer:delivery_ready', _onPeerDeliveryReady);
    s.on('chat:reaction', _onSocketReaction);
  }

  void _unbindSocket() {
    if (!Get.isRegistered<ChatController>()) return;
    final c = Get.find<ChatController>();
    c.setConversationOpenPeer(null);
    final s = c.chatSocket;
    s?.off('chat:message', _onSocketMessage);
    s?.off('chat:message:delivered', _onDelivered);
    s?.off('chat:message:seen', _onSeen);
    s?.off('chat:typing', _onTyping);
    s?.off('chat:peer:delivery_ready', _onPeerDeliveryReady);
    s?.off('chat:reaction', _onSocketReaction);
  }

  void _onSocketReaction(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    final mRaw = map?['message'];
    if (mRaw is! Map) return;
    final dto = ChatMessageDto.fromJson(Map<String, dynamic>.from(mRaw));
    if (!_involvesPeer(dto)) return;
    _applyReactionDto(dto);
  }

  void _applyReactionDto(ChatMessageDto dto) {
    if (!mounted) return;
    final i = _messages.indexWhere((m) => m.id == dto.id);
    if (i < 0) return;
    setState(() {
      _messages[i] = _messages[i].copyWith(reactions: dto.reactions);
    });
  }

  Future<void> _setMessageReaction(String messageId, String emoji) async {
    if (messageId.isEmpty || messageId.startsWith('local:')) return;
    try {
      final dto = await _repo.setChatMessageReaction(
        peerId: widget.contact.id,
        messageId: messageId,
        emoji: emoji,
      );
      _applyReactionDto(dto);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not update reaction',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _removeReactionOverlay() {
    _reactionOverlayEntry?.remove();
    _reactionOverlayEntry = null;
  }

  void _openQuickReactions(_UiMsg msg, GlobalKey anchorKey) {
    if (msg.id.startsWith('local:')) return;
    HapticFeedback.mediumImpact();
    final ctx = anchorKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;
    _removeReactionOverlay();
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (oc) => _MessageReactionOverlay(
        anchorRect: Rect.fromLTWH(topLeft.dx, topLeft.dy, size.width, size.height),
        onDismiss: () {
          entry.remove();
          if (_reactionOverlayEntry == entry) {
            _reactionOverlayEntry = null;
          }
        },
        onPickEmoji: (emoji) {
          _removeReactionOverlay();
          unawaited(_setMessageReaction(msg.id, emoji));
        },
        onOpenEmojiPicker: () {
          _removeReactionOverlay();
          _showReactionEmojiPickerSheet(
            onSelected: (emoji) => unawaited(_setMessageReaction(msg.id, emoji)),
          );
        },
      ),
    );
    _reactionOverlayEntry = entry;
    overlay.insert(entry);
  }

  void _showReactionEmojiPickerSheet({required ValueChanged<String> onSelected}) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _ChatThreadColors.composerBar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 280,
          child: EmojiPicker(
            onEmojiSelected: (_, emoji) {
              Navigator.pop(ctx);
              onSelected(emoji.emoji);
            },
            config: _chatThreadEmojiPickerConfig(),
          ),
        ),
      ),
    );
  }

  void _showReactionDetailsSheet(_UiMsg msg, ChatContact peer) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _ChatThreadColors.composerBar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ReactionDetailsSheet(
        msg: msg,
        myId: _myId,
        peerDisplayName:
            peer.name.trim().isNotEmpty ? peer.name.trim() : peer.email,
        onRemoveMine: () {
          Navigator.pop(ctx);
          unawaited(_setMessageReaction(msg.id, ''));
        },
        onPickEmoji: () {
          Navigator.pop(ctx);
          _showReactionEmojiPickerSheet(
            onSelected: (emoji) => unawaited(_setMessageReaction(msg.id, emoji)),
          );
        },
      ),
    );
  }

  void _onSocketMessage(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    final mRaw = map?['message'];
    if (mRaw is! Map) return;
    final dto = ChatMessageDto.fromJson(Map<String, dynamic>.from(mRaw));
    if (!_involvesPeer(dto)) return;
    if (!_initialHistorySyncDone) {
      if (!_pendingDuringHistory.any((e) => e.id == dto.id)) {
        _pendingDuringHistory.add(dto);
      }
      return;
    }
    setState(() => _ingestRemoteDto(dto));
    _maybeMarkReadInbound(dto);
    _scrollIfPinned();
  }

  void _ingestRemoteDto(ChatMessageDto dto) {
    if (_serverIds.contains(dto.id)) return;
    _serverIds.add(dto.id);

    if (dto.senderId == _myId) {
      final idx = _messages.indexWhere(
        (x) => x.clientId.isNotEmpty && x.clientId == (dto.clientId ?? '') && x.senderId == _myId,
      );
      if (idx >= 0) {
        final prev = _messages[idx];
        final outbound = dto.readAt != null
            ? OutboundDelivery.seen
            : (prev.outbound == OutboundDelivery.seen
                ? OutboundDelivery.seen
                : prev.outbound ?? OutboundDelivery.sent);
        _messages[idx] = _UiMsg(
          id: dto.id,
          clientId: prev.clientId,
          senderId: dto.senderId,
          body: dto.body,
          createdAt: dto.createdAt.toLocal(),
          outbound: outbound,
          replyTo: dto.replyTo ?? prev.replyTo,
          reactions: dto.reactions,
        );
        return;
      }
    }

    final mine = dto.senderId == _myId;
    final outbound = mine
        ? (dto.readAt != null ? OutboundDelivery.seen : OutboundDelivery.sent)
        : null;

    _messages.add(
      _UiMsg(
        id: dto.id,
        clientId: dto.clientId ?? '',
        senderId: dto.senderId,
        body: dto.body,
        createdAt: dto.createdAt.toLocal(),
        outbound: outbound,
        replyTo: dto.replyTo,
        reactions: dto.reactions,
      ),
    );
    _sortMessages();
  }

  void _onDelivered(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    final messageId = '${map['messageId'] ?? ''}';
    final cid = map['clientId'] != null ? '${map['clientId']}'.trim() : '';
    setState(() {
      final i = _messages.indexWhere(
        (x) => (messageId.isNotEmpty && x.id == messageId) || (cid.isNotEmpty && x.clientId == cid),
      );
      if (i < 0) return;
      final o = _messages[i].outbound;
      if (o == null || o == OutboundDelivery.failed || o == OutboundDelivery.sending) return;
      if (o == OutboundDelivery.seen) return;
      _messages[i] = _messages[i].copyWith(outbound: OutboundDelivery.delivered);
    });
  }

  /// Emitted when the peer's socket connects (they opened the app).
  void _onPeerDeliveryReady(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    final peerId = '${map?['peerId'] ?? ''}'.trim();
    if (peerId.isEmpty || peerId != widget.contact.id) return;
    _applyUpgradeSentToDelivered();
  }

  /// When contacts list shows this peer online, same as delivery_ready (presence path).
  void _maybeUpgradeDeliveryFromPeerPresence() {
    if (!mounted || !Get.isRegistered<ChatController>()) return;
    for (final c in Get.find<ChatController>().contacts) {
      if (c.id == widget.contact.id) {
        if (c.isOnline) _applyUpgradeSentToDelivered();
        return;
      }
    }
  }

  void _applyUpgradeSentToDelivered() {
    if (!mounted) return;
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.senderId != _myId) continue;
      if (m.outbound != OutboundDelivery.sent) continue;
      _messages[i] = m.copyWith(outbound: OutboundDelivery.delivered);
      changed = true;
    }
    if (changed) setState(() {});
  }

  void _onSeen(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    final reader = '${map['readerId'] ?? ''}';
    if (reader != widget.contact.id) return;
    final readUpToId = '${map['readUpToId'] ?? ''}';
    if (readUpToId.isEmpty) return;
    setState(() {
      for (var i = 0; i < _messages.length; i++) {
        final m = _messages[i];
        if (m.senderId != _myId) continue;
        if (!_objectIdLessOrEqual(m.id, readUpToId)) continue;
        if (m.outbound == OutboundDelivery.seen) continue;
        _messages[i] = m.copyWith(outbound: OutboundDelivery.seen);
      }
    });
  }

  void _onTyping(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    if ('${map['fromUserId']}' != widget.contact.id) return;
    final typing = map['typing'] == true;
    setState(() => _peerTyping = typing);
    _peerTypingClear?.cancel();
    if (typing) {
      _peerTypingClear = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _peerTyping = false);
      });
    }
  }

  bool _involvesPeer(ChatMessageDto m) {
    final peer = widget.contact.id;
    return (m.senderId == peer && m.recipientId == _myId) ||
        (m.senderId == _myId && m.recipientId == peer);
  }

  /// Lexicographic order matches Mongo ObjectId time ordering for same-length hex ids.
  bool _objectIdLessOrEqual(String messageId, String upTo) {
    if (messageId.startsWith('local:')) return true;
    if (messageId.length == 24 && upTo.length == 24) {
      return messageId.compareTo(upTo) <= 0;
    }
    return messageId.compareTo(upTo) <= 0;
  }

  void _maybeMarkReadInbound(ChatMessageDto dto) {
    if (dto.senderId != widget.contact.id) return;
    if (_viewingOlderMessages) return;
    unawaited(_markReadSafe(widget.contact.id, dto.id));
  }

  Future<void> _markReadSafe(String peerId, String readUpToId) async {
    try {
      await _repo.markChatMessagesRead(peerId: peerId, readUpToId: readUpToId);
    } catch (_) {}
  }

  Future<void> _syncHistoryWithServer() async {
    if (!mounted) return;
    if (_messages.isEmpty) {
      setState(() => _historyError = null);
    }
    try {
      final list = await _repo.fetchChatMessages(peerId: widget.contact.id);
      if (!mounted) return;
      setState(() {
        _mergeHistorySnapshot(list);
        _initialHistorySyncDone = true;
        if (_messages.isNotEmpty) {
          _historyError = null;
        }
      });
      _flushPendingSocketMessages();
      ChatMessageDto? lastPeer;
      for (var i = list.length - 1; i >= 0; i--) {
        if (list[i].senderId == widget.contact.id) {
          lastPeer = list[i];
          break;
        }
      }
      if (lastPeer != null && !_viewingOlderMessages) {
        unawaited(_markReadSafe(widget.contact.id, lastPeer.id));
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeUpgradeDeliveryFromPeerPresence();
        _scrollToLatest(animate: false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initialHistorySyncDone = true;
        if (_messages.isEmpty) {
          _historyError = '$e';
        }
      });
    }
  }

  void _mergeHistorySnapshot(List<ChatMessageDto> list) {
    final pending = _messages.where((m) {
      if (m.id.startsWith('local:')) return true;
      if (m.outbound == OutboundDelivery.sending) return true;
      if (m.outbound == OutboundDelivery.failed) return true;
      return false;
    }).toList();

    _messages
      ..clear()
      ..addAll(list.map(_fromHistoryDto))
      ..addAll(pending);
    _sortMessages();
    _removeOptimisticDuplicatesReplacedByServer();

    _serverIds
      ..clear()
      ..addAll(list.map((e) => e.id));
    for (final m in pending) {
      if (!m.id.startsWith('local:')) {
        _serverIds.add(m.id);
      }
    }
  }

  void _removeOptimisticDuplicatesReplacedByServer() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.id.startsWith('local:')) continue;
      if (m.clientId.isEmpty) continue;
      final hasServer = _messages.any(
        (x) =>
            !x.id.startsWith('local:') &&
            x.clientId.isNotEmpty &&
            x.clientId == m.clientId,
      );
      if (hasServer) {
        _messages.removeAt(i);
      }
    }
  }

  void _flushPendingSocketMessages() {
    if (!mounted) return;
    final pending = List<ChatMessageDto>.from(_pendingDuringHistory);
    _pendingDuringHistory.clear();
    if (pending.isEmpty) return;
    setState(() {
      for (final dto in pending) {
        _ingestRemoteDto(dto);
      }
    });
    for (final dto in pending) {
      _maybeMarkReadInbound(dto);
    }
    _scrollIfPinned(animate: false);
  }

  _UiMsg _fromHistoryDto(ChatMessageDto m) {
    final mine = m.senderId == _myId;
    OutboundDelivery? outbound;
    if (mine) {
      outbound = m.readAt != null ? OutboundDelivery.seen : OutboundDelivery.sent;
    }
    return _UiMsg(
      id: m.id,
      clientId: m.clientId ?? '',
      senderId: m.senderId,
      body: m.body,
      createdAt: m.createdAt.toLocal(),
      outbound: outbound,
      replyTo: m.replyTo,
      reactions: m.reactions,
    );
  }

  void _sortMessages() {
    _messages.sort((a, b) {
      final t = a.createdAt.compareTo(b.createdAt);
      if (t != 0) return t;
      return a.id.compareTo(b.id);
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    const threshold = 96.0;
    // reverse: true — newest at scroll offset 0; larger pixels = viewing older.
    final p = _scroll.position.pixels;
    final away = p > threshold;
    if (away != _viewingOlderMessages) {
      setState(() => _viewingOlderMessages = away);
    }
  }

  void _scrollIfPinned({bool animate = true}) {
    if (_viewingOlderMessages) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: animate);
    });
  }

  static const _scrollLatestEpsilon = 6.0;

  /// With [reverse: true] list, latest messages sit at [minScrollExtent] (usually 0).
  void _scrollToLatest({required bool animate}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.minScrollExtent;
    final current = _scroll.position.pixels;
    if ((current - target).abs() <= _scrollLatestEpsilon) {
      return;
    }
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _onInputChanged() {
    if (_input.text.trim().isEmpty) {
      _scheduleTypingFalse();
    }
  }

  void _onComposerTextChanged(String _) {
    _typingEmitDebounce?.cancel();
    _typingEmitDebounce = Timer(const Duration(milliseconds: 400), () {
      _emitTyping(true);
    });
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(milliseconds: 1200), () {
      _emitTyping(false);
    });
  }

  void _scheduleTypingFalse() {
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(milliseconds: 200), () {
      _emitTyping(false);
    });
  }

  void _emitTyping(bool typing) {
    if (!Get.isRegistered<ChatController>()) return;
    final s = Get.find<ChatController>().chatSocket;
    s?.emit('chat:typing', {'peerId': widget.contact.id, 'typing': typing});
  }

  String _newClientId() {
    final t = DateTime.now().microsecondsSinceEpoch;
    final r = Random().nextInt(0x7fffffff);
    return 'c_${t}_$r';
  }

  String _formatTime(DateTime local) {
    final d = local;
    final h24 = d.hour;
    final isPm = h24 >= 12;
    var h12 = h24 % 12;
    if (h12 == 0) h12 = 12;
    final m = d.minute < 10 ? '0${d.minute}' : '${d.minute}';
    return '$h12:$m ${isPm ? 'pm' : 'am'}';
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (_myId.isEmpty) return;

    final clientId = _newClientId();
    final pinned = _replyTarget;
    final replyQuote = pinned != null ? _replyQuoteFromTarget(pinned) : null;
    final replyToMessageId = replyQuote?.messageId;

    _input.clear();
    _emitTyping(false);
    _typingEmitDebounce?.cancel();
    _typingStopTimer?.cancel();

    setState(() {
      _replyTarget = null;
      _messages.add(
        _UiMsg(
          id: 'local:$clientId',
          clientId: clientId,
          senderId: _myId,
          body: text,
          createdAt: DateTime.now(),
          outbound: OutboundDelivery.sending,
          replyTo: replyQuote,
          reactions: const [],
        ),
      );
      _sortMessages();
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });

    try {
      final r = await _repo.sendChatMessage(
        peerId: widget.contact.id,
        body: text,
        clientId: clientId,
        replyToMessageId: replyToMessageId,
      );
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i < 0) return;
        _serverIds.add(r.message.id);
        _messages[i] = _UiMsg(
          id: r.message.id,
          clientId: clientId,
          senderId: r.message.senderId,
          body: r.message.body,
          createdAt: r.message.createdAt.toLocal(),
          outbound: r.peerOnline ? OutboundDelivery.delivered : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? replyQuote,
          reactions: r.message.reactions,
        );
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(outbound: OutboundDelivery.failed);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(outbound: OutboundDelivery.failed);
        }
      });
    }
  }

  Future<void> _retrySend(_UiMsg msg) async {
    if (msg.outbound != OutboundDelivery.failed) return;
    final clientId = msg.clientId;
    if (clientId.isEmpty) return;

    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == clientId);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(outbound: OutboundDelivery.sending);
      }
    });

    try {
      final r = await _repo.sendChatMessage(
        peerId: widget.contact.id,
        body: msg.body,
        clientId: clientId,
        replyToMessageId: msg.replyTo?.messageId,
      );
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i < 0) return;
        _serverIds.add(r.message.id);
        _messages[i] = _UiMsg(
          id: r.message.id,
          clientId: clientId,
          senderId: r.message.senderId,
          body: r.message.body,
          createdAt: r.message.createdAt.toLocal(),
          outbound: r.peerOnline ? OutboundDelivery.delivered : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? msg.replyTo,
          reactions: r.message.reactions,
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(outbound: OutboundDelivery.failed);
        }
      });
    }
  }

  ChatContact _livePeer() {
    if (!Get.isRegistered<ChatController>()) return widget.contact;
    final list = Get.find<ChatController>().contacts;
    for (final c in list) {
      if (c.id == widget.contact.id) return c;
    }
    return widget.contact;
  }

  String _headerSubtitle(ChatContact peer) {
    if (_peerTyping) return 'typing…';
    if (peer.isOnline) return 'Online';
    final s = peer.lastSeenSubtitle;
    if (s != null) return s;
    return 'Offline';
  }

  @override
  void dispose() {
    _removeReactionOverlay();
    _ChatThreadMemoryCache.instance.save(
      widget.contact.id,
      _messages,
      _serverIds,
    );
    unawaited(
      ChatThreadLocalStore.save(
        widget.contact.id,
        _messages.map(_toPersistedRow).toList(),
        _serverIds.toList(),
      ),
    );
    _contactsEver?.dispose();
    _typingEmitDebounce?.cancel();
    _typingStopTimer?.cancel();
    _peerTypingClear?.cancel();
    _unbindSocket();
    _input.removeListener(_onInputChanged);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<ChatController>()) {
      return _threadScaffold(context, widget.contact);
    }
    return Obx(() => _threadScaffold(context, _livePeer()));
  }

  Widget? _replyComposerBanner(ChatContact peer) {
    final t = _replyTarget;
    if (t == null) return null;
    final title = t.senderId == _myId
        ? 'You'
        : (peer.name.trim().isNotEmpty ? peer.name.trim() : peer.email);
    return _ReplyDraftStrip(
      title: title,
      subtitle: _oneLinePreview(t.body),
      onClose: () => setState(() => _replyTarget = null),
      onNavigateToQuote: () => _scrollToQuotedMessage(t.id),
    );
  }

  Widget _buildMessageLayer(ChatContact peer) {
    if (_historyError != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _historyError!,
            textAlign: TextAlign.center,
            style: GoogleFonts.ptSans(
              color: _ChatThreadColors.mutedOnCanvas,
              fontSize: 14,
            ),
          ),
        ),
      );
    }
    if (_messages.isNotEmpty) {
      _syncMessageAnchorKeys();
      return ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
        itemCount: _messages.length,
        itemBuilder: (context, i) {
          final msg = _messages[_messages.length - 1 - i];
          final peerLabel =
              peer.name.trim().isNotEmpty ? peer.name.trim() : peer.email;
          final q = msg.replyTo;
          return KeyedSubtree(
            key: _anchorKeyForMessageId(msg.id),
            child: _MessageBubble(
              msg: msg,
              myId: _myId,
              peerDisplayName: peerLabel,
              timeLabel: _formatTime(msg.createdAt),
              onRetry: msg.outbound == OutboundDelivery.failed
                  ? () => unawaited(_retrySend(msg))
                  : null,
              onSwipeReply: !msg.id.startsWith('local:')
                  ? () {
                      HapticFeedback.lightImpact();
                      setState(() => _replyTarget = msg);
                    }
                  : null,
              onReplyQuoteTap: (q != null && !q.isEmpty)
                  ? () => _scrollToQuotedMessage(q.messageId)
                  : null,
              onLongPressBubble: !msg.id.startsWith('local:')
                  ? () => _openQuickReactions(msg, _anchorKeyForMessageId(msg.id))
                  : null,
              onReactionSummaryTap: msg.reactions.isEmpty
                  ? null
                  : () => _showReactionDetailsSheet(msg, peer),
            ),
          );
        },
      );
    }
    if (_initialHistorySyncDone) {
      return Center(
        child: Text(
          'No messages yet',
          style: GoogleFonts.ptSans(
            color: _ChatThreadColors.mutedOnCanvas,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _threadScaffold(BuildContext context, ChatContact peer) {
    final initial = peer.name.trim().isEmpty
        ? '?'
        : peer.name.trim()[0].toUpperCase();

    return Scaffold(
      backgroundColor: _ChatThreadColors.canvas,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: _ChatThreadColors.composerBar,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: kPrimaryBlue.withValues(alpha: 0.9),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: peer.isOnline
                          ? const Color(0xFF22C55E)
                          : const Color(0xFF6B7280),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _ChatThreadColors.composerBar,
                        width: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    peer.name.isNotEmpty ? peer.name : peer.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ptSans(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _headerSubtitle(peer),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ptSans(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: _ChatThreadColors.canvas,
                    child: SizedBox.expand(
                      child: Image.asset(
                        'assets/chat.webp',
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                      ),
                    ),
                  ),
                ),
                _buildMessageLayer(peer),
              ],
            ),
          ),
          _ThreadComposer(
            controller: _input,
            replyBanner: _replyComposerBanner(peer),
            onSend: _send,
            onAttach: _showAttachmentSheet,
            onTextChanged: _onComposerTextChanged,
          ),
        ],
      ),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _ChatThreadColors.composerBar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final items = <(IconData, String, Color)>[
          (Icons.photo_library_rounded, 'Gallery', const Color(0xFF2196F3)),
          (Icons.photo_camera_rounded, 'Camera', const Color(0xFFE91E8C)),
          (Icons.description_rounded, 'Document', const Color(0xFF7C4DFF)),
          (Icons.poll_rounded, 'Poll', const Color(0xFFFFC107)),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: items.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 10,
                    mainAxisExtent: 108,
                  ),
                  itemBuilder: (context, i) {
                    final (icon, label, color) = items[i];
                    return _AttachmentSheetTile(
                      icon: icon,
                      label: label,
                      iconColor: color,
                      tileBackground: Colors.transparent,
                      onTap: () => Navigator.pop(ctx),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AttachmentSheetTile extends StatelessWidget {
  const _AttachmentSheetTile({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.tileBackground,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color tileBackground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 72,
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tileBackground,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Center(
                  child: Icon(icon, color: iconColor, size: 28),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: GoogleFonts.ptSans(
                color: Colors.white.withValues(alpha: 0.88),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

abstract final class _ChatThreadColors {
  static const canvas = Color(0xFF282828);
  static const composerBar = Color(0xFF121212);
  static const composerField = Color(0xFF3A3A3A);
  static const onComposer = Color(0xFFE8EAED);
  static const hintOnComposer = Color(0xFF9AA0A6);
  static const mutedOnCanvas = Color(0xFF9AA0A6);

  /// Dark chat bubbles (WhatsApp-style dark mode).
  static const incomingBubble = Color(0xFF202C33);
  static const outgoingBubble = Color(0xFF005C4B);
  static const bubbleText = Color(0xFFFFFFFF);
  static const bubbleMeta = Color(0xFF8696A0);
}

Config _chatThreadEmojiPickerConfig() {
  const bar = _ChatThreadColors.composerBar;
  return Config(
    height: 256,
    checkPlatformCompatibility: true,
    emojiViewConfig: const EmojiViewConfig(
      backgroundColor: _ChatThreadColors.composerBar,
      buttonMode: ButtonMode.CUPERTINO,
    ),
    categoryViewConfig: CategoryViewConfig(
      backgroundColor: bar,
      indicatorColor: kPrimaryBlue,
      iconColor: Colors.white.withValues(alpha: 0.54),
      iconColorSelected: kPrimaryBlue,
      backspaceColor: Colors.white70,
      dividerColor: Colors.transparent,
    ),
    bottomActionBarConfig: const BottomActionBarConfig(
      backgroundColor: _ChatThreadColors.composerBar,
      buttonColor: Color(0xFF2C2C2C),
      buttonIconColor: Colors.white70,
      enabled: false,
    ),
    searchViewConfig: SearchViewConfig(
      backgroundColor: _ChatThreadColors.composerBar,
      buttonIconColor: Colors.white54,
      hintTextStyle: GoogleFonts.ptSans(color: Colors.white38, fontSize: 16),
      inputTextStyle: GoogleFonts.ptSans(color: Colors.white, fontSize: 16),
    ),
    viewOrderConfig: ViewOrderConfig(
      top: EmojiPickerItem.searchBar,
      middle: EmojiPickerItem.categoryBar,
      bottom: EmojiPickerItem.emojiView,
    ),
  );
}

/// Rounded rect + small triangle at **top**-left (incoming).
class _IncomingBubbleClipper extends CustomClipper<Path> {
  const _IncomingBubbleClipper();

  static const _joinX = 9.0;
  static const _r = 10.0;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    if (w < _joinX + _r + 4 || h < 20) {
      return Path()..addRRect(RRect.fromLTRBR(0, 0, w, h, const Radius.circular(_r)));
    }
    final tipY = 11.0.clamp(7.0, h - 7.0);
    final topY = (tipY - 6).clamp(3.0, h - 10.0);
    final botY = (tipY + 6).clamp(10.0, h - 3.0);
    final body = Path()
      ..addRRect(
        RRect.fromLTRBR(_joinX, 0, w, h, const Radius.circular(_r)),
      );
    final tail = Path()
      ..moveTo(0, tipY)
      ..lineTo(_joinX, topY)
      ..lineTo(_joinX, botY)
      ..close();
    return Path.combine(PathOperation.union, tail, body);
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// Rounded rect + small triangle at **top**-right (outgoing).
class _OutgoingBubbleClipper extends CustomClipper<Path> {
  const _OutgoingBubbleClipper();

  static const _joinW = 9.0;
  static const _r = 10.0;

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    if (w < _joinW + _r + 4 || h < 20) {
      return Path()..addRRect(RRect.fromLTRBR(0, 0, w, h, const Radius.circular(_r)));
    }
    final tipY = 11.0.clamp(7.0, h - 7.0);
    final topY = (tipY - 6).clamp(3.0, h - 10.0);
    final botY = (tipY + 6).clamp(10.0, h - 3.0);
    final body = Path()
      ..addRRect(
        RRect.fromLTRBR(0, 0, w - _joinW, h, const Radius.circular(_r)),
      );
    final tail = Path()
      ..moveTo(w, tipY)
      ..lineTo(w - _joinW, topY)
      ..lineTo(w - _joinW, botY)
      ..close();
    return Path.combine(PathOperation.union, body, tail);
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// Reply preview above the composer (swipe-to-reply).
class _ReplyDraftStrip extends StatelessWidget {
  const _ReplyDraftStrip({
    required this.title,
    required this.subtitle,
    required this.onClose,
    this.onNavigateToQuote,
  });

  final String title;
  final String subtitle;
  final VoidCallback onClose;
  final VoidCallback? onNavigateToQuote;

  static const _accent = Color(0xFF9C88FF);
  static const _surface = Color(0xFF2A2A2A);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      padding: const EdgeInsets.fromLTRB(0, 8, 4, 8),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 40,
            margin: const EdgeInsets.only(left: 8, right: 10),
            decoration: BoxDecoration(
              color: _accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: onNavigateToQuote == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.ptSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _accent,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.ptSans(
                          fontSize: 13,
                          height: 1.25,
                          color: Colors.white.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  )
                : Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onNavigateToQuote,
                      borderRadius: BorderRadius.circular(6),
                      splashColor: _accent.withValues(alpha: 0.12),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4, bottom: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.ptSans(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _accent,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.ptSans(
                                fontSize: 13,
                                height: 1.25,
                                color: Colors.white.withValues(alpha: 0.72),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: Icon(
              Icons.close_rounded,
              size: 20,
              color: Colors.white.withValues(alpha: 0.85),
            ),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SwipeToReplyWrap extends StatefulWidget {
  const _SwipeToReplyWrap({
    required this.child,
    required this.onReply,
  });

  final Widget child;
  final VoidCallback onReply;

  @override
  State<_SwipeToReplyWrap> createState() => _SwipeToReplyWrapState();
}

class _SwipeToReplyWrapState extends State<_SwipeToReplyWrap>
    with SingleTickerProviderStateMixin {
  /// Rubber-band cap while dragging (visual only).
  static const double _maxRubber = 88;

  double _dragOffset = 0;
  AnimationController? _snapCtrl;

  @override
  void dispose() {
    _snapCtrl?.dispose();
    super.dispose();
  }

  double _clampDrag(double x) {
    if (x <= _maxRubber) return x;
    return _maxRubber + (x - _maxRubber) * 0.22;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final next = _dragOffset + d.delta.dx;
    if (next < 0) {
      setState(() => _dragOffset = next * 0.35);
      return;
    }
    setState(() => _dragOffset = _clampDrag(next));
  }

  void _snapBack() {
    final start = _dragOffset;
    if (start < 0.5) {
      setState(() => _dragOffset = 0);
      return;
    }
    _snapCtrl?.dispose();
    final ms = (140 + start * 0.55).round().clamp(120, 280);
    _snapCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    );
    final anim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _snapCtrl!, curve: Curves.easeOutCubic),
    );
    void tick() {
      setState(() => _dragOffset = anim.value);
    }

    anim.addListener(tick);
    _snapCtrl!.forward().then((_) {
      anim.removeListener(tick);
      _snapCtrl?.dispose();
      _snapCtrl = null;
      if (mounted) setState(() => _dragOffset = 0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (!mounted) return;
    // Only start reply after a deliberate swipe — a fraction of screen width.
    // Short drags: animate back with [_snapBack]. Successful reply: jump to old
    // position first, then open reply (parent setState must not leave bubble shifted).
    final width = MediaQuery.sizeOf(context).width;
    final commitPx = (width * 0.11).clamp(48.0, 88.0);
    final committed = _dragOffset >= commitPx;

    _snapCtrl?.stop(canceled: true);
    _snapCtrl?.dispose();
    _snapCtrl = null;

    if (committed) {
      setState(() => _dragOffset = 0);
      widget.onReply();
      return;
    }
    _snapBack();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) {
        if (_snapCtrl != null) {
          _snapCtrl!.stop(canceled: true);
          _snapCtrl!.dispose();
          _snapCtrl = null;
        }
        setState(() => _dragOffset = 0);
      },
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _snapBack,
      child: Transform.translate(
        offset: Offset(_dragOffset, 0),
        child: widget.child,
      ),
    );
  }
}

/// Preserves first-seen order of emoji keys for summary chips.
List<MapEntry<String, int>> _groupReactionEmojiCounts(List<ChatReactionEntry> reactions) {
  final order = <String>[];
  final counts = <String, int>{};
  for (final r in reactions) {
    counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    if (!order.contains(r.emoji)) order.add(r.emoji);
  }
  return [for (final e in order) MapEntry(e, counts[e]!)];
}

/// Matches [_IncomingBubbleClipper._joinX] / [_OutgoingBubbleClipper._joinW] so reactions
/// align with the **body** corner, not the tail.
const double _kBubbleTailWidth = 9.0;

String _reactionSummaryLabel(List<MapEntry<String, int>> grouped) {
  if (grouped.isEmpty) return '';
  if (grouped.length == 1) {
    final e = grouped.first;
    return e.value > 1 ? '${e.key}${e.value}' : e.key;
  }
  return '${grouped[0].key}${grouped[1].key}${grouped.length > 2 ? '+' : ''}';
}

/// WhatsApp-style: perfect circle, half on the bubble and half below the bottom edge.
class _ReactionSummaryBadge extends StatelessWidget {
  const _ReactionSummaryBadge({
    required this.grouped,
    required this.bubbleColor,
  });

  static const double diameter = 30.0;

  final List<MapEntry<String, int>> grouped;
  final Color bubbleColor;

  @override
  Widget build(BuildContext context) {
    final label = _reactionSummaryLabel(grouped);
    return SizedBox(
      width: diameter,
      height: diameter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bubbleColor,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.42),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageReactionOverlay extends StatelessWidget {
  const _MessageReactionOverlay({
    required this.anchorRect,
    required this.onDismiss,
    required this.onPickEmoji,
    required this.onOpenEmojiPicker,
  });

  final Rect anchorRect;
  final VoidCallback onDismiss;
  final ValueChanged<String> onPickEmoji;
  final VoidCallback onOpenEmojiPicker;

  static const _quick = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    const barH = 48.0;
    const gap = 8.0;
    final barW = _quick.length * 40.0 + 44.0 + 16.0;
    final centerX = anchorRect.left + anchorRect.width / 2;
    var left = centerX - barW / 2;
    left = left.clamp(8.0, media.width - barW - 8.0);
    var top = anchorRect.top - barH - gap;
    if (top < pad.top + 4) {
      top = anchorRect.bottom + gap;
    }

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 12,
              shadowColor: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(28),
              color: const Color(0xFF1E1E1E),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in _quick)
                      InkWell(
                        onTap: () => onPickEmoji(e),
                        borderRadius: BorderRadius.circular(22),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Text(e, style: const TextStyle(fontSize: 22)),
                        ),
                      ),
                    InkWell(
                      onTap: onOpenEmojiPicker,
                      borderRadius: BorderRadius.circular(22),
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.add, color: Colors.white70, size: 20),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReactionDetailsSheet extends StatefulWidget {
  const _ReactionDetailsSheet({
    required this.msg,
    required this.myId,
    required this.peerDisplayName,
    required this.onRemoveMine,
    required this.onPickEmoji,
  });

  final _UiMsg msg;
  final String myId;
  final String peerDisplayName;
  final VoidCallback onRemoveMine;
  final VoidCallback onPickEmoji;

  @override
  State<_ReactionDetailsSheet> createState() => _ReactionDetailsSheetState();
}

class _ReactionDetailsSheetState extends State<_ReactionDetailsSheet> {
  String? _filterEmoji;

  String _nameFor(String userId) {
    if (userId == widget.myId) return 'You';
    return widget.peerDisplayName;
  }

  @override
  Widget build(BuildContext context) {
    final rx = widget.msg.reactions;
    final n = rx.length;
    final title = n == 1 ? '1 reaction' : '$n reactions';
    final groups = _groupReactionEmojiCounts(rx);
    final filtered =
        _filterEmoji == null ? rx : rx.where((e) => e.emoji == _filterEmoji).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: GoogleFonts.ptSans(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Material(
                    color: const Color(0xFF2C2C2C),
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: widget.onPickEmoji,
                      borderRadius: BorderRadius.circular(20),
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(
                          Icons.add_reaction_outlined,
                          color: Colors.white54,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ...groups.map((g) {
                    final selected = _filterEmoji == g.key;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Material(
                        color: selected ? const Color(0xFF005C4B) : const Color(0xFF2C2C2C),
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          onTap: () => setState(() {
                            _filterEmoji = selected ? null : g.key;
                          }),
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(g.key, style: const TextStyle(fontSize: 18)),
                                const SizedBox(width: 4),
                                Text(
                                  '${g.value}',
                                  style: GoogleFonts.ptSans(
                                    color: selected
                                        ? const Color(0xFF7DD3A8)
                                        : Colors.white70,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final e = filtered[i];
                  final mine = e.userId == widget.myId;
                  final name = _nameFor(e.userId);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF5D4037),
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: GoogleFonts.ptSans(color: Colors.white),
                      ),
                    ),
                    title: Text(
                      name,
                      style: GoogleFonts.ptSans(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: mine
                        ? Text(
                            'Tap to remove',
                            style: GoogleFonts.ptSans(
                              color: _ChatThreadColors.hintOnComposer,
                              fontSize: 12,
                            ),
                          )
                        : null,
                    trailing: Text(e.emoji, style: const TextStyle(fontSize: 22)),
                    onTap: mine ? widget.onRemoveMine : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutboundTicks extends StatelessWidget {
  const _OutboundTicks({required this.state});

  final OutboundDelivery state;

  static const _muted = Color(0xFF8696A0);
  static const _seenBlue = Color(0xFF53BDEB);

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case OutboundDelivery.sending:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: _ChatThreadColors.bubbleMeta.withValues(alpha: 0.95),
          ),
        );
      case OutboundDelivery.sent:
        return Icon(Icons.check_rounded, size: 16, color: _muted);
      case OutboundDelivery.delivered:
        return Icon(Icons.done_all_rounded, size: 16, color: _muted);
      case OutboundDelivery.seen:
        return Icon(Icons.done_all_rounded, size: 16, color: _seenBlue);
      case OutboundDelivery.failed:
        return Icon(Icons.error_outline_rounded, size: 16, color: Colors.red.shade300);
    }
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.msg,
    required this.myId,
    required this.peerDisplayName,
    required this.timeLabel,
    this.onRetry,
    this.onSwipeReply,
    this.onReplyQuoteTap,
    this.onLongPressBubble,
    this.onReactionSummaryTap,
  });

  final _UiMsg msg;
  final String myId;
  final String peerDisplayName;
  final String timeLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onSwipeReply;
  final VoidCallback? onReplyQuoteTap;
  final VoidCallback? onLongPressBubble;
  final VoidCallback? onReactionSummaryTap;

  static const _bodyStyle = TextStyle(
    color: _ChatThreadColors.bubbleText,
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w400,
  );

  static TextStyle _metaStyle(BuildContext context) => GoogleFonts.ptSans(
        fontSize: 12,
        height: 1.2,
        color: _ChatThreadColors.bubbleMeta,
        fontWeight: FontWeight.w400,
      );

  static const _replyAccent = Color(0xFF9C88FF);

  Widget _inlineReplyStrip(ChatReplyQuote q) {
    final who = q.senderId == myId ? 'You' : peerDisplayName;
    final prev =
        q.bodyPreview.isNotEmpty ? q.bodyPreview : 'Message';
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 3,
          height: 36,
          decoration: BoxDecoration(
            color: _replyAccent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                who,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.ptSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _replyAccent,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                prev,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.ptSans(
                  fontSize: 13,
                  height: 1.2,
                  color: _ChatThreadColors.bubbleMeta,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final padded = Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: row,
    );
    final tap = onReplyQuoteTap;
    if (tap == null) return padded;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(6),
          splashColor: _replyAccent.withValues(alpha: 0.14),
          child: row,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outgoing = msg.senderId == myId;
    final meta = _metaStyle(context);
    final q = msg.replyTo;
    const baseRowBottom = 6.0;
    final hasReactions = msg.reactions.isNotEmpty;
    final rowBottomPadding = hasReactions
        ? baseRowBottom +
            _ReactionSummaryBadge.diameter / 2 +
            6 // space below the half-outside reaction circle before the next row
        : baseRowBottom;

    if (outgoing) {
      final st = msg.outbound ?? OutboundDelivery.sent;
      final grouped = _groupReactionEmojiCounts(msg.reactions);
      final bubbleCore = GestureDetector(
        onLongPress: onLongPressBubble,
        behavior: HitTestBehavior.deferToChild,
        child: ClipPath(
          clipper: const _OutgoingBubbleClipper(),
          child: ColoredBox(
            color: _ChatThreadColors.outgoingBubble,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 18, 8),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                    Text(
                      msg.body,
                      style: GoogleFonts.ptSans(textStyle: _bodyStyle),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(timeLabel, style: meta),
                        const SizedBox(width: 4),
                        if (st == OutboundDelivery.failed && onRetry != null)
                          InkWell(
                            onTap: onRetry,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 2),
                              child: Text(
                                'Retry',
                                style: GoogleFonts.ptSans(
                                  fontSize: 12,
                                  color: const Color(0xFF7DD3FC),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(bottom: 0.5),
                            child: _OutboundTicks(state: st),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final bubble = Padding(
        padding: EdgeInsets.only(left: 56, right: 0, bottom: rowBottomPadding, top: 2),
        child: Align(
          alignment: Alignment.centerRight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              bubbleCore,
              if (grouped.isNotEmpty && onReactionSummaryTap != null)
                Positioned(
                  right: _kBubbleTailWidth,
                  bottom: -_ReactionSummaryBadge.diameter / 2,
                  child: GestureDetector(
                    onTap: onReactionSummaryTap,
                    behavior: HitTestBehavior.opaque,
                    child: _ReactionSummaryBadge(
                      grouped: grouped,
                      bubbleColor: _ChatThreadColors.outgoingBubble,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (onSwipeReply == null) return bubble;
      return _SwipeToReplyWrap(
        onReply: onSwipeReply!,
        child: bubble,
      );
    }

    final groupedIn = _groupReactionEmojiCounts(msg.reactions);
    final incomingCore = GestureDetector(
      onLongPress: onLongPressBubble,
      behavior: HitTestBehavior.deferToChild,
      child: ClipPath(
        clipper: const _IncomingBubbleClipper(),
        child: ColoredBox(
          color: _ChatThreadColors.incomingBubble,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                  Text(
                    msg.body,
                    style: GoogleFonts.ptSans(textStyle: _bodyStyle),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(timeLabel, style: meta),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final incomingBubble = Padding(
      padding: EdgeInsets.only(right: 56, bottom: rowBottomPadding, top: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            incomingCore,
            if (groupedIn.isNotEmpty && onReactionSummaryTap != null)
              Positioned(
                left: _kBubbleTailWidth,
                bottom: -_ReactionSummaryBadge.diameter / 2,
                child: GestureDetector(
                  onTap: onReactionSummaryTap,
                  behavior: HitTestBehavior.opaque,
                  child: _ReactionSummaryBadge(
                    grouped: groupedIn,
                    bubbleColor: _ChatThreadColors.incomingBubble,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (onSwipeReply == null) return incomingBubble;
    return _SwipeToReplyWrap(
      onReply: onSwipeReply!,
      child: incomingBubble,
    );
  }
}

class _ThreadComposer extends StatefulWidget {
  const _ThreadComposer({
    required this.controller,
    this.replyBanner,
    required this.onSend,
    required this.onAttach,
    required this.onTextChanged,
  });

  final TextEditingController controller;
  final Widget? replyBanner;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final ValueChanged<String> onTextChanged;

  @override
  State<_ThreadComposer> createState() => _ThreadComposerState();
}

class _ThreadComposerState extends State<_ThreadComposer> {
  final FocusNode _fieldFocus = FocusNode();
  bool _emojiPanelOpen = false;

  void _onControllerText() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerText);
    _fieldFocus.addListener(() {
      if (_fieldFocus.hasFocus && _emojiPanelOpen) {
        setState(() => _emojiPanelOpen = false);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ThreadComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerText);
      widget.controller.addListener(_onControllerText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerText);
    _fieldFocus.dispose();
    super.dispose();
  }

  bool get _hasTypedText => widget.controller.text.trim().isNotEmpty;

  void _notifyTextChanged() {
    widget.onTextChanged(widget.controller.text);
  }

  void _toggleEmojiPanel() {
    if (_emojiPanelOpen) {
      setState(() => _emojiPanelOpen = false);
      _fieldFocus.requestFocus();
    } else {
      setState(() => _emojiPanelOpen = true);
      _fieldFocus.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  static Config _emojiPickerConfig() => _chatThreadEmojiPickerConfig();

  @override
  Widget build(BuildContext context) {
    final hasText = _hasTypedText;
    return PopScope(
      canPop: !_emojiPanelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _emojiPanelOpen) {
          setState(() => _emojiPanelOpen = false);
        }
      },
      child: Material(
      color: _ChatThreadColors.composerBar,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.replyBanner != null) ...[
                widget.replyBanner!,
                const SizedBox(height: 8),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _ChatThreadColors.composerField,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.only(left: 4, right: 2),
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 44,
                            ),
                            icon: Icon(
                              _emojiPanelOpen
                                  ? Icons.keyboard_rounded
                                  : Icons.emoji_emotions_outlined,
                              color: _ChatThreadColors.onComposer,
                              size: 24,
                            ),
                            tooltip: _emojiPanelOpen
                                ? 'Show keyboard'
                                : 'Show emojis',
                            onPressed: _toggleEmojiPanel,
                          ),
                          Expanded(
                            child: TextField(
                              controller: widget.controller,
                              focusNode: _fieldFocus,
                              minLines: 1,
                              maxLines: 5,
                              cursorColor: _ChatThreadColors.onComposer,
                              textCapitalization: TextCapitalization.sentences,
                              style: GoogleFonts.ptSans(
                                fontSize: 16,
                                color: _ChatThreadColors.onComposer,
                              ),
                              onChanged: widget.onTextChanged,
                              decoration: InputDecoration(
                                hintText: 'Type a message',
                                hintStyle: GoogleFonts.ptSans(
                                  color: _ChatThreadColors.hintOnComposer,
                                  fontSize: 16,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.fromLTRB(
                                  0,
                                  10,
                                  4,
                                  10,
                                ),
                                isDense: true,
                              ),
                              onSubmitted: (_) {
                                if (_hasTypedText) widget.onSend();
                              },
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.only(left: 2, right: 4),
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 44,
                            ),
                            icon: Icon(
                              Icons.attach_file_rounded,
                              color: _ChatThreadColors.onComposer.withValues(
                                alpha: 0.92,
                              ),
                              size: 22,
                            ),
                            onPressed: widget.onAttach,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (hasText)
                    Material(
                      color: const Color(0xFF00A884),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: widget.onSend,
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(
                            Icons.send_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    )
                  else
                    Material(
                      color: kPrimaryBlue,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () {},
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(
                            Icons.mic_none_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                    ),
                  ),
                ],
              ),
              if (_emojiPanelOpen) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 280,
                  child: EmojiPicker(
                    textEditingController: widget.controller,
                    onEmojiSelected: (_, _) => _notifyTextChanged(),
                    config: _emojiPickerConfig(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    );
  }
}
