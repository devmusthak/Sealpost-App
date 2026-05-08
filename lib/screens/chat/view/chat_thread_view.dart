import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:downloadsfolder/downloadsfolder.dart' as downloads_folder;
import 'package:linkify/linkify.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:record/record.dart';

import '../../../core/call/agora_call_service.dart';
import '../../../core/call/voice_call_navigation.dart';
import '../../../core/push/local_notification_service.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_image_message.dart';
import '../../../data/chat/chat_media_repository.dart';
import '../../../data/chat/chat_poll_message.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_message_dto.dart';
import '../../../data/chat/chat_repository.dart';
import '../../../data/chat/chat_thread_local_store.dart';
import '../../../data/chat/chat_user.dart';
import '../../../data/chat/link_preview_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/chat_action_dialog.dart';
import '../../compose/view/compose_view.dart';
import '../chat_forward_opener.dart';
import '../controller/chat_controller.dart';
import '../widgets/chat_link_preview_card.dart';
import '../widgets/chat_message_document.dart';
import '../widgets/chat_message_images.dart';
import '../widgets/chat_message_voice.dart';
import '../widgets/chat_message_video.dart';
import '../widgets/chat_poll_card.dart';
import '../widgets/group_invite_preview_widget.dart';
import 'chat_image_preview_screen.dart';
import 'chat_image_viewer_screen.dart';
import 'chat_pdf_viewer_screen.dart';
import 'chat_video_preview_screen.dart';
import 'chat_video_viewer_screen.dart';
import 'group_info_view.dart';
import 'create_poll_view.dart';
import 'poll_results_view.dart';

enum OutboundDelivery { sending, sent, delivered, seen, failed }

class _UiMsg {
  const _UiMsg({
    required this.id,
    required this.clientId,
    required this.senderId,
    this.senderName = '',
    required this.body,
    required this.createdAt,
    this.outbound,
    this.replyTo,
    this.reactions = const [],
    this.editedAt,
  });

  final String id;
  final String clientId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;
  final OutboundDelivery? outbound;
  final ChatReplyQuote? replyTo;
  final List<ChatReactionEntry> reactions;
  final DateTime? editedAt;

  _UiMsg copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? body,
    DateTime? createdAt,
    OutboundDelivery? outbound,
    ChatReplyQuote? replyTo,
    List<ChatReactionEntry>? reactions,
    DateTime? editedAt,
  }) {
    return _UiMsg(
      id: id ?? this.id,
      clientId: clientId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      outbound: outbound ?? this.outbound,
      replyTo: replyTo ?? this.replyTo,
      reactions: reactions ?? this.reactions,
      editedAt: editedAt ?? this.editedAt,
    );
  }

  /// Snapshot for restoring when re-opening the thread (no flicker).
  _UiMsg clone() {
    return _UiMsg(
      id: id,
      clientId: clientId,
      senderId: senderId,
      senderName: senderName,
      body: body,
      createdAt: createdAt,
      outbound: outbound,
      replyTo: replyTo,
      reactions: List<ChatReactionEntry>.from(reactions),
      editedAt: editedAt,
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
  const ChatThreadScreen({
    super.key,
    required this.contact,
    this.forwardMessagesOnOpen,
    this.shareMediaOnOpen,
    this.initialScrollToMessageId,
  });

  final ChatContact contact;

  /// When opening from forward flow: send each string as its own message (chronological order).
  /// Each entry should include the forwarded header lines you want at the top of that bubble.
  final List<String>? forwardMessagesOnOpen;

  /// When opening from the OS share sheet: image/video preview then send (same as in-thread attach).
  final List<SharedMediaFile>? shareMediaOnOpen;
  final String? initialScrollToMessageId;

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_UiMsg> _messages = [];
  final Set<String> _serverIds = {};
  OverlayEntry? _reactionOverlayEntry;

  /// Multi-select (persists after reaction popup is dismissed).
  final Set<String> _selectedMessageIds = {};
  bool _didSendOpeningForward = false;
  bool _didProcessOpeningShare = false;

  late final ChatRepository _repo = Get.find<ChatRepository>();
  String _myId = '';

  bool _viewingOlderMessages = false;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;
  bool _initialOpenPositionApplied = false;
  String? _lastReadMessageId;
  int? _firstUnreadIndex;

  /// Jump-to-latest arrow only after at least one older page was loaded (not just scrolling in first 50).
  bool _didLoadOlderPage = false;
  bool _didInitialExternalScroll = false;
  bool _peerTyping = false;
  bool _peerVoiceRecording = false;
  Timer? _peerTypingClear;
  Timer? _peerVoiceRecordingClear;

  Timer? _typingStopTimer;
  Timer? _socketBindRetry;

  /// Throttle repeated `typing: true` (server ~450ms gate).
  DateTime? _lastTypingTrueSent;

  /// Message user is replying to (swipe); cleared after send or dismiss.
  _UiMsg? _replyTarget;

  final FocusNode _composerFocus = FocusNode();

  /// Non-null while the composer is editing an existing server message.
  String? _editingMessageId;

  /// When editing a forwarded bubble, re-applied on submit before the typed text.
  String _editingLeadPrefix = '';

  /// Scroll-to-quote: one [GlobalKey] per loaded message id.
  final Map<String, GlobalKey> _messageAnchorKeys = {};

  /// One [GlobalKey] per inline day-separator, keyed by message id.
  final Map<String, GlobalKey> _dateSeparatorAnchorKeys = {};

  /// Bounds for mapping scroll → top-visible message (floating date header).
  final GlobalKey _chatListAreaKey = GlobalKey();

  /// Sticky label at top of list (updates while scrolling).
  String _floatingDateLabel = '';
  bool _floatingDateSuppressedByVisibleInline = false;
  bool _isUserScrollingMessages = false;
  Timer? _floatingDateThrottleTimer;
  Timer? _floatingDateHideTimer;

  /// Brief light-blue pulse on the message we scrolled to (reply jump-to-quote).
  Timer? _jumpHighlightTimer;
  String? _jumpHighlightMessageId;
  bool _jumpHighlightPulse = true;
  final Set<String> _voicePlayedEmitSent = <String>{};
  final Set<String> _docPreviewAutoDownloaded = <String>{};
  final Set<String> _docPreviewAutoInFlight = <String>{};
  bool _docPreviewAutoScanRunning = false;

  /// First server history fetch finished (success or error).
  bool _initialHistorySyncDone = false;

  String? _historyError;
  final List<ChatMessageDto> _pendingDuringHistory = [];

  /// Upgrades single-tick when peer comes online (socket or contacts presence).
  Worker? _contactsEver;
  bool get _isGroupConversation => widget.contact.isGroupConversation;
  String get _conversationId => widget.contact.conversationId;

  Future<SendChatMessageResult> _sendMessageRemote({
    required String body,
    required String clientId,
    String? replyToMessageId,
  }) {
    if (_isGroupConversation) {
      return _repo.sendGroupMessage(
        groupId: _conversationId,
        body: body,
        clientId: clientId,
        replyToMessageId: replyToMessageId,
      );
    }
    return _repo.sendChatMessage(
      peerId: widget.contact.id,
      body: body,
      clientId: clientId,
      replyToMessageId: replyToMessageId,
    );
  }

  Future<ChatMessageDto> _setMessageReactionRemote({
    required String messageId,
    required String emoji,
  }) {
    if (_isGroupConversation) {
      return _repo.setGroupMessageReaction(
        groupId: _conversationId,
        messageId: messageId,
        emoji: emoji,
      );
    }
    return _repo.setChatMessageReaction(
      peerId: widget.contact.id,
      messageId: messageId,
      emoji: emoji,
    );
  }

  Future<ChatMessageDto> _editMessageRemote({
    required String messageId,
    required String body,
  }) {
    if (_isGroupConversation) {
      return _repo.editGroupMessage(
        groupId: _conversationId,
        messageId: messageId,
        body: body,
      );
    }
    return _repo.editChatMessage(
      peerId: widget.contact.id,
      messageId: messageId,
      body: body,
    );
  }

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
        _scheduleFloatingDateUpdate();
        _scheduleDocPreviewAutoDownload();
      }
    });
    if (widget.forwardMessagesOnOpen != null &&
        widget.forwardMessagesOnOpen!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_trySendOpeningForward());
      });
    }
    if (widget.shareMediaOnOpen != null &&
        widget.shareMediaOnOpen!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_tryProcessOpeningShare());
      });
    }
  }

  Future<void> _trySendOpeningForward() async {
    if (_didSendOpeningForward) return;
    final list = widget.forwardMessagesOnOpen;
    if (list == null || list.isEmpty) return;
    final payloads = list
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (payloads.isEmpty) return;
    if (_myId.isEmpty) return;
    _didSendOpeningForward = true;
    for (final text in payloads) {
      if (!mounted) return;
      await _emitOutboundMessage(text, replyQuote: null);
    }
  }

  Future<void> _tryProcessOpeningShare() async {
    if (_didProcessOpeningShare) return;
    final raw = widget.shareMediaOnOpen;
    if (raw == null || raw.isEmpty) return;
    if (widget.forwardMessagesOnOpen != null &&
        widget.forwardMessagesOnOpen!.isNotEmpty) {
      return;
    }
    if (_myId.isEmpty) return;
    _didProcessOpeningShare = true;

    bool isShareVideo(SharedMediaFile f) {
      if (f.type == SharedMediaType.video) return true;
      final m = f.mimeType?.toLowerCase() ?? '';
      return m.startsWith('video/');
    }

    bool isShareImage(SharedMediaFile f) {
      if (f.type == SharedMediaType.image) return true;
      final m = f.mimeType?.toLowerCase() ?? '';
      if (m.startsWith('image/')) return true;
      final p = f.path.toLowerCase();
      return p.endsWith('.jpg') ||
          p.endsWith('.jpeg') ||
          p.endsWith('.png') ||
          p.endsWith('.gif') ||
          p.endsWith('.webp') ||
          p.endsWith('.heic');
    }

    final videos = raw.where(isShareVideo).toList();
    final nonVideos = raw.where((f) => !isShareVideo(f)).toList();
    for (final f in nonVideos) {
      if (!isShareImage(f)) {
        if (mounted) {
          _showThreadSnackBar(
            SnackBar(
              content: Text(
                'That file type can’t be shared here yet.',
                style: GoogleFonts.ptSans(),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
    }
    if (videos.length > 1) {
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text(
              'Share one video at a time.',
              style: GoogleFonts.ptSans(),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (videos.isNotEmpty && nonVideos.isNotEmpty) {
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text(
              'Share either photos or one video.',
              style: GoogleFonts.ptSans(),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (videos.isNotEmpty) {
      final path = videos.first.path;
      int len;
      try {
        len = await File(path).length();
      } catch (_) {
        return;
      }
      if (len > _kMaxChatVideoBytes) {
        if (mounted) {
          _showThreadSnackBar(
            SnackBar(
              content: Text(
                'Video must be under 20 MB',
                style: GoogleFonts.ptSans(),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      final file = XFile(path);
      final r = await Navigator.of(context).push<ChatVideoPreviewResult>(
        MaterialPageRoute(builder: (_) => ChatVideoPreviewScreen(file: file)),
      );
      if (!mounted || r == null) return;
      await _sendVideoMessage(r.file, r.caption);
      return;
    }

    final capped = nonVideos.length > _kMaxChatImages
        ? nonVideos.sublist(0, _kMaxChatImages)
        : nonVideos;
    final xfiles = capped.map((f) => XFile(f.path)).toList();
    if (!mounted) return;
    final r = await Navigator.of(context).push<ChatImagePreviewResult>(
      MaterialPageRoute(
        builder: (_) => ChatImagePreviewScreen(
          initialFiles: xfiles,
          maxImages: _kMaxChatImages,
        ),
      ),
    );
    if (!mounted || r == null || r.files.isEmpty) return;
    await _sendImageMessage(r.files, r.caption);
  }

  /// Disk cache (cold start) → socket → background sync. No blocking loader.
  Future<void> _startThread() async {
    _lastReadMessageId = await ChatThreadLocalStore.loadLastReadMessageId(
      _conversationId,
    );
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
          _recomputeUnreadBoundary();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scheduleFloatingDateUpdate();
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
      if (m.editedAt != null) 'editedAt': m.editedAt!.toUtc().toIso8601String(),
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
    final created =
        DateTime.tryParse('${e['createdAt'] ?? ''}') ?? DateTime.now();
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
    final editedRaw = e['editedAt'];
    DateTime? editedAt;
    if (editedRaw != null && '$editedRaw'.trim().isNotEmpty) {
      final ed = DateTime.tryParse('$editedRaw');
      if (ed != null) {
        editedAt = ed.isUtc ? ed.toLocal() : ed;
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
      editedAt: editedAt,
    );
  }

  static String _oneLinePreview(String body) {
    final t = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= 120) return t;
    return '${t.substring(0, 119)}…';
  }

  static String _replyBodyPreview(String body) {
    final voc = ChatVoiceMessage.tryParse(body);
    if (voc != null) {
      return 'Voice message';
    }
    final doc = ChatDocumentMessage.tryParse(body);
    if (doc != null) {
      return doc.isPdf ? 'PDF' : 'Document';
    }
    final vid = ChatVideoMessage.tryParse(body);
    if (vid != null) {
      final c = vid.caption.trim();
      if (c.isNotEmpty) return _oneLinePreview(c);
      return 'Video';
    }
    final img = ChatImageMessage.tryParse(body);
    if (img != null) {
      final c = img.caption.trim();
      if (c.isNotEmpty) return _oneLinePreview(c);
      return img.items.length > 1 ? '${img.items.length} photos' : 'Photo';
    }
    return _oneLinePreview(body);
  }

  ChatReplyQuote? _replyQuoteFromTarget(_UiMsg m) {
    if (m.id.startsWith('local:')) return null;
    final inner = _ForwardedPayloadParse.stripForDisplay(m.body) ?? m.body;
    return ChatReplyQuote(
      messageId: m.id,
      senderId: m.senderId,
      bodyPreview: _replyBodyPreview(inner),
    );
  }

  void _syncMessageAnchorKeys() {
    final valid = _messages.map((m) => m.id).toSet();
    _messageAnchorKeys.removeWhere((id, _) => !valid.contains(id));
  }

  void _syncDateSeparatorAnchorKeys() {
    final valid = <String>{};
    for (var i = 0; i < _messages.length; i++) {
      if (_isFirstMessageOfItsCalendarDay(i)) {
        valid.add(_messages[i].id);
      }
    }
    _dateSeparatorAnchorKeys.removeWhere((id, _) => !valid.contains(id));
  }

  GlobalKey _anchorKeyForMessageId(String id) =>
      _messageAnchorKeys.putIfAbsent(id, () => GlobalKey());

  GlobalKey _dateSeparatorKeyForMessageId(String id) =>
      _dateSeparatorAnchorKeys.putIfAbsent(id, () => GlobalKey());

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

  /// Clears any visible snack bars, then shows [snackBar] (avoids stacking).
  void _showThreadSnackBar(SnackBar snackBar, [BuildContext? scaffoldContext]) {
    final target = scaffoldContext ?? context;
    if (!target.mounted) return;
    final messenger = ScaffoldMessenger.of(target);
    messenger.clearSnackBars();
    messenger.showSnackBar(snackBar);
  }

  Future<void> _onCallActionTap({
    required ChatContact peer,
    required bool video,
  }) async {
    if (!mounted) return;
    if (video) {
      _showThreadSnackBar(
        SnackBar(
          content: Text(
            'Video call is not integrated yet.',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final callType = video ? 'Video call' : 'Voice call';
    final mic = await Permission.microphone.status;
    final micStatus = mic.isGranted ? mic : await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (micStatus.isPermanentlyDenied || micStatus.isRestricted) {
        await openAppSettings();
      }
      if (!mounted) return;
      _showThreadSnackBar(
        SnackBar(
          content: Text(
            'Microphone access is required for voice calls. Enable it in Settings > Sealpost > Microphone.',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final auth = Get.find<AuthRepository>();
      final session = await Get.find<AgoraCallService>().createAndInviteAudioSession(
        peerId: peer.id,
        peerName: peer.name.isEmpty ? peer.email : peer.name,
        conversationId: peer.conversationId,
        callerName:
            auth.session?.name ??
            auth.session?.email ??
            auth.userId ??
            'Sealpost User',
      );
      if (!mounted) return;
      await openVoiceCallScreen(session: session);
    } catch (error) {
      if (!mounted) return;
      _showThreadSnackBar(
        SnackBar(
          content: Text(
            error is StateError ? error.message : '$callType failed to start',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _startAudioCallFromToolbar(ChatContact peer) async {
    await _onCallActionTap(peer: peer, video: false);
  }

  void _startJumpToQuoteHighlight(String messageId) {
    _jumpHighlightTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _jumpHighlightMessageId = messageId;
      _jumpHighlightPulse = true;
    });
    var tick = 0;
    const maxTicks = 8;
    _jumpHighlightTimer = Timer.periodic(const Duration(milliseconds: 280), (
      t,
    ) {
      if (!mounted) {
        t.cancel();
        return;
      }
      tick++;
      setState(() => _jumpHighlightPulse = tick.isOdd);
      if (tick >= maxTicks) {
        t.cancel();
        setState(() {
          _jumpHighlightMessageId = null;
          _jumpHighlightPulse = true;
        });
      }
    });
  }

  /// [ListView.builder] does not keep off-screen items built, so [GlobalKey.currentContext]
  /// is often null for quoted messages. Scroll near the target first, then [ensureVisible].
  void _scrollToQuotedMessage(String targetId) {
    final resolved = _resolveQuoteTargetId(targetId);
    if (resolved == null) {
      if (!mounted) return;
      _showThreadSnackBar(
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
          _startJumpToQuoteHighlight(resolved);
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
    c.setConversationOpenPeer(
      _conversationId,
      isGroupConversation: _isGroupConversation,
    );
    unawaited(
      LocalNotificationService.clearChatNotificationsForPeer(_conversationId),
    );
    final s = c.chatSocket;
    if (s == null) {
      _socketBindRetry?.cancel();
      _socketBindRetry = Timer(const Duration(milliseconds: 600), _bindSocket);
      return;
    }
    _socketBindRetry?.cancel();
    s.on('chat:message', _onSocketMessage);
    s.on('chat:message:delivered', _onDelivered);
    s.on('chat:message:seen', _onSeen);
    s.on('chat:typing', _onTyping);
    s.on('chat:voice:recording', _onVoiceRecordingActivity);
    s.on('voice_recording', _onVoiceRecordingActivity);
    s.on('chat:peer:delivery_ready', _onPeerDeliveryReady);
    s.on('chat:reaction', _onSocketReaction);
    s.on('chat:message:edited', _onSocketMessage);
    s.on('poll_created', _onSocketMessage);
    s.on('poll_voted', _onSocketMessage);
    s.on('poll_ended', _onSocketMessage);
    s.on('chat:voice:played', _onVoicePlayed);
    s.on('voice_message_played', _onVoicePlayed);
    s.on('chat:voice_message_played', _onVoicePlayed);
  }

  void _unbindSocket() {
    _socketBindRetry?.cancel();
    _socketBindRetry = null;
    if (!Get.isRegistered<ChatController>()) return;
    final c = Get.find<ChatController>();
    c.setConversationOpenPeer(null);
    final s = c.chatSocket;
    s?.off('chat:message', _onSocketMessage);
    s?.off('chat:message:delivered', _onDelivered);
    s?.off('chat:message:seen', _onSeen);
    s?.off('chat:typing', _onTyping);
    s?.off('chat:voice:recording', _onVoiceRecordingActivity);
    s?.off('voice_recording', _onVoiceRecordingActivity);
    s?.off('chat:peer:delivery_ready', _onPeerDeliveryReady);
    s?.off('chat:reaction', _onSocketReaction);
    s?.off('chat:message:edited', _onSocketMessage);
    s?.off('poll_created', _onSocketMessage);
    s?.off('poll_voted', _onSocketMessage);
    s?.off('poll_ended', _onSocketMessage);
    s?.off('chat:voice:played', _onVoicePlayed);
    s?.off('voice_message_played', _onVoicePlayed);
    s?.off('chat:voice_message_played', _onVoicePlayed);
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

  void _applyReactionDto(ChatMessageDto dto, {bool clearSelection = false}) {
    if (!mounted) return;
    final i = _messages.indexWhere((m) => m.id == dto.id);
    if (i < 0) return;
    setState(() {
      _messages[i] = _messages[i].copyWith(reactions: dto.reactions);
      if (clearSelection) {
        _selectedMessageIds.clear();
      }
    });
  }

  /// Mirrors server reaction rules: remove, toggle off same emoji, or set/replace mine.
  List<ChatReactionEntry> _predictedReactionsAfterPick(
    List<ChatReactionEntry> current,
    String emoji,
    String myId,
  ) {
    final em = emoji.trim();
    final withoutMe = current.where((e) => e.userId != myId).toList();
    if (em.isEmpty) return withoutMe;
    if (myId.isEmpty) return List<ChatReactionEntry>.from(current);

    ChatReactionEntry? prevMine;
    for (final e in current) {
      if (e.userId == myId) {
        prevMine = e;
        break;
      }
    }
    if (prevMine != null && prevMine.emoji == em) {
      return withoutMe;
    }
    return [...withoutMe, ChatReactionEntry(userId: myId, emoji: em)];
  }

  Future<void> _setMessageReaction(String messageId, String emoji) async {
    if (messageId.isEmpty || messageId.startsWith('local:')) return;
    final i = _messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return;

    final em = emoji.trim();
    final previousReactions = List<ChatReactionEntry>.from(
      _messages[i].reactions,
    );
    final useOptimistic = _myId.isNotEmpty;

    if (useOptimistic) {
      final optimistic = _predictedReactionsAfterPick(
        previousReactions,
        emoji,
        _myId,
      );
      setState(() {
        final j = _messages.indexWhere((m) => m.id == messageId);
        if (j >= 0) {
          _messages[j] = _messages[j].copyWith(reactions: optimistic);
        }
      });
    }

    try {
      final dto = await _setMessageReactionRemote(messageId: messageId, emoji: em);
      if (!mounted) return;
      _applyReactionDto(dto, clearSelection: true);
    } catch (_) {
      if (!mounted) return;
      if (useOptimistic) {
        setState(() {
          final j = _messages.indexWhere((m) => m.id == messageId);
          if (j >= 0) {
            _messages[j] = _messages[j].copyWith(reactions: previousReactions);
          }
        });
      }
      _showThreadSnackBar(
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

  void _removeReactionOverlayEntryOnly() {
    _reactionOverlayEntry?.remove();
    _reactionOverlayEntry = null;
  }

  /// Selected rows in chronological order (oldest first), for copy/forward.
  List<_UiMsg> _selectedMessagesInOrder() {
    return _messages.where((m) => _selectedMessageIds.contains(m.id)).toList();
  }

  bool get _hasMessageSelection => _selectedMessageIds.isNotEmpty;

  /// Peer live activity chip (typing or voice recording).
  bool get _showPeerActivityBubble => (_peerVoiceRecording || _peerTyping);
  bool get _showPeerVoiceRecordingBubble =>
      _showPeerActivityBubble && _peerVoiceRecording;

  void _clearMessageSelection() {
    _removeReactionOverlayEntryOnly();
    if (!mounted) return;
    if (_selectedMessageIds.isNotEmpty) {
      setState(() => _selectedMessageIds.clear());
    }
  }

  void _toggleMessageSelection(_UiMsg msg) {
    if (msg.id.startsWith('local:')) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedMessageIds.contains(msg.id)) {
        _selectedMessageIds.remove(msg.id);
      } else {
        _selectedMessageIds.add(msg.id);
      }
    });
  }

  String _combinedSelectedTextForCopy() {
    final parts = <String>[];
    for (final m in _selectedMessagesInOrder()) {
      final raw = m.body;
      final stripped = _ForwardedPayloadParse.stripForDisplay(raw);
      final body = (stripped ?? raw).trim();
      if (body.isEmpty) continue;
      parts.add(body);
    }
    return parts.join('\n\n');
  }

  /// One outgoing bubble per selected message (UI shows « Forwarded » row; no original time).
  List<String> _forwardBodiesFromSelection() {
    final out = <String>[];
    for (final m in _selectedMessagesInOrder()) {
      final raw = m.body.trim();
      if (raw.isEmpty) continue;
      final inner = _ForwardedPayloadParse.stripToInnerPayload(raw).trim();
      if (inner.isEmpty) continue;
      out.add('${_ForwardedPayloadParse.textPrefix}$inner');
    }
    return out;
  }

  void _copyFocusedReactionMessage() {
    if (!_hasMessageSelection) return;
    final text = _combinedSelectedTextForCopy();
    if (text.trim().isEmpty) {
      _showThreadSnackBar(
        SnackBar(
          content: Text('Nothing to copy', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    _clearMessageSelection();
  }

  Future<void> _forwardFocusedReactionMessage() async {
    if (!_hasMessageSelection) return;
    final payloads = _forwardBodiesFromSelection();
    if (payloads.isEmpty) {
      _showThreadSnackBar(
        SnackBar(
          content: Text('Nothing to forward', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    _clearMessageSelection();
    if (!mounted) return;
    if (!Get.isRegistered<ChatForwardOpener>()) return;
    await Get.find<ChatForwardOpener>().openPickRecipient(context, payloads);
  }

  static const Duration _kMessageEditWindow = Duration(minutes: 5);

  _UiMsg? _singleSelectedMessage() {
    if (_selectedMessageIds.length != 1) return null;
    final sid = _selectedMessageIds.single;
    for (final m in _messages) {
      if (m.id == sid) return m;
    }
    return null;
  }

  bool _canEditMessage(_UiMsg msg) {
    if (msg.id.startsWith('local:')) return false;
    if (msg.senderId != _myId) return false;
    if (msg.outbound == OutboundDelivery.failed) return false;
    final raw = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
    if (ChatImageMessage.tryParse(raw) != null) return false;
    if (ChatVideoMessage.tryParse(raw) != null) return false;
    if (ChatVoiceMessage.tryParse(raw) != null) return false;
    if (ChatDocumentMessage.tryParse(raw) != null) return false;
    final poll = ChatPollMessage.tryParse(raw);
    if (poll != null) {
      return _canEditPollMessage(poll);
    }
    final age = DateTime.now().difference(msg.createdAt);
    return age <= _kMessageEditWindow;
  }

  bool _canEditPollMessage(ChatPollMessage poll) {
    if (poll.createdBy != _myId) return false;
    if (poll.isEndedAt(DateTime.now().toUtc())) return false;
    // Keep editing safe: allow updates before first vote.
    if (poll.votes.isNotEmpty) return false;
    return true;
  }

  void _beginEditingSelectedMessage() async {
    final msg = _singleSelectedMessage();
    if (msg == null || !_canEditMessage(msg)) {
      _showThreadSnackBar(
        SnackBar(
          content: Text(
            'You can edit only your recent messages. Polls can be edited before votes start.',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final raw = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
    final poll = ChatPollMessage.tryParse(raw);
    if (poll != null) {
      _removeReactionOverlayEntryOnly();
      await _editPollMessage(msg, poll);
      return;
    }
    _removeReactionOverlayEntryOnly();
    final stripped = _ForwardedPayloadParse.stripForDisplay(raw);
    setState(() {
      _replyTarget = null;
      _editingMessageId = msg.id;
      _editingLeadPrefix = stripped != null
          ? _ForwardedPayloadParse.textPrefix
          : '';
      _input.text = stripped ?? msg.body;
      _selectedMessageIds.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  Future<void> _editPollMessage(_UiMsg msg, ChatPollMessage poll) async {
    final result = await Navigator.of(context).push<CreatePollResult>(
      MaterialPageRoute(
        builder: (_) => CreatePollScreen(
          title: 'Edit Poll',
          submitLabel: 'Update Poll',
          initialQuestion: poll.question,
          initialOptions: poll.options.map((e) => e.text).toList(),
          initialEndsAtUtc: poll.endsAtUtc,
          initialVisibleAnswers: poll.visibleAnswers,
        ),
      ),
    );
    if (!mounted || result == null) return;
    final updatedOptions = <ChatPollOption>[];
    for (var i = 0; i < result.options.length; i++) {
      final old = i < poll.options.length ? poll.options[i] : null;
      updatedOptions.add(
        ChatPollOption(
          optionId: old?.optionId ?? 'opt_${i + 1}_${DateTime.now().microsecondsSinceEpoch}',
          text: result.options[i],
          voteCount: old?.voteCount ?? 0,
        ),
      );
    }
    final updated = poll.copyWith(
      options: updatedOptions,
      votes: const <ChatPollVote>[],
      status: result.endsAtUtc.isAfter(DateTime.now().toUtc()) ? 'active' : 'ended',
    );
    final body = ChatPollMessage(
      pollId: poll.pollId,
      question: result.question,
      options: updated.options,
      votes: updated.votes,
      createdBy: poll.createdBy,
      createdAtUtc: poll.createdAtUtc,
      endsAtUtc: result.endsAtUtc,
      allowMultipleAnswers: poll.allowMultipleAnswers,
      visibleAnswers: result.visibleAnswers,
      status: updated.status,
    ).encode();

    try {
      final dto = await _editMessageRemote(messageId: msg.id, body: body);
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((m) => m.id == dto.id);
        if (i >= 0) _mergeRemoteDtoIntoIndex(i, dto);
        _selectedMessageIds.clear();
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final em = e.response?.data is Map
          ? '${(e.response!.data as Map)['message'] ?? ''}'.trim()
          : '';
      _showThreadSnackBar(
        SnackBar(
          content: Text(em.isNotEmpty ? em : 'Could not update poll', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _showThreadSnackBar(
        SnackBar(
          content: Text('Could not update poll', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _cancelEditingMessage() {
    if (_editingMessageId == null) return;
    setState(() {
      _editingMessageId = null;
      _editingLeadPrefix = '';
      _input.clear();
    });
  }

  Future<void> _submitMessageEdit() async {
    final id = _editingMessageId;
    if (id == null || _myId.isEmpty) return;
    final trimmed = _input.text.trim();
    if (trimmed.isEmpty) return;
    final body = _editingLeadPrefix.isEmpty
        ? trimmed
        : '$_editingLeadPrefix$trimmed';
    try {
      final dto = await _editMessageRemote(messageId: id, body: body);
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((m) => m.id == dto.id);
        if (i >= 0) {
          _mergeRemoteDtoIntoIndex(i, dto);
        }
        _editingMessageId = null;
        _editingLeadPrefix = '';
        _input.clear();
      });
      _emitTyping(false);
    } on DioException catch (e) {
      if (!mounted) return;
      final msg = e.response?.data is Map
          ? '${(e.response!.data as Map)['message'] ?? ''}'.trim()
          : '';
      _showThreadSnackBar(
        SnackBar(
          content: Text(
            msg.isNotEmpty ? msg : 'Could not edit message',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _showThreadSnackBar(
        SnackBar(
          content: Text('Could not edit message', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
    _removeReactionOverlayEntryOnly();
    setState(() => _selectedMessageIds.add(msg.id));
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (oc) => _MessageReactionOverlay(
        anchorRect: Rect.fromLTWH(
          topLeft.dx,
          topLeft.dy,
          size.width,
          size.height,
        ),
        onDismiss: () {
          _removeReactionOverlayEntryOnly();
        },
        onPickEmoji: (emoji) {
          _removeReactionOverlayEntryOnly();
          unawaited(_setMessageReaction(msg.id, emoji));
        },
        onOpenEmojiPicker: () {
          _removeReactionOverlayEntryOnly();
          _showReactionEmojiPickerSheet(
            onSelected: (emoji) =>
                unawaited(_setMessageReaction(msg.id, emoji)),
          );
        },
      ),
    );
    _reactionOverlayEntry = entry;
    overlay.insert(entry);
  }

  Future<void> _showReactionEmojiPickerSheet({
    required ValueChanged<String> onSelected,
  }) async {
    await showModalBottomSheet<void>(
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

  Future<void> _showReactionDetailsSheet(_UiMsg msg, ChatContact peer) async {
    if (!mounted) return;
    _removeReactionOverlayEntryOnly();
    // Let any competing gesture/overlay settle before opening the sheet.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: _ChatThreadColors.composerBar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ReactionDetailsSheet(
        msg: msg,
        myId: _myId,
        nameForUserId: (userId) => _reactionUserName(
          userId: userId,
          msg: msg,
          peer: peer,
        ),
        onRemoveMine: () {
          Navigator.pop(ctx);
          unawaited(_setMessageReaction(msg.id, ''));
        },
        onPickEmoji: () {
          Navigator.pop(ctx);
          _showReactionEmojiPickerSheet(
            onSelected: (emoji) =>
                unawaited(_setMessageReaction(msg.id, emoji)),
          );
        },
      ),
    );
  }

  String _reactionUserName({
    required String userId,
    required _UiMsg msg,
    required ChatContact peer,
  }) {
    if (userId == _myId) return 'You';
    if (msg.senderId == userId && msg.senderName.trim().isNotEmpty) {
      return msg.senderName.trim();
    }
    for (final c in Get.find<ChatController>().contacts) {
      if (!c.isGroupConversation && c.id == userId) {
        return c.name.trim().isNotEmpty ? c.name.trim() : c.email;
      }
    }
    if (!peer.isGroupConversation) {
      return peer.name.trim().isNotEmpty ? peer.name.trim() : peer.email;
    }
    return 'Member';
  }

  /// Same as chat home [ChatScreen] when opening a thread with a friend.
  ChatContact _chatContactForFriendThread(ChatUser u) {
    return ChatContact(
      id: u.id,
      name: u.name.isNotEmpty ? u.name : u.email,
      email: u.email,
      isOnline: u.isOnline,
      lastSeenAt: null,
      relationStatus: 'friends',
      lastMessage: '',
      timeLabel: '',
      unreadCount: 0,
    );
  }

  /// Same modal as chat home search user tap ([ChatScreen._showActionModal]).
  Future<void> _showChatHomeStyleUserActionModal(ChatUser user) async {
    if (!mounted) return;
    final parentContext = context;
    final subtitle =
        '${user.name.isEmpty ? user.email : user.name}  ${user.isOnline ? '• Online' : '• Offline'}\n${user.email}';

    await showDialog<void>(
      context: parentContext,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (dialogContext) {
        switch (user.relationStatus) {
          case 'request_received':
            return ChatActionDialog(
              title: 'Friend request',
              subtitle: subtitle,
              primaryText: 'Accept',
              secondaryText: 'Close',
              primaryFilled: true,
              onPrimary: () async {
                Navigator.of(dialogContext).pop();
                await Get.find<ChatRepository>().acceptFriendRequest(user.id);
                if (Get.isRegistered<ChatController>()) {
                  await Get.find<ChatController>().refreshContacts();
                }
                if (!mounted || !parentContext.mounted) return;
                _showThreadSnackBar(
                  const SnackBar(content: Text('Friend request accepted')),
                  parentContext,
                );
                await Navigator.of(parentContext).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ChatThreadScreen(
                      contact: _chatContactForFriendThread(user),
                    ),
                  ),
                );
              },
              onSecondary: () => Navigator.of(dialogContext).pop(),
            );
          case 'request_sent':
            return ChatActionDialog(
              title: 'Request pending',
              subtitle: subtitle,
              primaryText: 'Notify user',
              secondaryText: 'Close',
              primaryFilled: true,
              onPrimary: () async {
                Navigator.of(dialogContext).pop();
                await Get.find<ChatRepository>().notifyFriendRequestUser(
                  user.id,
                );
                if (!mounted || !parentContext.mounted) return;
                _showThreadSnackBar(
                  const SnackBar(content: Text('Notification sent')),
                  parentContext,
                );
              },
              onSecondary: () => Navigator.of(dialogContext).pop(),
            );
          case 'friends':
            return ChatActionDialog(
              title: 'Friends',
              subtitle: subtitle,
              primaryText: 'Open chat',
              secondaryText: 'Close',
              primaryFilled: true,
              onPrimary: () {
                Navigator.of(dialogContext).pop();
                unawaited(
                  Navigator.of(parentContext).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatThreadScreen(
                        contact: _chatContactForFriendThread(user),
                      ),
                    ),
                  ),
                );
              },
              onSecondary: () => Navigator.of(dialogContext).pop(),
            );
          case 'none':
          default:
            return ChatActionDialog(
              title: 'Add friend',
              subtitle: subtitle,
              primaryText: 'Add friend',
              secondaryText: 'Close',
              primaryFilled: true,
              onPrimary: () async {
                Navigator.of(dialogContext).pop();
                if (user.relationStatus != 'none') return;
                await Get.find<ChatRepository>().sendFriendRequest(user.id);
                if (Get.isRegistered<ChatController>()) {
                  await Get.find<ChatController>().refreshContacts();
                }
                if (!mounted || !parentContext.mounted) return;
                _showThreadSnackBar(
                  const SnackBar(content: Text('Friend request sent')),
                  parentContext,
                );
              },
              onSecondary: () => Navigator.of(dialogContext).pop(),
            );
        }
      },
    );
  }

  Future<void> _openComposeToAddress(String to) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ComposeScreen(
          prefill: ComposePrefill(
            toAddresses: [to.trim()],
            subject: '',
            body: '',
          ),
        ),
      ),
    );
  }

  Future<void> _onMessageEmailTap(String rawEmail) async {
    final email = rawEmail.trim();
    if (email.isEmpty) return;
    final normalized = email.toLowerCase();

    final myEmail =
        Get.find<AuthRepository>().session?.email.trim().toLowerCase() ?? '';
    if (myEmail.isNotEmpty && normalized == myEmail) {
      if (!mounted) return;
      _showThreadSnackBar(
        SnackBar(
          content: Text('This is your email', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );

    try {
      final repo = Get.find<ChatRepository>();
      final users = await repo.searchUsersByEmail(normalized);
      if (!mounted) return;
      Navigator.of(context).pop();

      ChatUser? match;
      for (final u in users) {
        if (u.email.trim().toLowerCase() == normalized) {
          match = u;
          break;
        }
      }

      if (match == null) {
        await _openComposeToAddress(email);
        return;
      }

      final user = match;
      final display = user.name.isNotEmpty ? user.name : user.email;

      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: _ChatThreadColors.composerBar,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        display,
                        style: GoogleFonts.ptSans(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white54,
                      ),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.mail_outline,
                  color: Color(0xFF7DD3FC),
                ),
                title: Text(
                  'Send email',
                  style: GoogleFonts.ptSans(color: Colors.white, fontSize: 16),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_openComposeToAddress(user.email));
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.chat_bubble_outline,
                  color: Color(0xFF7DD3FC),
                ),
                title: Text(
                  'Chat with $display',
                  style: GoogleFonts.ptSans(color: Colors.white, fontSize: 16),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_openChatFromEmailUser(user));
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text(
              'Could not look up email',
              style: GoogleFonts.ptSans(),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _openChatFromEmailUser(ChatUser user) async {
    if (!mounted) return;
    if (user.relationStatus == 'friends') {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              ChatThreadScreen(contact: _chatContactForFriendThread(user)),
        ),
      );
      return;
    }
    await _showChatHomeStyleUserActionModal(user);
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
    setState(() {
      _ingestRemoteDto(dto);
      _recomputeUnreadBoundary();
    });
    _scheduleDocPreviewAutoDownload();
    _maybeMarkReadInbound(dto);
    // Group chats: avoid visible auto-scroll animation when a new remote message
    // arrives right as the thread opens; keep position update instant instead.
    _scrollIfPinned(animate: !_isGroupConversation);
  }

  void _mergeRemoteDtoIntoIndex(int i, ChatMessageDto dto) {
    final prev = _messages[i];
    final mine = dto.senderId == _myId;
    OutboundDelivery? outbound;
    if (mine) {
      outbound = dto.readAt != null
          ? OutboundDelivery.seen
          : (prev.outbound == OutboundDelivery.seen
                ? OutboundDelivery.seen
                : prev.outbound ?? OutboundDelivery.sent);
    }
    final cid = dto.clientId?.trim() ?? '';
    final mergedBody = _mergeVoicePlayedBodyPreservingLocal(
      incomingBody: dto.body,
      localBody: prev.body,
    );
    _messages[i] = _UiMsg(
      id: dto.id,
      clientId: cid.isNotEmpty ? cid : prev.clientId,
      senderId: dto.senderId,
      senderName: dto.senderName?.trim().isNotEmpty == true
          ? dto.senderName!.trim()
          : prev.senderName,
      body: mergedBody,
      createdAt: dto.createdAt.toLocal(),
      outbound: outbound,
      replyTo: dto.replyTo ?? prev.replyTo,
      reactions: dto.reactions,
      editedAt: dto.editedAt?.toLocal(),
    );
  }

  void _ingestRemoteDto(ChatMessageDto dto) {
    if (dto.senderId == _myId) {
      final idx = _messages.indexWhere(
        (x) =>
            x.clientId.isNotEmpty &&
            x.clientId == (dto.clientId ?? '') &&
            x.senderId == _myId,
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
          senderName: dto.senderName?.trim().isNotEmpty == true
              ? dto.senderName!.trim()
              : prev.senderName,
          body: _mergeVoicePlayedBodyPreservingLocal(
            incomingBody: dto.body,
            localBody: prev.body,
          ),
          createdAt: dto.createdAt.toLocal(),
          outbound: outbound,
          replyTo: dto.replyTo ?? prev.replyTo,
          reactions: dto.reactions,
          editedAt: dto.editedAt?.toLocal(),
        );
        if (!_serverIds.contains(dto.id)) {
          _serverIds.add(dto.id);
        }
        return;
      }
    }

    final existing = _messages.indexWhere((m) => m.id == dto.id);
    if (existing >= 0) {
      _mergeRemoteDtoIntoIndex(existing, dto);
      return;
    }

    if (_serverIds.contains(dto.id)) return;
    _serverIds.add(dto.id);

    final mine = dto.senderId == _myId;
    final outbound = mine
        ? (dto.readAt != null ? OutboundDelivery.seen : OutboundDelivery.sent)
        : null;

    _messages.add(
      _UiMsg(
        id: dto.id,
        clientId: dto.clientId ?? '',
        senderId: dto.senderId,
        senderName: dto.senderName?.trim() ?? '',
        body: dto.body,
        createdAt: dto.createdAt.toLocal(),
        outbound: outbound,
        replyTo: dto.replyTo,
        reactions: dto.reactions,
        editedAt: dto.editedAt?.toLocal(),
      ),
    );
    _sortMessages();
  }

  String _mergeVoicePlayedBodyPreservingLocal({
    required String incomingBody,
    required String localBody,
  }) {
    final incoming = ChatVoiceMessage.tryParse(incomingBody);
    if (incoming == null) return incomingBody;
    if (incoming.playedByPeer) return incomingBody;
    final local = ChatVoiceMessage.tryParse(localBody);
    if (local == null || !local.playedByPeer) return incomingBody;
    return incoming
        .copyWith(
          playedByPeer: true,
          playedAtIso: local.playedAtIso ?? DateTime.now().toIso8601String(),
        )
        .encode();
  }

  void _onDelivered(dynamic data) {
    if (!mounted) return;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;
    if (map == null) return;
    final messageId = '${map['messageId'] ?? ''}';
    final cid = map['clientId'] != null ? '${map['clientId']}'.trim() : '';
    setState(() {
      final i = _messages.indexWhere(
        (x) =>
            (messageId.isNotEmpty && x.id == messageId) ||
            (cid.isNotEmpty && x.clientId == cid),
      );
      if (i < 0) return;
      final o = _messages[i].outbound;
      if (o == null ||
          o == OutboundDelivery.failed ||
          o == OutboundDelivery.sending) {
        return;
      }
      if (o == OutboundDelivery.seen) return;
      _messages[i] = _messages[i].copyWith(
        outbound: OutboundDelivery.delivered,
      );
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
    final root = data is Map ? Map<String, dynamic>.from(data) : null;
    if (root == null) return;
    final nested = root['payload'];
    final map = nested is Map ? Map<String, dynamic>.from(nested) : root;
    final fromId =
        '${map['fromUserId'] ?? map['senderId'] ?? map['from'] ?? ''}'.trim();
    final peerId =
        '${map['peerId'] ?? map['toUserId'] ?? map['conversationId'] ?? map['groupId'] ?? ''}'
            .trim();
    final fromMatches = !_isGroupConversation &&
        fromId.isNotEmpty &&
        fromId == widget.contact.id;
    final targetMatchesSelf = !_isGroupConversation &&
        peerId.isNotEmpty &&
        peerId == _myId;
    final groupMatches = _isGroupConversation &&
        peerId.isNotEmpty &&
        peerId == _conversationId &&
        fromId.isNotEmpty &&
        fromId != _myId;
    if (!fromMatches && !targetMatchesSelf && !groupMatches) return;
    final voiceRecording =
        map['voiceRecording'] == true ||
        map['isRecordingVoice'] == true ||
        '${map['activity']}'.trim().toLowerCase() == 'voice' ||
        '${map['activityType']}'.trim().toLowerCase() == 'voice_recording' ||
        '${map['event']}'.trim().toLowerCase() == 'voice_recording_start';
    final typing = map['typing'] == true;
    if (voiceRecording) {
      setState(() {
        _peerVoiceRecording = true;
        _peerTyping = false;
      });
      _peerVoiceRecordingClear?.cancel();
      _peerVoiceRecordingClear = Timer(const Duration(seconds: 6), () {
        if (mounted) {
          setState(() => _peerVoiceRecording = false);
        }
      });
      return;
    }

    // Explicit voice stop from peer.
    if (map['voiceRecording'] == false ||
        '${map['event']}'.trim().toLowerCase() == 'voice_recording_stop') {
      if (_peerVoiceRecording) {
        setState(() => _peerVoiceRecording = false);
      }
      _peerVoiceRecordingClear?.cancel();
    }

    setState(() => _peerTyping = typing);
    _peerTypingClear?.cancel();
    if (typing) {
      _peerVoiceRecording = false;
      // Reset on each typing ping; keep indicator while peer sends ~480ms heartbeats.
      _peerTypingClear = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _peerTyping = false);
      });
    }
  }

  void _onVoiceRecordingActivity(dynamic data) {
    if (!mounted) return;
    final root = data is Map ? Map<String, dynamic>.from(data) : null;
    if (root == null) return;
    final nested = root['payload'];
    final map = nested is Map ? Map<String, dynamic>.from(nested) : root;
    final fromId =
        '${map['fromUserId'] ?? map['senderId'] ?? map['from'] ?? ''}'.trim();
    final peerId =
        '${map['peerId'] ?? map['toUserId'] ?? map['conversationId'] ?? map['groupId'] ?? ''}'
            .trim();
    final fromMatches = !_isGroupConversation &&
        fromId.isNotEmpty &&
        fromId == widget.contact.id;
    final targetMatchesSelf = !_isGroupConversation &&
        peerId.isNotEmpty &&
        peerId == _myId;
    final groupMatches = _isGroupConversation &&
        peerId.isNotEmpty &&
        peerId == _conversationId &&
        fromId.isNotEmpty &&
        fromId != _myId;
    if (!fromMatches && !targetMatchesSelf && !groupMatches) return;
    final active =
        map['voiceRecording'] == true ||
        map['isRecordingVoice'] == true ||
        map['recording'] == true ||
        '${map['activity']}'.trim().toLowerCase() == 'voice' ||
        '${map['activityType']}'.trim().toLowerCase() == 'voice_recording' ||
        '${map['event']}'.trim().toLowerCase() == 'voice_recording_start';
    if (active) {
      _peerTypingClear?.cancel();
      _peerVoiceRecordingClear?.cancel();
      setState(() {
        _peerVoiceRecording = true;
        _peerTyping = false;
      });
      _peerVoiceRecordingClear = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _peerVoiceRecording = false);
      });
    } else {
      _peerVoiceRecordingClear?.cancel();
      if (_peerVoiceRecording) {
        setState(() => _peerVoiceRecording = false);
      }
    }
  }

  void _onVoicePlayed(dynamic data) {
    if (!mounted) return;
    final root = data is Map ? Map<String, dynamic>.from(data) : null;
    if (root == null) return;
    final mapRaw = root['payload'];
    final map = mapRaw is Map ? Map<String, dynamic>.from(mapRaw) : root;
    final peerId =
        '${map['peerId'] ?? map['fromUserId'] ?? map['senderId'] ?? ''}'.trim();
    if (peerId.isNotEmpty && peerId != widget.contact.id) return;
    final messageId =
        '${map['messageId'] ?? map['chatMessageId'] ?? map['id'] ?? ''}'.trim();
    final clientId = '${map['clientId'] ?? ''}'.trim();
    if (messageId.isEmpty && clientId.isEmpty) return;
    final playedAt = '${map['playedAt'] ?? DateTime.now().toIso8601String()}'
        .trim();
    setState(() {
      final i = _messages.indexWhere(
        (m) =>
            m.id == messageId ||
            (clientId.isNotEmpty && m.clientId == clientId),
      );
      if (i < 0) return;
      final m = _messages[i];
      if (m.senderId != _myId) return;
      final raw = _ForwardedPayloadParse.stripForDisplay(m.body) ?? m.body;
      final voc = ChatVoiceMessage.tryParse(raw);
      if (voc == null || voc.playedByPeer) return;
      _messages[i] = m.copyWith(
        body: voc.copyWith(playedByPeer: true, playedAtIso: playedAt).encode(),
      );
    });
  }

  void _onIncomingVoiceFirstPlay(_UiMsg msg) {
    if (!mounted) return;
    if (msg.id.startsWith('local:')) return;
    if (_voicePlayedEmitSent.contains(msg.id)) return;
    final raw = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
    final voc = ChatVoiceMessage.tryParse(raw);
    if (voc == null || voc.playedByPeer) return;
    _voicePlayedEmitSent.add(msg.id);
    if (Get.isRegistered<ChatController>()) {
      final s = Get.find<ChatController>().chatSocket;
      final payload = {
        'peerId': _conversationId,
        'conversationId': _conversationId,
        if (_isGroupConversation) 'groupId': _conversationId,
        'messageId': msg.id,
        'chatMessageId': msg.id,
        'senderId': msg.senderId,
        'receiverId': _myId,
        'playedAt': DateTime.now().toIso8601String(),
      };
      // Emit multiple aliases for backend compatibility.
      s?.emit('chat:voice:played', payload);
      s?.emit('voice_message_played', payload);
      s?.emit('chat:voice_message_played', payload);
    }
  }

  bool _involvesPeer(ChatMessageDto m) {
    if (_isGroupConversation) {
      final gid = _conversationId;
      if (gid.isEmpty) return false;
      return (m.groupId?.trim() == gid) || m.recipientId == gid;
    }
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

  bool _isInboundForReadAnchor(_UiMsg m) {
    if (_isGroupConversation) return m.senderId != _myId;
    return m.senderId == widget.contact.id;
  }

  void _recomputeUnreadBoundary() {
    final anchor = _lastReadMessageId?.trim() ?? '';
    if (anchor.isEmpty || _messages.isEmpty) {
      _firstUnreadIndex = null;
      return;
    }
    final anchorIdx = _messages.indexWhere((m) => m.id == anchor);
    if (anchorIdx < 0) {
      _firstUnreadIndex = null;
      return;
    }
    for (var i = anchorIdx + 1; i < _messages.length; i++) {
      if (_isInboundForReadAnchor(_messages[i])) {
        _firstUnreadIndex = i;
        return;
      }
    }
    _firstUnreadIndex = null;
  }

  bool _showUnreadDividerBeforeMessage(int messageIndex) {
    final unreadIdx = _firstUnreadIndex;
    if (unreadIdx == null) return false;
    return messageIndex == unreadIdx;
  }

  Future<void> _applyInitialUnreadOpenPosition() async {
    if (!mounted) return;
    if (!_scroll.hasClients) {
      // Don't block thread rendering if the list is not attached yet.
      _initialOpenPositionApplied = true;
      return;
    }
    final unreadIdx = _firstUnreadIndex;
    if (unreadIdx != null && unreadIdx > 0 && unreadIdx < _messages.length) {
      final anchorId = _messages[unreadIdx - 1].id;
      final ctx = _anchorKeyForMessageId(anchorId).currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.08,
          duration: Duration.zero,
        );
      } else {
        _scrollToLatest(animate: false);
      }
    } else {
      _scrollToLatest(animate: false);
    }
    if (!mounted) return;
    setState(() {
      _initialOpenPositionApplied = true;
    });
    _scheduleFloatingDateUpdate();
  }

  void _maybeMarkLatestVisibleAsRead() {
    if (!_scroll.hasClients) return;
    if (_viewingOlderMessages) return;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!_isInboundForReadAnchor(m)) continue;
      unawaited(_markReadSafe(_conversationId, m.id));
      return;
    }
  }

  void _maybeMarkReadInbound(ChatMessageDto dto) {
    if (!_isGroupConversation && dto.senderId != widget.contact.id) return;
    if (_isGroupConversation) {
      final gid = _conversationId;
      final target = dto.groupId?.trim().isNotEmpty == true
          ? dto.groupId!.trim()
          : dto.recipientId;
      if (target != gid) return;
    }
    if (_viewingOlderMessages) return;
    unawaited(_markReadSafe(_conversationId, dto.id));
  }

  Future<void> _markReadSafe(String peerId, String readUpToId) async {
    try {
      if (_isGroupConversation) {
        await _repo.markGroupMessagesRead(groupId: peerId, readUpToId: readUpToId);
      } else {
        await _repo.markChatMessagesRead(peerId: peerId, readUpToId: readUpToId);
      }
      _lastReadMessageId = readUpToId;
      unawaited(
        ChatThreadLocalStore.saveLastReadMessageId(_conversationId, readUpToId),
      );
      if (mounted) {
        setState(_recomputeUnreadBoundary);
      }
    } catch (_) {}
  }

  Future<void> _syncHistoryWithServer() async {
    if (!mounted) return;
    if (_messages.isEmpty) {
      setState(() => _historyError = null);
    }
    try {
      final list = _isGroupConversation
          ? await _repo.fetchGroupMessages(groupId: _conversationId)
          : await _repo.fetchChatMessages(peerId: widget.contact.id);
      if (!mounted) return;
      setState(() {
        _mergeHistorySnapshot(list);
        _recomputeUnreadBoundary();
        _initialHistorySyncDone = true;
        if (_messages.isNotEmpty) {
          _historyError = null;
        }
        _hasMoreOlder = list.length >= 50;
      });
      _scheduleDocPreviewAutoDownload();
      _flushPendingSocketMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _maybeUpgradeDeliveryFromPeerPresence();
        final initialJump = widget.initialScrollToMessageId?.trim() ?? '';
        if (!_didInitialExternalScroll && initialJump.isNotEmpty) {
          _didInitialExternalScroll = true;
          _initialOpenPositionApplied = true;
          _scrollToQuotedMessage(initialJump);
          _scheduleFloatingDateUpdate();
          return;
        }
        if (!_initialOpenPositionApplied) {
          unawaited(_applyInitialUnreadOpenPosition());
        } else {
          _scrollToLatest(animate: false);
        }
        _maybeMarkLatestVisibleAsRead();
        _scheduleFloatingDateUpdate();
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
      _recomputeUnreadBoundary();
    });
    _scheduleDocPreviewAutoDownload();
    for (final dto in pending) {
      _maybeMarkReadInbound(dto);
    }
    _scrollIfPinned(animate: false);
  }

  _UiMsg _fromHistoryDto(ChatMessageDto m) {
    final mine = m.senderId == _myId;
    OutboundDelivery? outbound;
    if (mine) {
      outbound = m.readAt != null
          ? OutboundDelivery.seen
          : OutboundDelivery.sent;
    }
    return _UiMsg(
      id: m.id,
      clientId: m.clientId ?? '',
      senderId: m.senderId,
      senderName: m.senderName?.trim() ?? '',
      body: m.body,
      createdAt: m.createdAt.toLocal(),
      outbound: outbound,
      replyTo: m.replyTo,
      reactions: m.reactions,
      editedAt: m.editedAt?.toLocal(),
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
    if (!away) {
      _maybeMarkLatestVisibleAsRead();
    }
    _maybeLoadOlder();
    _scheduleFloatingDateUpdate();
  }

  void _scheduleFloatingDateUpdate() {
    _floatingDateThrottleTimer?.cancel();
    _floatingDateThrottleTimer = Timer(const Duration(milliseconds: 20), () {
      _floatingDateThrottleTimer = null;
      if (!mounted) return;
      _recomputeFloatingDateLabel();
    });
  }

  /// Picks the [topmost visible] message row and mirrors its calendar day in [_floatingDateLabel].
  void _recomputeFloatingDateLabel() {
    if (!mounted || _messages.isEmpty) {
      if (_floatingDateLabel.isNotEmpty ||
          _floatingDateSuppressedByVisibleInline) {
        setState(() {
          _floatingDateLabel = '';
          _floatingDateSuppressedByVisibleInline = false;
        });
      }
      return;
    }
    final stackCtx = _chatListAreaKey.currentContext;
    if (stackCtx == null) return;
    final stackBox = stackCtx.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final viewTop = stackBox.localToGlobal(Offset.zero).dy;
    final viewBottom = viewTop + stackBox.size.height;

    _UiMsg? topmost;
    var bestY = double.infinity;
    for (final m in _messages) {
      final ctx = _anchorKeyForMessageId(m.id).currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= viewTop || top >= viewBottom) continue;
      if (top < bestY) {
        bestY = top;
        topmost = m;
      }
    }
    topmost ??= _messages.isNotEmpty ? _messages.last : null;
    if (topmost == null) return;
    final label = _chatDateHeaderLabel(topmost.createdAt);
    final suppressed = _isInlineDateSeparatorVisibleForLabel(
      label,
      viewTop: viewTop,
      viewBottom: viewBottom,
    );
    if (label != _floatingDateLabel ||
        suppressed != _floatingDateSuppressedByVisibleInline) {
      setState(() {
        _floatingDateLabel = label;
        _floatingDateSuppressedByVisibleInline = suppressed;
      });
    }
  }

  bool _isInlineDateSeparatorVisibleForLabel(
    String label, {
    required double viewTop,
    required double viewBottom,
  }) {
    for (var i = 0; i < _messages.length; i++) {
      if (!_isFirstMessageOfItsCalendarDay(i)) continue;
      final msg = _messages[i];
      if (_chatDateHeaderLabel(msg.createdAt) != label) continue;
      final ctx = _dateSeparatorKeyForMessageId(msg.id).currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom > viewTop && top < viewBottom) {
        return true;
      }
    }
    return false;
  }

  void _setUserScrollingMessages(bool scrolling) {
    if (!mounted || _isUserScrollingMessages == scrolling) return;
    setState(() => _isUserScrollingMessages = scrolling);
  }

  void _onScrollStartForFloatingDate() {
    _floatingDateHideTimer?.cancel();
    _setUserScrollingMessages(true);
    _scheduleFloatingDateUpdate();
  }

  void _onScrollEndForFloatingDate() {
    _floatingDateHideTimer?.cancel();
    // Keep the sticky chip briefly after scroll end for WhatsApp-like feel.
    _floatingDateHideTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      _setUserScrollingMessages(false);
    });
    _scheduleFloatingDateUpdate();
  }

  /// Oldest server message id in the list — cursor for `before` pagination.
  String? _oldestServerCursorId() {
    for (final m in _messages) {
      final id = m.id;
      if (id.startsWith('local:')) continue;
      if (id.length == 24) return id;
    }
    return null;
  }

  void _maybeLoadOlder() {
    if (_loadingOlder || !_hasMoreOlder || _messages.isEmpty) return;
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final max = pos.maxScrollExtent;
    if (max <= 0) return;
    const lead = 320.0;
    if (pos.pixels < max - lead) return;
    unawaited(_loadOlderMessages());
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMoreOlder || !mounted) return;
    final before = _oldestServerCursorId();
    if (before == null) return;

    final oldPixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final oldMax = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;

    setState(() => _loadingOlder = true);
    try {
      final page = _isGroupConversation
          ? await _repo.fetchGroupMessages(
              groupId: _conversationId,
              before: before,
              limit: 50,
            )
          : await _repo.fetchChatMessages(
              peerId: widget.contact.id,
              before: before,
              limit: 50,
            );
      if (!mounted) return;
      if (page.isEmpty) {
        setState(() {
          _hasMoreOlder = false;
          _loadingOlder = false;
        });
        return;
      }

      final existing = _messages.map((m) => m.id).toSet();
      final unique = <_UiMsg>[];
      for (final dto in page) {
        if (existing.contains(dto.id)) continue;
        unique.add(_fromHistoryDto(dto));
        existing.add(dto.id);
      }

      if (unique.isEmpty) {
        setState(() {
          _hasMoreOlder = false;
          _loadingOlder = false;
        });
        return;
      }

      setState(() {
        _messages.insertAll(0, unique);
        _sortMessages();
        for (final m in unique) {
          if (!m.id.startsWith('local:')) {
            _serverIds.add(m.id);
          }
        }
        if (page.length < 50) {
          _hasMoreOlder = false;
        }
        _loadingOlder = false;
        _didLoadOlderPage = true;
      });
      _scheduleDocPreviewAutoDownload();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final min = _scroll.position.minScrollExtent;
        final max = _scroll.position.maxScrollExtent;
        final delta = max - oldMax;
        _scroll.jumpTo((oldPixels + delta).clamp(min, max));
        _scheduleFloatingDateUpdate();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  void _scrollIfPinned({bool animate = true}) {
    if (_viewingOlderMessages) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToLatest(animate: animate);
        _scheduleFloatingDateUpdate();
      }
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
    if (mounted && (_peerTyping || _peerVoiceRecording)) {
      setState(() {});
    }
  }

  static const _typingTrueMinGap = Duration(milliseconds: 480);

  /// How long after the last keystroke we tell the peer we stopped typing.
  static const _typingIdleBeforeFalse = Duration(milliseconds: 3000);

  void _onComposerTextChanged(String text) {
    final hasText = text.trim().isNotEmpty;
    if (!hasText) {
      _typingStopTimer?.cancel();
      _lastTypingTrueSent = null;
      _scheduleTypingFalse();
      return;
    }

    final now = DateTime.now();
    final gapOk =
        _lastTypingTrueSent == null ||
        now.difference(_lastTypingTrueSent!) >= _typingTrueMinGap;
    if (gapOk) {
      _emitTyping(true);
      _lastTypingTrueSent = now;
    }

    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(_typingIdleBeforeFalse, () {
      _emitTyping(false);
      _lastTypingTrueSent = null;
    });
  }

  void _scheduleTypingFalse() {
    _typingStopTimer?.cancel();
    _lastTypingTrueSent = null;
    _typingStopTimer = Timer(const Duration(milliseconds: 200), () {
      _emitTyping(false);
    });
  }

  void _emitTyping(bool typing) {
    if (!Get.isRegistered<ChatController>()) return;
    final s = Get.find<ChatController>().chatSocket;
    s?.emit('chat:typing', {
      'peerId': _conversationId,
      'conversationId': _conversationId,
      if (_isGroupConversation) 'groupId': _conversationId,
      'typing': typing,
      'voiceRecording': false,
      'activity': typing ? 'text' : 'none',
      'event': typing ? 'typing_start' : 'typing_stop',
    });
  }

  void _emitVoiceRecording(bool recording) {
    if (!Get.isRegistered<ChatController>()) return;
    final s = Get.find<ChatController>().chatSocket;
    final payload = {
      'peerId': _conversationId,
      'conversationId': _conversationId,
      if (_isGroupConversation) 'groupId': _conversationId,
      'typing': false,
      'voiceRecording': recording,
      'isRecordingVoice': recording,
      'activity': recording ? 'voice' : 'none',
      'activityType': recording ? 'voice_recording' : 'none',
      'event': recording ? 'voice_recording_start' : 'voice_recording_stop',
    };
    s?.emit('chat:typing', payload);
    s?.emit('chat:voice:recording', payload);
    s?.emit('voice_recording', payload);
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

  /// Calendar day in local timezone (handles UTC [createdAt] from server).
  static DateTime _calendarDayLocal(DateTime t) {
    final l = t.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  static bool _isSameCalendarDay(DateTime a, DateTime b) {
    final aa = _calendarDayLocal(a);
    final bb = _calendarDayLocal(b);
    return aa.year == bb.year && aa.month == bb.month && aa.day == bb.day;
  }

  /// Dynamic label from [messageTimestamp]: Today / Yesterday / `d Mon yyyy` (local calendar).
  String _chatDateHeaderLabel(DateTime messageTimestamp) {
    final d = _calendarDayLocal(messageTimestamp);
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (d == today) return 'Today';
    if (d == yesterday) return 'Yesterday';
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// [_messages] is sorted **oldest → newest** (index `0` = oldest in thread).
  /// Show one date chip **above** the **first message of each calendar day** — the day boundary
  /// sits above the **oldest** message of that day (when you scroll up, you hit the chip before
  /// older days). All messages the same day share that single chip; the **newest** row must not
  /// repeat it.
  bool _isFirstMessageOfItsCalendarDay(int messageIndexInThread) {
    if (messageIndexInThread <= 0) return true;
    return !_isSameCalendarDay(
      _messages[messageIndexInThread - 1].createdAt,
      _messages[messageIndexInThread].createdAt,
    );
  }

  Future<void> _send() async {
    if (_editingMessageId != null) {
      await _submitMessageEdit();
      return;
    }
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (_myId.isEmpty) return;

    final pinned = _replyTarget;
    final replyQuote = pinned != null ? _replyQuoteFromTarget(pinned) : null;

    _input.clear();
    _emitTyping(false);
    _typingStopTimer?.cancel();
    _lastTypingTrueSent = null;

    setState(() => _replyTarget = null);

    await _emitOutboundMessage(text, replyQuote: replyQuote);
  }

  Future<void> _emitOutboundMessage(
    String body, {
    required ChatReplyQuote? replyQuote,
  }) async {
    final text = body.trim();
    if (text.isEmpty) return;
    if (_myId.isEmpty) return;

    final clientId = _newClientId();
    final replyToMessageId = replyQuote?.messageId;

    setState(() {
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
          editedAt: null,
        ),
      );
      _sortMessages();
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });

    try {
      final r = await _sendMessageRemote(
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
          outbound: r.peerOnline
              ? OutboundDelivery.delivered
              : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? replyQuote,
          reactions: r.message.reactions,
          editedAt: r.message.editedAt?.toLocal(),
        );
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
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
        _messages[i] = _messages[i].copyWith(
          outbound: OutboundDelivery.sending,
        );
      }
    });

    try {
      final r = await _sendMessageRemote(
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
          outbound: r.peerOnline
              ? OutboundDelivery.delivered
              : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? msg.replyTo,
          reactions: r.message.reactions,
          editedAt: r.message.editedAt?.toLocal(),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    }
  }

  ChatContact _livePeer() {
    if (!Get.isRegistered<ChatController>()) return widget.contact;
    final list = Get.find<ChatController>().contacts;
    for (final c in list) {
      if (c.conversationId == _conversationId || c.id == widget.contact.id) {
        return c;
      }
    }
    return widget.contact;
  }

  String _headerSubtitle(ChatContact peer) {
    if (peer.isGroupConversation) {
      final names = _groupSubtitleNames(peer);
      final online = _groupOnlineCount(peer, names);
      if (names.isEmpty) return '$online online';
      return '$online online · ${names.join(', ')}';
    }
    if (peer.isOnline) return 'Online';
    final s = peer.lastSeenSubtitle;
    if (s != null) return s;
    return 'Offline';
  }

  String _resolveReplySenderLabel(ChatReplyQuote q, ChatContact peer) {
    if (q.senderId == _myId) return 'You';

    final byMessageId = _messages.where((m) => m.id == q.messageId);
    if (byMessageId.isNotEmpty) {
      final matched = byMessageId.first;
      final n = matched.senderName.trim();
      if (n.isNotEmpty) return n;
      if (matched.senderId == _myId) return 'You';
    }

    if (Get.isRegistered<ChatController>()) {
      for (final c in Get.find<ChatController>().contacts) {
        if (!c.isGroupConversation && c.id == q.senderId) {
          final n = c.name.trim();
          if (n.isNotEmpty) return n;
          final e = c.email.trim();
          if (e.isNotEmpty) return e;
        }
      }
    }

    if (_isGroupConversation) return 'Member';
    final fallback = peer.name.trim();
    return fallback.isNotEmpty ? fallback : peer.email;
  }

  /// Group subtitle names: show others first and "You" at the end.
  List<String> _groupSubtitleNames(ChatContact peer) {
    final raw = peer.memberNames
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (raw.isEmpty) return const ['You'];

    final auth = Get.find<AuthRepository>();
    final meName = auth.session?.name.trim() ?? '';
    final meEmail = auth.session?.email.trim() ?? '';
    final meLower = meName.toLowerCase();
    final meEmailLower = meEmail.toLowerCase();
    final seen = <String>{};
    final unique = <String>[];
    for (final n in raw) {
      final key = n.toLowerCase();
      if (!seen.add(key)) continue;
      unique.add(n);
    }

    // Replace only the logged-in user's own label with "You".
    // Keep all other member names exactly as-is.
    int meIndex = -1;
    for (var i = 0; i < unique.length; i++) {
      final key = unique[i].toLowerCase();
      final isMe = key == 'you' ||
          (meLower.isNotEmpty && key == meLower) ||
          (meEmailLower.isNotEmpty && key == meEmailLower);
      if (isMe) {
        meIndex = i;
        break;
      }
    }

    final others = <String>[];
    for (var i = 0; i < unique.length; i++) {
      if (i == meIndex) continue;
      others.add(unique[i]);
    }
    return [...others, 'You'];
  }

  int _groupOnlineCount(ChatContact peer, List<String> subtitleNames) {
    if (!Get.isRegistered<ChatController>()) return 1;
    final contacts = Get.find<ChatController>().contacts;
    final others = subtitleNames
        .where((n) => n.trim().isNotEmpty && n != 'You')
        .map((n) => n.toLowerCase())
        .toSet();
    var onlineOthers = 0;
    for (final c in contacts) {
      if (c.isGroupConversation || !c.isOnline) continue;
      final name = c.name.trim().toLowerCase();
      final email = c.email.trim().toLowerCase();
      if (others.contains(name) || others.contains(email)) {
        onlineOthers += 1;
      }
    }
    // This user is in the open group thread, so include self.
    return onlineOthers + 1;
  }

  @override
  void dispose() {
    _removeReactionOverlayEntryOnly();
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
    _typingStopTimer?.cancel();
    _socketBindRetry?.cancel();
    _peerTypingClear?.cancel();
    _peerVoiceRecordingClear?.cancel();
    _jumpHighlightTimer?.cancel();
    _floatingDateThrottleTimer?.cancel();
    _floatingDateHideTimer?.cancel();
    _unbindSocket();
    _input.removeListener(_onInputChanged);
    _scroll.removeListener(_onScroll);
    _composerFocus.dispose();
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
      subtitle: _replyBodyPreview(
        _ForwardedPayloadParse.stripForDisplay(t.body) ?? t.body,
      ),
      onClose: () => setState(() => _replyTarget = null),
      onNavigateToQuote: () => _scrollToQuotedMessage(t.id),
    );
  }

  Widget? _composerTopBanner(ChatContact peer) {
    if (_editingMessageId != null) {
      return _EditDraftStrip(onClose: _cancelEditingMessage);
    }
    return _replyComposerBanner(peer);
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
      _syncDateSeparatorAnchorKeys();
      return Positioned.fill(
        key: _chatListAreaKey,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: (ScrollNotification n) {
                  if (n.metrics.axis == Axis.vertical) {
                    _maybeLoadOlder();
                    if (n is ScrollStartNotification) {
                      // Show sticky date only for user-driven scroll sessions.
                      if (n.dragDetails != null || _isUserScrollingMessages) {
                        _onScrollStartForFloatingDate();
                      }
                    } else if (n is ScrollUpdateNotification) {
                      _scheduleFloatingDateUpdate();
                    } else if (n is UserScrollNotification) {
                      if (n.direction == ScrollDirection.idle) {
                        _onScrollEndForFloatingDate();
                      } else {
                        _onScrollStartForFloatingDate();
                      }
                    } else if (n is ScrollEndNotification) {
                      _onScrollEndForFloatingDate();
                    } else {
                      _scheduleFloatingDateUpdate();
                    }
                  }
                  return false;
                },
                child: ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  // Reserve space for the typing overlay so it does not cover
                  // the last visible message bubble.
                  padding: EdgeInsets.fromLTRB(
                    8,
                    12,
                    8,
                    _showPeerActivityBubble ? 64 : 10,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final messageIndex = _messages.length - 1 - i;
                    final msg = _messages[messageIndex];
                    final showDateChip = _isFirstMessageOfItsCalendarDay(
                      messageIndex,
                    );
                    final peerLabel = peer.name.trim().isNotEmpty
                        ? peer.name.trim()
                        : peer.email;
                    final q = msg.replyTo;
                    return KeyedSubtree(
                      key: _anchorKeyForMessageId(msg.id),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showDateChip)
                            _ChatDateSeparator(
                              key: _dateSeparatorKeyForMessageId(msg.id),
                              label: _chatDateHeaderLabel(msg.createdAt),
                            ),
                          if (_showUnreadDividerBeforeMessage(messageIndex))
                            const _UnreadMessagesDivider(),
                          _MessageBubble(
                            msg: msg,
                            myId: _myId,
                            peerDisplayName: peerLabel,
                            isGroupConversation: _isGroupConversation,
                            timeLabel: _formatTime(msg.createdAt),
                            selectionHighlight: _selectedMessageIds.contains(
                              msg.id,
                            ),
                            jumpHighlightActive:
                                _jumpHighlightMessageId == msg.id,
                            jumpHighlightPulse: _jumpHighlightPulse,
                            onSelectionTap:
                                _hasMessageSelection &&
                                    !msg.id.startsWith('local:')
                                ? () => _toggleMessageSelection(msg)
                                : null,
                            onRetry: msg.outbound == OutboundDelivery.failed
                                ? () {
                                    final inner =
                                        _ForwardedPayloadParse.stripForDisplay(
                                          msg.body,
                                        ) ??
                                        msg.body;
                                    final vid = ChatVideoMessage.tryParse(
                                      inner,
                                    );
                                    if (vid != null &&
                                        (vid.item.url.isEmpty ||
                                            vid.item.status == 'failed')) {
                                      unawaited(_retryVideoUpload(msg));
                                      return;
                                    }
                                    final img = ChatImageMessage.tryParse(
                                      inner,
                                    );
                                    if (img != null &&
                                        img.items.any(
                                          (e) =>
                                              e.url.isEmpty ||
                                              e.status == 'failed',
                                        )) {
                                      unawaited(_retryImageUpload(msg));
                                    } else {
                                      final voc = ChatVoiceMessage.tryParse(
                                        inner,
                                      );
                                      if (voc != null &&
                                          (voc.url.isEmpty ||
                                              voc.status == 'failed')) {
                                        unawaited(_retryVoiceUpload(msg));
                                        return;
                                      }
                                      final doc = ChatDocumentMessage.tryParse(
                                        inner,
                                      );
                                      if (doc != null &&
                                          (doc.url.isEmpty ||
                                              doc.status == 'failed')) {
                                        unawaited(_retryDocumentUpload(msg));
                                        return;
                                      }
                                      unawaited(_retrySend(msg));
                                    }
                                  }
                                : null,
                            onOpenImageSlot: (slot) => unawaited(
                              _openImageViewerForMessage(msg, slot),
                            ),
                            onOpenVideo: () =>
                                unawaited(_openVideoViewerForMessage(msg)),
                            onOpenDocument: () =>
                                unawaited(_openDocumentForMessage(msg)),
                            onIncomingVoiceFirstPlay: msg.senderId != _myId
                                ? () => _onIncomingVoiceFirstPlay(msg)
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
                                ? () {
                                    final rawBody = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
                                    final poll = ChatPollMessage.tryParse(rawBody);
                                    if (poll != null) return;
                                    _openQuickReactions(
                                      msg,
                                      _anchorKeyForMessageId(msg.id),
                                    );
                                  }
                                : null,
                            onReactionSummaryTap: msg.reactions.isEmpty
                                ? null
                                : () => _showReactionDetailsSheet(msg, peer),
                            onEmailTap: _onMessageEmailTap,
                            onPollVote: (optionId) {
                              final poll = ChatPollMessage.tryParse(msg.body);
                              if (poll == null) return;
                              unawaited(
                                _voteOnPoll(
                                  messageId: msg.id,
                                  optionId: optionId,
                                  poll: poll,
                                ),
                              );
                            },
                            onPollSeeVotes: () {
                              final poll = ChatPollMessage.tryParse(msg.body);
                              if (poll == null) return;
                              Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => PollResultsScreen(
                                    poll: poll,
                                    showEdit: _canEditPollMessage(poll),
                                    onEdit: () async {
                                      await _editPollMessage(msg, poll);
                                    },
                                  ),
                                ),
                              );
                            },
                            replySenderLabelResolver: (q) =>
                                _resolveReplySenderLabel(q, peer),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity:
                        (_isUserScrollingMessages &&
                            _floatingDateLabel.isNotEmpty &&
                            !_floatingDateSuppressedByVisibleInline)
                        ? 1
                        : 0,
                    duration: const Duration(milliseconds: 170),
                    curve: Curves.easeOut,
                    child: _floatingDateLabel.isEmpty
                        ? const SizedBox.shrink()
                        : _FloatingStickyDateChip(label: _floatingDateLabel),
                  ),
                ),
              ),
            ),
            if (_loadingOlder)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  color: kPrimaryBlue,
                ),
              ),
            if (_viewingOlderMessages && _didLoadOlderPage)
              Positioned(
                right: 12,
                bottom: 16,
                child: Material(
                  elevation: 8,
                  color: const Color(0xFF00A884),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _scrollToLatest(animate: true);
                    },
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
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

    return PopScope(
      canPop: !_hasMessageSelection && _editingMessageId == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _hasMessageSelection) {
          _clearMessageSelection();
        } else if (!didPop && _editingMessageId != null) {
          _cancelEditingMessage();
        }
      },
      child: Scaffold(
        backgroundColor: _ChatThreadColors.canvas,
        appBar: AppBar(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: _ChatThreadColors.composerBar,
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () {
              if (_hasMessageSelection) {
                _clearMessageSelection();
              } else if (_editingMessageId != null) {
                _cancelEditingMessage();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: ClipOval(
                      child: peer.groupImage.trim().isNotEmpty
                          ? Image.network(
                              peer.groupImage.trim(),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: kPrimaryBlue.withValues(alpha: 0.9),
                                  ),
                                  child: Center(
                                    child: Text(
                                      initial,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          : DecoratedBox(
                              decoration: BoxDecoration(
                                color: kPrimaryBlue.withValues(alpha: 0.9),
                              ),
                              child: Center(
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: peer.isGroupConversation
                        ? Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F2937),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _ChatThreadColors.composerBar,
                                width: 1.4,
                              ),
                            ),
                            child: const Icon(
                              Icons.groups_2_rounded,
                              size: 8.5,
                              color: Colors.white,
                            ),
                          )
                        : Container(
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
                      softWrap: false,
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
                      maxLines: 1,
                      softWrap: false,
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
            if (_hasMessageSelection) ...[
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded),
                onPressed: _copyFocusedReactionMessage,
              ),
              if (_selectedMessageIds.length == 1) ...[
                Builder(
                  builder: (context) {
                    final m = _singleSelectedMessage();
                    final can = m != null && _canEditMessage(m);
                    if (!can) return const SizedBox.shrink();
                    return IconButton(
                      tooltip: 'Edit',
                      icon: const Icon(Icons.edit_rounded),
                      onPressed: _beginEditingSelectedMessage,
                    );
                  },
                ),
              ],
              IconButton(
                tooltip: 'Forward',
                icon: const Icon(Icons.forward_rounded),
                onPressed: () => unawaited(_forwardFocusedReactionMessage()),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: _clearMessageSelection,
              ),
            ] else ...[
              if (peer.isGroupConversation)
                IconButton(
                  tooltip: 'Group info',
                  icon: const Icon(Icons.info_outline_rounded),
                  onPressed: () async {
                    Get.to(() => GroupInfoScreen(contact: peer));
                  },
                ),
              if (!peer.isGroupConversation) ...[
                IconButton(
                  tooltip: 'Call',
                  icon: const Icon(Icons.call_rounded),
                  onPressed: () => unawaited(
                    _startAudioCallFromToolbar(peer),
                  ),
                ),
              ],
              if (!peer.isGroupConversation)
                IconButton(
                  tooltip: 'Mail',
                  icon: const Icon(Icons.mail_outline_rounded),
                  onPressed: () {
                    final to = peer.email.trim();
                    if (to.isNotEmpty) {
                      unawaited(_openComposeToAddress(to));
                    } else {
                      unawaited(
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => const ComposeScreen(),
                          ),
                        ),
                      );
                    }
                  },
                ),
            ],
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
                          'assets/chat.jpeg',
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                        ),
                      ),
                    ),
                  ),
                  _buildMessageLayer(peer),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 170),
                        curve: Curves.easeOut,
                        offset: _showPeerActivityBubble
                            ? Offset.zero
                            : const Offset(0, 0.12),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 170),
                          curve: Curves.easeOut,
                          opacity: _showPeerActivityBubble ? 1 : 0,
                          child: _PeerTypingConversationBubble(
                            showVoice: _showPeerVoiceRecordingBubble,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _ThreadComposer(
              controller: _input,
              focusNode: _composerFocus,
              replyBanner: _composerTopBanner(peer),
              composerHint: _editingMessageId != null
                  ? 'Update message'
                  : 'Type a message',
              onSend: _send,
              onSendVoice: _sendVoiceMessage,
              onVoiceRecordingChanged: (active) {
                // Voice recording status overrides typing while active.
                _emitTyping(false);
                _emitVoiceRecording(active);
              },
              onAttach: _showAttachmentSheet,
              onTextChanged: _onComposerTextChanged,
            ),
          ],
        ),
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
          (Icons.image_rounded, 'Image', const Color(0xFF2196F3)),
          (Icons.videocam_rounded, 'Video', const Color(0xFFE53935)),
          (Icons.description_rounded, 'Document', const Color(0xFF7C4DFF)),
          (Icons.photo_camera_rounded, 'Camera', const Color(0xFFE91E8C)),
          (Icons.poll_rounded, 'Poll', const Color(0xFF00A884)),
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
                    mainAxisSpacing: 15,
                    crossAxisSpacing: 15,
                    mainAxisExtent: 118,
                  ),
                  itemBuilder: (context, i) {
                    final (icon, label, color) = items[i];
                    return _AttachmentSheetTile(
                      icon: icon,
                      label: label,
                      iconColor: color,
                      tileBackground: Colors.transparent,
                      onTap: () {
                        Navigator.pop(ctx);
                        if (i == 0) {
                          unawaited(_openGalleryPickerAndPreview());
                        } else if (i == 1) {
                          unawaited(_openVideoPickerAndPreview());
                        } else if (i == 2) {
                          _openDocumentPicker();
                        } else if (i == 3) {
                          unawaited(_openCameraForChat());
                        } else if (i == 4) {
                          unawaited(_openCreatePoll());
                        }
                      },
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

  Future<void> _openCreatePoll() async {
    if (!mounted || _myId.isEmpty) return;
    final result = await Navigator.of(context).push<CreatePollResult>(
      MaterialPageRoute(builder: (_) => const CreatePollScreen()),
    );
    if (!mounted || result == null) return;
    await _sendPollMessage(result);
  }

  Future<void> _sendPollMessage(CreatePollResult payload) async {
    final clientId = _newClientId();
    final nowUtc = DateTime.now().toUtc();
    final options = <ChatPollOption>[];
    for (var i = 0; i < payload.options.length; i++) {
      options.add(
        ChatPollOption(
          optionId: 'opt_${i + 1}_${DateTime.now().microsecondsSinceEpoch}',
          text: payload.options[i],
          voteCount: 0,
        ),
      );
    }
    final poll = ChatPollMessage(
      pollId: 'poll_${DateTime.now().microsecondsSinceEpoch}',
      question: payload.question,
      options: options,
      votes: const [],
      createdBy: _myId,
      createdAtUtc: nowUtc,
      endsAtUtc: payload.endsAtUtc,
      allowMultipleAnswers: false,
      visibleAnswers: payload.visibleAnswers,
      status: 'active',
    );
    final replyQuote = _replyTarget != null ? _replyQuoteFromTarget(_replyTarget!) : null;
    setState(() {
      _messages.add(
        _UiMsg(
          id: 'local:$clientId',
          clientId: clientId,
          senderId: _myId,
          body: poll.encode(),
          createdAt: DateTime.now(),
          outbound: OutboundDelivery.sending,
          replyTo: replyQuote,
          reactions: const [],
          editedAt: null,
        ),
      );
      _replyTarget = null;
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });
    try {
      final sent = _isGroupConversation
          ? await _repo.sendGroupMessage(
              groupId: _conversationId,
              body: poll.encode(),
              clientId: clientId,
              replyToMessageId: replyQuote?.messageId,
            )
          : await _repo.sendChatMessage(
              peerId: _conversationId,
              body: poll.encode(),
              clientId: clientId,
              replyToMessageId: replyQuote?.messageId,
            );
      if (!mounted) return;
      setState(() => _ingestRemoteDto(sent.message));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((m) => m.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(outbound: OutboundDelivery.failed);
        }
      });
    }
  }

  Future<void> _voteOnPoll({
    required String messageId,
    required String optionId,
    required ChatPollMessage poll,
  }) async {
    if (messageId.startsWith('local:')) return;
    final oldVotes = List<ChatPollVote>.from(poll.votes);
    final optimisticVotes = oldVotes.where((v) => v.userId != _myId).toList()
      ..add(
        ChatPollVote(
          userId: _myId,
          optionId: optionId,
          votedAtUtc: DateTime.now().toUtc(),
          userName: 'You',
        ),
      );
    final optimisticOptions = poll.options
        .map(
          (o) => o.copyWith(
            voteCount: optimisticVotes.where((v) => v.optionId == o.optionId).length,
          ),
        )
        .toList();
    setState(() {
      final i = _messages.indexWhere((m) => m.id == messageId);
      if (i < 0) return;
      final parsed = ChatPollMessage.tryParse(_messages[i].body);
      if (parsed == null) return;
      _messages[i] = _messages[i].copyWith(
        body: parsed.copyWith(votes: optimisticVotes, options: optimisticOptions).encode(),
      );
    });
    try {
      final dto = _isGroupConversation
          ? await _repo.voteGroupPoll(
              groupId: _conversationId,
              messageId: messageId,
              optionId: optionId,
            )
          : await _repo.voteDirectPoll(
              peerId: _conversationId,
              messageId: messageId,
              optionId: optionId,
            );
      if (!mounted) return;
      setState(() => _ingestRemoteDto(dto));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((m) => m.id == messageId);
        if (i < 0) return;
        final parsed = ChatPollMessage.tryParse(_messages[i].body);
        if (parsed == null) return;
        _messages[i] = _messages[i].copyWith(body: parsed.copyWith(votes: oldVotes).encode());
      });
      _showThreadSnackBar(
        SnackBar(
          content: Text('Could not vote right now', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static const int _kMaxChatImages = 4;
  static const int _kMaxChatVideoBytes = 20 * 1024 * 1024;

  Future<void> _openVideoPickerAndPreview() async {
    if (!mounted || _myId.isEmpty) return;
    final pick = ImagePicker();
    final file = await pick.pickVideo(source: ImageSource.gallery);
    if (!mounted || file == null) return;
    final len = await File(file.path).length();
    if (len > _kMaxChatVideoBytes) {
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text(
              'Video must be under 20 MB',
              style: GoogleFonts.ptSans(),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final r = await Navigator.of(context).push<ChatVideoPreviewResult>(
      MaterialPageRoute(builder: (_) => ChatVideoPreviewScreen(file: file)),
    );
    if (!mounted || r == null) return;
    await _sendVideoMessage(r.file, r.caption);
  }

  Future<void> _openGalleryPickerAndPreview() async {
    if (!mounted || _myId.isEmpty) return;
    final pick = ImagePicker();
    final list = await pick.pickMultiImage(
      imageQuality: 85,
      limit: _kMaxChatImages,
    );
    if (!mounted || list.isEmpty) return;
    final capped = list.length > _kMaxChatImages
        ? list.sublist(0, _kMaxChatImages)
        : list;
    final r = await Navigator.of(context).push<ChatImagePreviewResult>(
      MaterialPageRoute(
        builder: (_) => ChatImagePreviewScreen(
          initialFiles: capped,
          maxImages: _kMaxChatImages,
        ),
      ),
    );
    if (!mounted || r == null || r.files.isEmpty) return;
    await _sendImageMessage(r.files, r.caption);
  }

  Future<void> _openCameraForChat() async {
    if (!mounted || _myId.isEmpty) return;
    final pick = ImagePicker();
    final file = await pick.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (!mounted || file == null) return;
    final r = await Navigator.of(context).push<ChatImagePreviewResult>(
      MaterialPageRoute(
        builder: (_) => ChatImagePreviewScreen(
          initialFiles: [file],
          maxImages: _kMaxChatImages,
        ),
      ),
    );
    if (!mounted || r == null || r.files.isEmpty) return;
    await _sendImageMessage(r.files, r.caption);
  }

  void _openDocumentPicker() {
    if (!mounted || _myId.isEmpty) return;
    unawaited(_pickAndSendDocument());
  }

  Future<void> _pickAndSendDocument() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.any,
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;
    final f = picked.files.single;
    final path = f.path ?? '';
    if (path.trim().isEmpty) return;
    await _sendDocumentMessage(f);
  }

  Future<void> _sendImageMessage(List<XFile> files, String caption) async {
    if (_myId.isEmpty || files.isEmpty) return;
    final clientId = _newClientId();
    final pinned = _replyTarget;
    final replyQuote = pinned != null ? _replyQuoteFromTarget(pinned) : null;
    final items = <ChatImageItem>[];
    for (final f in files) {
      final bytes = await f.readAsBytes();
      final h = sha256.convert(bytes);
      items.add(
        ChatImageItem(
          hash: h.toString(),
          sizeBytes: bytes.length,
          url: '',
          localPath: f.path,
          status: 'uploading',
          progress: 0,
        ),
      );
    }
    final env = ChatImageMessage(caption: caption.trim(), items: items);
    setState(() {
      _messages.add(
        _UiMsg(
          id: 'local:$clientId',
          clientId: clientId,
          senderId: _myId,
          body: env.encode(),
          createdAt: DateTime.now(),
          outbound: OutboundDelivery.sending,
          replyTo: replyQuote,
          reactions: const [],
          editedAt: null,
        ),
      );
      _replyTarget = null;
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });
    unawaited(_uploadAndSendImageMessage(clientId));
  }

  Future<void> _sendVideoMessage(XFile file, String caption) async {
    if (_myId.isEmpty) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > _kMaxChatVideoBytes) {
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text(
              'Video must be under 20 MB',
              style: GoogleFonts.ptSans(),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final clientId = _newClientId();
    final pinned = _replyTarget;
    final replyQuote = pinned != null ? _replyQuoteFromTarget(pinned) : null;
    final h = sha256.convert(bytes);
    final item = ChatImageItem(
      hash: h.toString(),
      sizeBytes: bytes.length,
      url: '',
      localPath: file.path,
      status: 'uploading',
      progress: 0,
    );
    final env = ChatVideoMessage(caption: caption.trim(), item: item);
    setState(() {
      _messages.add(
        _UiMsg(
          id: 'local:$clientId',
          clientId: clientId,
          senderId: _myId,
          body: env.encode(),
          createdAt: DateTime.now(),
          outbound: OutboundDelivery.sending,
          replyTo: replyQuote,
          reactions: const [],
          editedAt: null,
        ),
      );
      _replyTarget = null;
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });
    unawaited(_uploadAndSendVideoMessage(clientId));
  }

  Future<void> _sendDocumentMessage(PlatformFile file) async {
    if (_myId.isEmpty) return;
    final p = file.path ?? '';
    if (p.trim().isEmpty) return;
    final bytes = await File(p).readAsBytes();
    if (bytes.isEmpty) return;
    final name = (file.name).trim().isEmpty ? 'document' : file.name.trim();
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : '';
    final h = sha256.convert(bytes).toString();
    final clientId = _newClientId();
    final pinned = _replyTarget;
    final replyQuote = pinned != null ? _replyQuoteFromTarget(pinned) : null;
    int? pages;
    if (ext == 'pdf') {
      // Page count can be unknown until preview/download; keep null if unavailable.
      pages = null;
    }
    final env = ChatDocumentMessage(
      hash: h,
      sizeBytes: bytes.length,
      url: '',
      name: name,
      ext: ext,
      mimeType: file.extension == 'pdf' ? 'application/pdf' : null,
      pages: pages,
      localPath: p,
      status: 'uploading',
      progress: 0,
    );
    setState(() {
      _messages.add(
        _UiMsg(
          id: 'local:$clientId',
          clientId: clientId,
          senderId: _myId,
          body: env.encode(),
          createdAt: DateTime.now(),
          outbound: OutboundDelivery.sending,
          replyTo: replyQuote,
          reactions: const [],
          editedAt: null,
        ),
      );
      _replyTarget = null;
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });
    unawaited(_uploadAndSendDocumentMessage(clientId));
  }

  List<int> _buildVoiceWaveform(List<int> bytes, {required Duration duration}) {
    final dynamicBars = (duration.inMilliseconds / 240).round().clamp(24, 56);
    if (bytes.isEmpty) {
      return List<int>.filled(dynamicBars, 28);
    }
    final out = <int>[];
    final stride = max(1, bytes.length ~/ dynamicBars);
    var smooth = 0.0;
    for (var i = 0; i < dynamicBars; i++) {
      final start = i * stride;
      if (start >= bytes.length) {
        out.add(20);
        continue;
      }
      final end = min(bytes.length, start + stride);
      var sum = 0;
      for (var j = start; j < end; j++) {
        sum += (bytes[j] - 128).abs();
      }
      final avg = sum / max(1, end - start);
      // Low-pass smoothing gives a more bass-like flowing pattern.
      smooth = (smooth * 0.68) + (avg * 0.32);
      final level = ((smooth / 128) * 100).round().clamp(8, 100);
      out.add(level);
    }
    return out;
  }

  Future<void> _sendVoiceMessage(String localPath, Duration duration) async {
    if (_myId.isEmpty) return;
    final file = File(localPath);
    if (!file.existsSync()) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;

    final clientId = _newClientId();
    final pinned = _replyTarget;
    final replyQuote = pinned != null ? _replyQuoteFromTarget(pinned) : null;
    final h = sha256.convert(bytes).toString();
    final env = ChatVoiceMessage(
      hash: h,
      sizeBytes: bytes.length,
      url: '',
      localPath: localPath,
      durationMs: duration.inMilliseconds,
      waveform: _buildVoiceWaveform(bytes, duration: duration),
      status: 'uploading',
      progress: 0,
    );
    setState(() {
      _messages.add(
        _UiMsg(
          id: 'local:$clientId',
          clientId: clientId,
          senderId: _myId,
          body: env.encode(),
          createdAt: DateTime.now(),
          outbound: OutboundDelivery.sending,
          replyTo: replyQuote,
          reactions: const [],
          editedAt: null,
        ),
      );
      _replyTarget = null;
    });
    _viewingOlderMessages = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(animate: true);
    });
    unawaited(_uploadAndSendVoiceMessage(clientId));
  }

  void _patchVoiceMessageByClientId(
    String clientId,
    ChatVoiceMessage Function(ChatVoiceMessage) fn,
  ) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == clientId);
      if (i < 0) return;
      final cur = ChatVoiceMessage.tryParse(_messages[i].body);
      if (cur == null) return;
      final next = fn(cur);
      _messages[i] = _messages[i].copyWith(body: next.encode());
    });
  }

  void _patchDocumentMessageByClientId(
    String clientId,
    ChatDocumentMessage Function(ChatDocumentMessage) fn,
  ) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == clientId);
      if (i < 0) return;
      final cur = ChatDocumentMessage.tryParse(_messages[i].body);
      if (cur == null) return;
      final next = fn(cur);
      _messages[i] = _messages[i].copyWith(body: next.encode());
    });
  }

  void _patchDocumentMessageById(
    String messageId,
    ChatDocumentMessage Function(ChatDocumentMessage) fn,
  ) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.id == messageId);
      if (i < 0) return;
      final cur = ChatDocumentMessage.tryParse(_messages[i].body);
      if (cur == null) return;
      final next = fn(cur);
      _messages[i] = _messages[i].copyWith(body: next.encode());
    });
  }

  void _scheduleDocPreviewAutoDownload() {
    if (!mounted) return;
    if (_docPreviewAutoScanRunning) return;
    unawaited(_autoDownloadDocPreviews());
  }

  Future<void> _autoDownloadDocPreviews() async {
    if (!mounted || _docPreviewAutoScanRunning) return;
    _docPreviewAutoScanRunning = true;
    try {
      const imageExts = <String>{
        'jpg',
        'jpeg',
        'png',
        'gif',
        'bmp',
        'webp',
        'heic',
        'heif',
        'tiff',
        'tif',
      };
      final snapshot = List<_UiMsg>.from(_messages);
      for (final msg in snapshot) {
        if (!mounted) return;
        final inner = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
        final doc = ChatDocumentMessage.tryParse(inner);
        if (doc == null) continue;
        final ext = doc.ext.trim().toLowerCase();
        final isPreviewDoc = doc.isPdf || ext == 'pdf' || imageExts.contains(ext);
        if (!isPreviewDoc) continue;
        final localPath = doc.localPath?.trim() ?? '';
        if (localPath.isNotEmpty && File(localPath).existsSync()) {
          final doneKey = doc.hash.trim().isNotEmpty ? doc.hash.trim() : msg.id;
          _docPreviewAutoDownloaded.add(doneKey);
          final cacheKey = doc.hash.trim().isNotEmpty ? doc.hash.trim() : doc.url.trim();
          if (cacheKey.isNotEmpty) {
            chatDocumentFileCache[cacheKey] = localPath;
          }
          continue;
        }
        final url = doc.url.trim();
        if (url.isEmpty) continue;
        final cacheKey = doc.hash.trim().isNotEmpty ? doc.hash.trim() : url;
        if (chatDocumentFileCache.containsKey(cacheKey)) {
          final cached = chatDocumentFileCache[cacheKey]!;
          if (File(cached).existsSync()) {
            _patchDocumentMessageById(
              msg.id,
              (e) => e.copyWith(localPath: cached, status: 'done'),
            );
            _docPreviewAutoDownloaded.add(cacheKey);
            continue;
          }
          chatDocumentFileCache.remove(cacheKey);
        }
        final key = doc.hash.trim().isNotEmpty ? doc.hash.trim() : url;
        if (_docPreviewAutoDownloaded.contains(key) ||
            _docPreviewAutoInFlight.contains(key)) {
          continue;
        }
        _docPreviewAutoInFlight.add(key);
        try {
          final bytes = await Get.find<ChatMediaRepository>().downloadUrl(url);
          if (bytes.isEmpty) continue;
          final fileNameBase =
              (doc.name.trim().isEmpty ? 'document' : doc.name.trim())
                  .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final suffix = ext.isEmpty ? '' : '.$ext';
          final hashPrefix = doc.hash.length <= 10
              ? doc.hash
              : doc.hash.substring(0, 10);
          final dir = await getApplicationDocumentsDirectory();
          final savePath = '${dir.path}/doc_${hashPrefix}_$fileNameBase$suffix';
          final out = File(savePath);
          await out.writeAsBytes(bytes, flush: true);
          chatDocumentFileCache[key] = savePath;
          _patchDocumentMessageById(
            msg.id,
            (e) => e.copyWith(localPath: savePath, status: 'done'),
          );
          _docPreviewAutoDownloaded.add(key);
        } catch (_) {
          // Silent background prefetch; user-triggered open still handles fallback.
        } finally {
          _docPreviewAutoInFlight.remove(key);
        }
      }
    } finally {
      _docPreviewAutoScanRunning = false;
    }
  }

  Future<void> _uploadAndSendDocumentMessage(String clientId) async {
    final media = Get.find<ChatMediaRepository>();
    var idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    var env = ChatDocumentMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final fPath = env.localPath?.trim() ?? '';
    if (fPath.isEmpty) return;
    final file = XFile(fPath);

    try {
      final up = await media.uploadImage(
        file,
        onSendProgress: (a, b) {
          if (b <= 0) return;
          final p = (a / b).clamp(0.0, 1.0);
          _patchDocumentMessageByClientId(
            clientId,
            (e) => e.copyWith(progress: p, status: 'uploading'),
          );
        },
      );
      _patchDocumentMessageByClientId(
        clientId,
        (e) => e.copyWith(
          url: up.url,
          hash: up.hash,
          sizeBytes: up.size,
          progress: 1,
          status: 'done',
        ),
      );
    } catch (_) {
      _patchDocumentMessageByClientId(
        clientId,
        (e) => e.copyWith(progress: 0, status: 'failed'),
      );
      if (mounted) {
        setState(() {
          final j = _messages.indexWhere((x) => x.clientId == clientId);
          if (j >= 0) {
            _messages[j] = _messages[j].copyWith(
              outbound: OutboundDelivery.failed,
            );
          }
        });
      }
      return;
    }

    idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    env = ChatDocumentMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final serverBody = ChatDocumentMessage(
      hash: env.hash,
      sizeBytes: env.sizeBytes,
      url: env.url,
      name: env.name,
      ext: env.ext,
      mimeType: env.mimeType,
      pages: env.pages,
    ).encode(forServer: true);
    final replyToMessageId = _messages[idx].replyTo?.messageId;
    try {
      final r = await _sendMessageRemote(
        body: serverBody,
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
          outbound: r.peerOnline
              ? OutboundDelivery.delivered
              : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? _messages[i].replyTo,
          reactions: r.message.reactions,
          editedAt: r.message.editedAt?.toLocal(),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    }
  }

  Future<void> _retryDocumentUpload(_UiMsg msg) async {
    if (msg.clientId.isEmpty) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == msg.clientId);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(
          outbound: OutboundDelivery.sending,
        );
      }
    });
    await _uploadAndSendDocumentMessage(msg.clientId);
  }

  Future<void> _uploadAndSendVoiceMessage(String clientId) async {
    final media = Get.find<ChatMediaRepository>();
    var idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    var env = ChatVoiceMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final fPath = env.localPath?.trim() ?? '';
    if (fPath.isEmpty) return;
    final file = XFile(fPath);

    try {
      final up = await media.uploadImage(
        file,
        onSendProgress: (a, b) {
          if (b <= 0) return;
          final p = (a / b).clamp(0.0, 1.0);
          _patchVoiceMessageByClientId(
            clientId,
            (e) => e.copyWith(progress: p, status: 'uploading'),
          );
        },
      );
      _patchVoiceMessageByClientId(
        clientId,
        (e) => e.copyWith(
          url: up.url,
          hash: up.hash,
          sizeBytes: up.size,
          progress: 1,
          status: 'done',
        ),
      );
    } catch (_) {
      _patchVoiceMessageByClientId(
        clientId,
        (e) => e.copyWith(progress: 0, status: 'failed'),
      );
      if (mounted) {
        setState(() {
          final j = _messages.indexWhere((x) => x.clientId == clientId);
          if (j >= 0) {
            _messages[j] = _messages[j].copyWith(
              outbound: OutboundDelivery.failed,
            );
          }
        });
      }
      return;
    }

    idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    env = ChatVoiceMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final serverBody = ChatVoiceMessage(
      hash: env.hash,
      sizeBytes: env.sizeBytes,
      url: env.url,
      durationMs: env.durationMs,
      waveform: env.waveform,
    ).encode(forServer: true);

    final replyToMessageId = _messages[idx].replyTo?.messageId;
    try {
      final r = await _sendMessageRemote(
        body: serverBody,
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
          outbound: r.peerOnline
              ? OutboundDelivery.delivered
              : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? _messages[i].replyTo,
          reactions: r.message.reactions,
          editedAt: r.message.editedAt?.toLocal(),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    }
  }

  Future<void> _retryVoiceUpload(_UiMsg msg) async {
    if (msg.clientId.isEmpty) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == msg.clientId);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(
          outbound: OutboundDelivery.sending,
        );
      }
    });
    await _uploadAndSendVoiceMessage(msg.clientId);
  }

  void _patchVideoMessageByClientId(
    String clientId,
    ChatVideoMessage Function(ChatVideoMessage) fn,
  ) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == clientId);
      if (i < 0) return;
      final cur = ChatVideoMessage.tryParse(_messages[i].body);
      if (cur == null) return;
      final next = fn(cur);
      _messages[i] = _messages[i].copyWith(body: next.encode());
    });
  }

  Future<void> _uploadAndSendVideoMessage(String clientId) async {
    final media = Get.find<ChatMediaRepository>();
    var idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    var env = ChatVideoMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    var item = env.item;

    final fPath = item.localPath;
    if (fPath == null || fPath.isEmpty) return;
    final file = XFile(fPath);
    try {
      final up = await media.uploadImage(
        file,
        onSendProgress: (a, b) {
          if (b <= 0) return;
          final p = (a / b).clamp(0.0, 1.0);
          _patchVideoMessageByClientId(clientId, (e) {
            return e.copyWith(
              item: e.item.copyWith(progress: p, status: 'uploading'),
            );
          });
        },
      );
      item = item.copyWith(
        url: up.url,
        hash: up.hash,
        sizeBytes: up.size,
        status: 'done',
        progress: 1,
      );
      _patchVideoMessageByClientId(clientId, (e) => e.copyWith(item: item));
    } catch (_) {
      item = item.copyWith(status: 'failed', progress: 0);
      _patchVideoMessageByClientId(clientId, (e) => e.copyWith(item: item));
      if (mounted) {
        setState(() {
          final j = _messages.indexWhere((x) => x.clientId == clientId);
          if (j >= 0) {
            _messages[j] = _messages[j].copyWith(
              outbound: OutboundDelivery.failed,
            );
          }
        });
      }
      return;
    }

    idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    env = ChatVideoMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final serverBody = ChatVideoMessage(
      caption: env.caption,
      item: ChatImageItem(
        hash: env.item.hash,
        sizeBytes: env.item.sizeBytes,
        url: env.item.url,
      ),
    ).encode(forServer: true);

    final replyToMessageId = _messages[idx].replyTo?.messageId;

    try {
      final r = await _sendMessageRemote(
        body: serverBody,
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
          outbound: r.peerOnline
              ? OutboundDelivery.delivered
              : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? _messages[i].replyTo,
          reactions: r.message.reactions,
          editedAt: r.message.editedAt?.toLocal(),
        );
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    }
  }

  Future<void> _retryVideoUpload(_UiMsg msg) async {
    if (msg.clientId.isEmpty) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == msg.clientId);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(
          outbound: OutboundDelivery.sending,
        );
      }
    });
    await _uploadAndSendVideoMessage(msg.clientId);
  }

  Future<void> _openVideoViewerForMessage(_UiMsg msg) async {
    final inner = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
    final env = ChatVideoMessage.tryParse(inner);
    if (env == null) return;
    final it = env.item;
    String? path;
    final lp = it.localPath?.trim() ?? '';
    if (lp.isNotEmpty && File(lp).existsSync()) {
      path = lp;
    } else {
      final h = it.hash.trim().toLowerCase();
      if (h.isNotEmpty && chatVideoFileCache.containsKey(h)) {
        final c = chatVideoFileCache[h]!;
        if (File(c).existsSync()) path = c;
      }
      if (path == null) {
        final url = it.url.trim();
        if (url.isEmpty || !mounted) return;
        try {
          final dir = await getTemporaryDirectory();
          final p = '${dir.path}/chat_vid_$h.mp4';
          if (!File(p).existsSync()) {
            final bytes = await Get.find<ChatMediaRepository>().downloadUrl(
              url,
            );
            await File(p).writeAsBytes(bytes);
          }
          chatVideoFileCache[h] = p;
          path = p;
        } catch (_) {
          return;
        }
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatVideoViewerScreen(localPath: path!),
      ),
    );
  }

  void _patchImageMessageByClientId(
    String clientId,
    ChatImageMessage Function(ChatImageMessage) fn,
  ) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == clientId);
      if (i < 0) return;
      final cur = ChatImageMessage.tryParse(_messages[i].body);
      if (cur == null) return;
      final next = fn(cur);
      _messages[i] = _messages[i].copyWith(body: next.encode());
    });
  }

  Future<void> _uploadAndSendImageMessage(String clientId) async {
    final media = Get.find<ChatMediaRepository>();
    var idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    var env = ChatImageMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final nextItems = List<ChatImageItem>.from(env.items);

    for (var k = 0; k < nextItems.length; k++) {
      final fPath = nextItems[k].localPath;
      if (fPath == null || fPath.isEmpty) continue;
      final file = XFile(fPath);
      try {
        final up = await media.uploadImage(
          file,
          onSendProgress: (a, b) {
            if (b <= 0) return;
            final p = (a / b).clamp(0.0, 1.0);
            _patchImageMessageByClientId(clientId, (e) {
              final it = List<ChatImageItem>.from(e.items);
              if (k < it.length) {
                it[k] = it[k].copyWith(progress: p, status: 'uploading');
              }
              return e.copyWith(items: it);
            });
          },
        );
        nextItems[k] = nextItems[k].copyWith(
          url: up.url,
          hash: up.hash,
          sizeBytes: up.size,
          status: 'done',
          progress: 1,
        );
      } catch (_) {
        nextItems[k] = nextItems[k].copyWith(status: 'failed', progress: 0);
        _patchImageMessageByClientId(
          clientId,
          (e) => e.copyWith(items: List<ChatImageItem>.from(nextItems)),
        );
        if (mounted) {
          setState(() {
            final j = _messages.indexWhere((x) => x.clientId == clientId);
            if (j >= 0) {
              _messages[j] = _messages[j].copyWith(
                outbound: OutboundDelivery.failed,
              );
            }
          });
        }
        return;
      }
      _patchImageMessageByClientId(
        clientId,
        (e) => e.copyWith(items: List<ChatImageItem>.from(nextItems)),
      );
    }

    idx = _messages.indexWhere((x) => x.clientId == clientId);
    if (idx < 0) return;
    env = ChatImageMessage.tryParse(_messages[idx].body);
    if (env == null) return;
    final serverBody = ChatImageMessage(
      caption: env.caption,
      items: env.items
          .map(
            (e) =>
                ChatImageItem(hash: e.hash, sizeBytes: e.sizeBytes, url: e.url),
          )
          .toList(),
    ).encode(forServer: true);

    final replyToMessageId = _messages[idx].replyTo?.messageId;

    try {
      final r = await _sendMessageRemote(
        body: serverBody,
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
          outbound: r.peerOnline
              ? OutboundDelivery.delivered
              : OutboundDelivery.sent,
          replyTo: r.message.replyTo ?? _messages[i].replyTo,
          reactions: r.message.reactions,
          editedAt: r.message.editedAt?.toLocal(),
        );
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere((x) => x.clientId == clientId);
        if (i >= 0) {
          _messages[i] = _messages[i].copyWith(
            outbound: OutboundDelivery.failed,
          );
        }
      });
    }
  }

  Future<void> _retryImageUpload(_UiMsg msg) async {
    if (msg.clientId.isEmpty) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.clientId == msg.clientId);
      if (i >= 0) {
        _messages[i] = _messages[i].copyWith(
          outbound: OutboundDelivery.sending,
        );
      }
    });
    await _uploadAndSendImageMessage(msg.clientId);
  }

  Future<void> _openImageViewerForMessage(_UiMsg msg, int tapIndex) async {
    final inner = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
    final env = ChatImageMessage.tryParse(inner);
    if (env == null) return;
    final paths = <String>[];
    for (final it in env.items) {
      final lp = it.localPath?.trim() ?? '';
      if (lp.isNotEmpty && File(lp).existsSync()) {
        paths.add(lp);
        continue;
      }
      final h = it.hash.trim().toLowerCase();
      if (h.isNotEmpty && chatImageFileCache.containsKey(h)) {
        final c = chatImageFileCache[h]!;
        if (File(c).existsSync()) {
          paths.add(c);
          continue;
        }
      }
      final url = it.url.trim();
      if (url.isEmpty) continue;
      try {
        final dir = await getTemporaryDirectory();
        final p = '${dir.path}/chat_img_$h.jpg';
        if (!File(p).existsSync()) {
          final bytes = await Get.find<ChatMediaRepository>().downloadUrl(url);
          await File(p).writeAsBytes(bytes);
        }
        chatImageFileCache[h] = p;
        paths.add(p);
      } catch (_) {}
    }
    if (paths.isEmpty || !mounted) return;
    final start = tapIndex.clamp(0, paths.length - 1);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatImageViewerScreen(paths: paths, initialIndex: start),
      ),
    );
  }

  Future<void> _openDocumentForMessage(_UiMsg msg) async {
    final inner = _ForwardedPayloadParse.stripForDisplay(msg.body) ?? msg.body;
    final doc = ChatDocumentMessage.tryParse(inner);
    if (doc == null) return;

    final ext = doc.ext.trim().toLowerCase();
    final imageExts = <String>{
      'jpg',
      'jpeg',
      'png',
      'gif',
      'bmp',
      'webp',
      'heic',
      'heif',
      'tiff',
      'tif',
    };
    final isImage = imageExts.contains(ext);
    final isPdf = doc.isPdf || ext == 'pdf';
    final fileNameBase = (doc.name.trim().isEmpty ? 'document' : doc.name.trim())
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final suffix = ext.isEmpty ? '' : '.$ext';
    final hashPrefix = doc.hash.length <= 10 ? doc.hash : doc.hash.substring(0, 10);
    final docsDir = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    final stableSavePath = '${docsDir.path}/doc_${hashPrefix}_$fileNameBase$suffix';
    Future<void> ensureVisibleInDownloadsIfNeeded(String sourcePath) async {
      if (isImage || isPdf) return;
      final fileName = suffix.isEmpty ? fileNameBase : '$fileNameBase$suffix';
      try {
        final downloadsDir = await downloads_folder.getDownloadDirectory();
        final publicPath = '${downloadsDir.path}/$fileName';
        final existsInDownloads = File(publicPath).existsSync();
        if (!existsInDownloads) {
          await downloads_folder.copyFileIntoDownloadFolder(sourcePath, fileName);
        }
      } catch (_) {
        // Best-effort copy to public Downloads; keep primary flow intact.
      }
    }

    final localPath = doc.localPath?.trim() ?? '';
    if (localPath.isNotEmpty && File(localPath).existsSync()) {
      final existingKey = doc.hash.trim().isNotEmpty ? doc.hash.trim() : doc.url.trim();
      if (existingKey.isNotEmpty) {
        chatDocumentFileCache[existingKey] = localPath;
      }
      if (isImage) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatImageViewerScreen(paths: [localPath], initialIndex: 0),
          ),
        );
        return;
      }
      if (isPdf) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatPdfViewerScreen(path: localPath, title: doc.name),
          ),
        );
        return;
      }
      try {
        if (!File(stableSavePath).existsSync()) {
          await File(localPath).copy(stableSavePath);
        }
        await ensureVisibleInDownloadsIfNeeded(stableSavePath);
        if (existingKey.isNotEmpty) {
          chatDocumentFileCache[existingKey] = stableSavePath;
        }
        if (mounted) {
          _showThreadSnackBar(
            SnackBar(
              content: Text('File already available on device', style: GoogleFonts.ptSans()),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          _showThreadSnackBar(
            SnackBar(
              content: Text('Could not save file', style: GoogleFonts.ptSans()),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
      return;
    }

    final url = doc.url.trim();
    final cacheKey = doc.hash.trim().isNotEmpty ? doc.hash.trim() : url;

    if (cacheKey.isNotEmpty && chatDocumentFileCache.containsKey(cacheKey)) {
      final cached = chatDocumentFileCache[cacheKey]!;
      if (File(cached).existsSync()) {
        if (isImage) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ChatImageViewerScreen(paths: [cached], initialIndex: 0),
            ),
          );
          return;
        }
        if (isPdf) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ChatPdfViewerScreen(path: cached, title: doc.name),
            ),
          );
          return;
        }
        if (mounted) {
          _showThreadSnackBar(
            SnackBar(
              content: Text('File already downloaded', style: GoogleFonts.ptSans()),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        await ensureVisibleInDownloadsIfNeeded(cached);
        return;
      } else {
        chatDocumentFileCache.remove(cacheKey);
      }
    }

    if (File(stableSavePath).existsSync()) {
      if (cacheKey.isNotEmpty) {
        chatDocumentFileCache[cacheKey] = stableSavePath;
      }
      if (isImage) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                ChatImageViewerScreen(paths: [stableSavePath], initialIndex: 0),
          ),
        );
        return;
      }
      if (isPdf) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatPdfViewerScreen(path: stableSavePath, title: doc.name),
          ),
        );
        return;
      }
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text('File already downloaded', style: GoogleFonts.ptSans()),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      await ensureVisibleInDownloadsIfNeeded(stableSavePath);
      return;
    }

    if (url.isEmpty) {
      if (mounted) {
        _showThreadSnackBar(
          SnackBar(
            content: Text('Document is not available yet', style: GoogleFonts.ptSans()),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final progress = ValueNotifier<double?>(null);
    try {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return PopScope(
              canPop: false,
              child: AlertDialog(
                backgroundColor: const Color(0xFF0F172A),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                content: ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (_, v, _) {
                    final pct = v == null ? null : (v * 100).clamp(0, 100).round();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isPdf ? 'Opening PDF...' : (isImage ? 'Opening image...' : 'Downloading file...'),
                          style: GoogleFonts.ptSans(
                            color: Colors.white.withValues(alpha: 0.96),
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          minHeight: 3,
                          value: v,
                          backgroundColor: Colors.white.withValues(alpha: 0.18),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFF53C5FF),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          pct == null ? 'Please wait...' : '$pct%',
                          style: GoogleFonts.ptSans(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      );

      final bytes = await Get.find<ChatMediaRepository>().downloadUrl(
        url,
        onProgress: (received, total) {
          if (total > 0) {
            progress.value = (received / total).clamp(0.0, 1.0);
          } else {
            progress.value = null;
          }
        },
      );
      if (bytes.isEmpty) {
        throw Exception('Empty download');
      }
      final out = File(stableSavePath);
      await out.writeAsBytes(bytes, flush: true);
      if (cacheKey.isNotEmpty) {
        chatDocumentFileCache[cacheKey] = stableSavePath;
      }
      progress.value = 1;

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();

      if (isImage) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
              builder: (_) =>
                  ChatImageViewerScreen(paths: [stableSavePath], initialIndex: 0),
          ),
        );
        return;
      }
      if (isPdf) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ChatPdfViewerScreen(path: stableSavePath, title: doc.name),
          ),
        );
        return;
      }
      await ensureVisibleInDownloadsIfNeeded(stableSavePath);

      _showThreadSnackBar(
        SnackBar(
          content: Text('File downloaded to app storage', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
      progress.dispose();
      if (!mounted) return;
      _showThreadSnackBar(
        SnackBar(
          content: Text('Could not open document', style: GoogleFonts.ptSans()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 92,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tileBackground,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Center(child: Icon(icon, color: iconColor, size: 38)),
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
    );
  }
}

abstract final class _ChatThreadColors {
  static const canvas = Color(0xFF000000);
  static const composerBar = Color(0xFF000000);
  static const composerField = Color(0xFF000000);
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
      return Path()
        ..addRRect(RRect.fromLTRBR(0, 0, w, h, const Radius.circular(_r)));
    }
    final tipY = 11.0.clamp(7.0, h - 7.0);
    final topY = (tipY - 6).clamp(3.0, h - 10.0);
    final botY = (tipY + 6).clamp(10.0, h - 3.0);
    final body = Path()
      ..addRRect(RRect.fromLTRBR(_joinX, 0, w, h, const Radius.circular(_r)));
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
      return Path()
        ..addRRect(RRect.fromLTRBR(0, 0, w, h, const Radius.circular(_r)));
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

/// Composer strip while editing an existing message (matches [_ReplyDraftStrip] layout).
class _EditDraftStrip extends StatelessWidget {
  const _EditDraftStrip({required this.onClose});

  final VoidCallback onClose;

  static const _accent = Color(0xFFE8B86D);
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Editing message',
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
                  'Tap send to update — only within 5 minutes of sending.',
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
  const _SwipeToReplyWrap({required this.child, required this.onReply});

  final Widget child;
  final VoidCallback onReply;

  @override
  State<_SwipeToReplyWrap> createState() => _SwipeToReplyWrapState();
}

class _SwipeToReplyWrapState extends State<_SwipeToReplyWrap>
    with TickerProviderStateMixin {
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
    final anim = Tween<double>(
      begin: start,
      end: 0,
    ).animate(CurvedAnimation(parent: _snapCtrl!, curve: Curves.easeOutCubic));
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
List<MapEntry<String, int>> _groupReactionEmojiCounts(
  List<ChatReactionEntry> reactions,
) {
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
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
                        child: const Icon(
                          Icons.add,
                          color: Colors.white70,
                          size: 20,
                        ),
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
    required this.nameForUserId,
    required this.onRemoveMine,
    required this.onPickEmoji,
  });

  final _UiMsg msg;
  final String myId;
  final String Function(String userId) nameForUserId;
  final VoidCallback onRemoveMine;
  final VoidCallback onPickEmoji;

  @override
  State<_ReactionDetailsSheet> createState() => _ReactionDetailsSheetState();
}

class _ReactionDetailsSheetState extends State<_ReactionDetailsSheet> {
  String? _filterEmoji;

  String _nameFor(String userId) {
    if (userId == widget.myId) return 'You';
    final v = widget.nameForUserId(userId).trim();
    return v.isEmpty ? 'Member' : v;
  }

  @override
  Widget build(BuildContext context) {
    final rx = widget.msg.reactions;
    final n = rx.length;
    final title = n == 1 ? '1 reaction' : '$n reactions';
    final groups = _groupReactionEmojiCounts(rx);
    final filtered = _filterEmoji == null
        ? rx
        : rx.where((e) => e.emoji == _filterEmoji).toList();

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
                        color: selected
                            ? const Color(0xFF005C4B)
                            : const Color(0xFF2C2C2C),
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          onTap: () => setState(() {
                            _filterEmoji = selected ? null : g.key;
                          }),
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  g.key,
                                  style: const TextStyle(fontSize: 18),
                                ),
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
                    trailing: Text(
                      e.emoji,
                      style: const TextStyle(fontSize: 22),
                    ),
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

/// Detects URLs, emails, and phone numbers; taps open the system handler.
class _LinkifiedMessageBody extends StatefulWidget {
  const _LinkifiedMessageBody({
    required this.text,
    required this.baseStyle,
    this.onEmailTap,
  });

  final String text;
  final TextStyle baseStyle;

  /// When set, tapping an email runs this (e.g. in-app lookup) instead of `mailto:`.
  final Future<void> Function(String email)? onEmailTap;

  @override
  State<_LinkifiedMessageBody> createState() => _LinkifiedMessageBodyState();
}

class _LinkifiedMessageBodyState extends State<_LinkifiedMessageBody> {
  final List<TapGestureRecognizer> _recognizers = [];
  List<InlineSpan> _spans = const [];

  static const _linkColor = Color(0xFF7DD3FC);

  static Future<void> _openLink(LinkableElement e) async {
    final raw = e.url.trim();
    if (raw.isEmpty) return;
    Uri? uri = Uri.tryParse(raw);
    if (uri == null && raw.toLowerCase().startsWith('tel:')) {
      final n = raw.substring(4).replaceAll(RegExp(r'[\s\-]'), '');
      if (n.isNotEmpty) {
        uri = Uri(scheme: 'tel', path: n);
      }
    }
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _rebuildSpans();
  }

  @override
  void didUpdateWidget(covariant _LinkifiedMessageBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.onEmailTap != widget.onEmailTap) {
      _rebuildSpans();
    }
  }

  void _rebuildSpans() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    if (widget.text.isEmpty) {
      _spans = [TextSpan(text: '', style: widget.baseStyle)];
      return;
    }

    final linkStyle = widget.baseStyle.copyWith(
      color: _linkColor,
      decoration: TextDecoration.underline,
      decorationColor: _linkColor,
    );

    // Email before URL: loose URLs can treat "user@host.tld" as a hostname and prepend https://.
    final elements = linkify(
      widget.text,
      linkifiers: const [
        EmailLinkifier(),
        UrlLinkifier(),
        PhoneNumberLinkifier(),
      ],
      options: const LinkifyOptions(
        humanize: false,
        looseUrl: true,
        defaultToHttps: true,
        excludeLastPeriod: true,
      ),
    );

    final out = <InlineSpan>[];
    for (final e in elements) {
      if (e is TextElement) {
        out.add(TextSpan(text: e.text, style: widget.baseStyle));
      } else if (e is EmailElement && widget.onEmailTap != null) {
        final mail = e.emailAddress;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => unawaited(widget.onEmailTap!(mail));
        _recognizers.add(recognizer);
        out.add(
          TextSpan(text: e.text, style: linkStyle, recognizer: recognizer),
        );
      } else if (e is LinkableElement) {
        final link = e;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _openLink(link);
        _recognizers.add(recognizer);
        out.add(
          TextSpan(text: link.text, style: linkStyle, recognizer: recognizer),
        );
      }
    }
    _spans = out;
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(children: _spans), style: widget.baseStyle);
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
        return Icon(
          Icons.error_outline_rounded,
          size: 16,
          color: Colors.red.shade300,
        );
    }
  }
}

/// Light incoming-style bubble above the composer when the peer is typing.
class _PeerTypingConversationBubble extends StatelessWidget {
  const _PeerTypingConversationBubble({required this.showVoice});

  final bool showVoice;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 56, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _ChatThreadColors.incomingBubble,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(18),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 6,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: showVoice
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.mic_rounded,
                        size: 16,
                        color: _ChatThreadColors.bubbleMeta.withValues(
                          alpha: 0.9,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Recording audio...',
                        style: GoogleFonts.ptSans(
                          color: _ChatThreadColors.bubbleMeta,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _TypingDotsIndicator(
                        dotColor: _ChatThreadColors.bubbleMeta,
                      ),
                    ],
                  )
                : _TypingDotsIndicator(dotColor: _ChatThreadColors.bubbleMeta),
          ),
        ),
      ),
    );
  }
}

/// Animated three-dot typing indicator (used in the conversation strip).
class _TypingDotsIndicator extends StatefulWidget {
  const _TypingDotsIndicator({required this.dotColor});

  final Color dotColor;

  @override
  State<_TypingDotsIndicator> createState() => _TypingDotsIndicatorState();
}

class _TypingDotsIndicatorState extends State<_TypingDotsIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fill = widget.dotColor;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = _c.value * 2 * pi;
            final bounce = sin(t + i * 0.95);
            final opacity = 0.35 + 0.55 * (0.5 + 0.5 * sin(t + i * 1.15));
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: Transform.translate(
                offset: Offset(0, -3.5 * bounce),
                child: Opacity(
                  opacity: opacity.clamp(0.28, 1.0),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: fill,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Wire format for forwarded sends — [stripForDisplay] removes this so the bubble can render a banner.
class _ForwardedPayloadParse {
  _ForwardedPayloadParse._();

  /// Stored in [ChatMessageDto.body]; parsed out before rendering message text.
  static const String textPrefix = '» Forwarded\n\n';

  static final RegExp _legacyHeader = RegExp(
    r'^---------- Forwarded message ----------\n(?:\[[^\]]*\]\n)?',
  );

  /// Collapsed / single-space variants (e.g. after API preview normalization).
  static final RegExp _flexForwardHeader = RegExp(r'^»\s*Forwarded\s*');

  /// Removes every stacked `» Forwarded` / legacy header so image JSON is parseable
  /// and re-forward only adds [textPrefix] once.
  static String stripToInnerPayload(String body) {
    var s = body;
    while (true) {
      if (s.startsWith(textPrefix)) {
        s = s.substring(textPrefix.length);
        continue;
      }
      final fm = _flexForwardHeader.firstMatch(s);
      if (fm != null && fm.start == 0) {
        s = s.substring(fm.end);
        continue;
      }
      final m = _legacyHeader.firstMatch(s);
      if (m != null) {
        s = s.substring(m.end);
        continue;
      }
      break;
    }
    return s;
  }

  /// Inner text for linkification, or null if not a forwarded payload.
  static String? stripForDisplay(String body) {
    final inner = stripToInnerPayload(body);
    if (inner == body) return null;
    return inner;
  }

  /// Number of stacked forwarded markers in the stored body.
  static int forwardedCount(String body) {
    var s = body;
    var count = 0;
    while (true) {
      if (s.startsWith(textPrefix)) {
        count++;
        s = s.substring(textPrefix.length);
        continue;
      }
      final fm = _flexForwardHeader.firstMatch(s);
      if (fm != null && fm.start == 0) {
        count++;
        s = s.substring(fm.end);
        continue;
      }
      final m = _legacyHeader.firstMatch(s);
      if (m != null) {
        count++;
        s = s.substring(m.end);
        continue;
      }
      break;
    }
    return count;
  }
}

class _ForwardedBannerRow extends StatelessWidget {
  const _ForwardedBannerRow({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '»',
            style: GoogleFonts.ptSans(
              fontSize: 13,
              fontStyle: FontStyle.italic,
              color: _ChatThreadColors.bubbleMeta,
              height: 1.2,
            ),
          ),
          Text(
            count > 1 ? ' Forwarded ($count)' : ' Forwarded',
            style: GoogleFonts.ptSans(
              fontSize: 13,
              fontStyle: FontStyle.italic,
              color: _ChatThreadColors.bubbleMeta,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _EditedBannerRow extends StatelessWidget {
  const _EditedBannerRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '»',
            style: GoogleFonts.ptSans(
              fontSize: 13,
              fontStyle: FontStyle.italic,
              color: _ChatThreadColors.bubbleMeta,
              height: 1.2,
            ),
          ),
          Text(
            ' Edited',
            style: GoogleFonts.ptSans(
              fontSize: 13,
              fontStyle: FontStyle.italic,
              color: _ChatThreadColors.bubbleMeta,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Centered pill above the first bubble of each day group (dynamic label from timestamps).
class _ChatDateSeparator extends StatelessWidget {
  const _ChatDateSeparator({super.key, required this.label});

  final String label;

  static const _pillText = Color(0xFF2D2D2D);
  static const _pillFill = Color(0xFFF5F0E8);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _pillFill.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 5,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
            child: Text(
              label,
              style: GoogleFonts.ptSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _pillText,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadMessagesDivider extends StatelessWidget {
  const _UnreadMessagesDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(
            child: Divider(
              color: Color(0x66FFFFFF),
              thickness: 0.8,
              height: 1,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Unread messages',
              style: GoogleFonts.ptSans(
                color: const Color(0xFFD1D5DB),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Expanded(
            child: Divider(
              color: Color(0x66FFFFFF),
              thickness: 0.8,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sticky header at top of thread: shows calendar day for the topmost visible message while scrolling.
class _FloatingStickyDateChip extends StatelessWidget {
  const _FloatingStickyDateChip({required this.label});

  final String label;

  static const _pillText = Color(0xFF2D2D2D);
  static const _pillFill = Color(0xFFF5F0E8);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: DecoratedBox(
          key: ValueKey<String>(label),
          decoration: BoxDecoration(
            color: _pillFill.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              label,
              style: GoogleFonts.ptSans(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _pillText,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// True when [raw] is a single grapheme cluster that is entirely one emoji (not a letter/digit).
bool _isSingleGraphemeEmojiOnly(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return false;
  if (t.characters.length != 1) return false;
  final re = EmojiPickerUtils().getEmojiRegex();
  final matches = re.allMatches(t).toList();
  if (matches.length != 1) return false;
  final m = matches.first;
  return m.start == 0 && m.end == t.length;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.msg,
    required this.myId,
    required this.peerDisplayName,
    required this.isGroupConversation,
    required this.timeLabel,
    this.selectionHighlight = false,
    this.jumpHighlightActive = false,
    this.jumpHighlightPulse = true,
    this.onRetry,
    this.onSwipeReply,
    this.onReplyQuoteTap,
    this.onLongPressBubble,
    this.onSelectionTap,
    this.onReactionSummaryTap,
    this.onEmailTap,
    this.onOpenImageSlot,
    this.onOpenVideo,
    this.onOpenDocument,
    this.onIncomingVoiceFirstPlay,
    this.onPollVote,
    this.onPollSeeVotes,
    this.replySenderLabelResolver,
  });

  final _UiMsg msg;
  final String myId;
  final String peerDisplayName;
  final bool isGroupConversation;
  final String timeLabel;
  final bool selectionHighlight;
  final bool jumpHighlightActive;
  final bool jumpHighlightPulse;
  final VoidCallback? onRetry;
  final VoidCallback? onSwipeReply;
  final VoidCallback? onReplyQuoteTap;
  final VoidCallback? onLongPressBubble;

  /// While selection mode is active: tap bubble to toggle this message in the set.
  final VoidCallback? onSelectionTap;
  final VoidCallback? onReactionSummaryTap;
  final Future<void> Function(String email)? onEmailTap;
  final void Function(int slotIndex)? onOpenImageSlot;
  final VoidCallback? onOpenVideo;
  final VoidCallback? onOpenDocument;
  final VoidCallback? onIncomingVoiceFirstPlay;
  final ValueChanged<String>? onPollVote;
  final VoidCallback? onPollSeeVotes;
  final String Function(ChatReplyQuote quote)? replySenderLabelResolver;

  static const _jumpHighlightTint = Color(0xFF7DD3FC);
  static const _selectionHighlightTint = Color(0xFF64B5F6);
  static const _selectionHighlightOpacity = 0.52;

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

  static String _normalizeReplyPreviewText(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'Message';
    final voc = ChatVoiceMessage.tryParse(t);
    if (voc != null) return 'Voice message';
    final doc = ChatDocumentMessage.tryParse(t);
    if (doc != null) return doc.isPdf ? 'PDF' : 'Document';
    final vid = ChatVideoMessage.tryParse(t);
    if (vid != null) {
      final c = vid.caption.trim();
      return c.isNotEmpty ? c : 'Video';
    }
    final img = ChatImageMessage.tryParse(t);
    if (img != null) {
      final c = img.caption.trim();
      if (c.isNotEmpty) return c;
      return img.items.length > 1 ? '${img.items.length} photos' : 'Photo';
    }
    final poll = ChatPollMessage.tryParse(t);
    if (poll != null) return poll.question;
    // Fallback for non-JSON map-like payload previews that may come from older rows.
    final low = t.toLowerCase();
    if (low.startsWith('{') && low.contains('t:')) {
      if (low.contains('t:voc') || low.contains('t:voice')) return 'Voice message';
      if (low.contains('t:doc') || low.contains('t:file')) {
        if (low.contains('e:pdf') || low.contains('ext:pdf')) return 'PDF';
        return 'Document';
      }
      if (low.contains('t:img')) return 'Photo';
      if (low.contains('t:vid')) return 'Video';
      return 'Attachment';
    }
    return t;
  }

  static String? _extractGroupInviteId(String? rawUrl) {
    final url = (rawUrl ?? '').trim();
    if (url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (u == null) return null;
    final seg = u.pathSegments;
    if (seg.length < 3) return null;
    final inviteSeg = seg[0].toLowerCase();
    if ((inviteSeg != 'invite' && inviteSeg != 'inivte') || seg[1] != 'group') {
      return null;
    }
    final id = seg[2].trim();
    if (RegExp(r'^[a-fA-F0-9]{24}$').hasMatch(id)) return id;
    return null;
  }

  Widget _inlineReplyStrip(ChatReplyQuote q) {
    final resolved = replySenderLabelResolver?.call(q).trim() ?? '';
    final who = resolved.isNotEmpty
        ? resolved
        : (q.senderId == myId ? 'You' : peerDisplayName);
    final prev = _normalizeReplyPreviewText(q.bodyPreview);
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
    final senderLabel = msg.senderName.trim().isNotEmpty
        ? msg.senderName.trim()
        : (outgoing ? 'You' : 'Member');
    final groupSenderInlineLabel = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        senderLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.ptSans(
          color: const Color(0xFF7DD3FC),
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    );
    final forwardedCount = _ForwardedPayloadParse.forwardedCount(msg.body);
    final bodyForRich = _ForwardedPayloadParse.stripForDisplay(msg.body);
    final showForwardedBanner = forwardedCount > 0 && bodyForRich != null;
    final bodyText = bodyForRich ?? msg.body;
    final showEditedBanner = msg.editedAt != null;
    final imageEnvelope = ChatImageMessage.tryParse(bodyText);
    final videoEnvelope = ChatVideoMessage.tryParse(bodyText);
    final voiceEnvelope = ChatVoiceMessage.tryParse(bodyText);
    final docEnvelope = ChatDocumentMessage.tryParse(bodyText);
    final pollEnvelope = ChatPollMessage.tryParse(bodyText);
    final previewUrl =
        (imageEnvelope != null ||
            videoEnvelope != null ||
            voiceEnvelope != null ||
            docEnvelope != null)
        ? null
        : LinkPreviewService.extractFirstHttpUrl(bodyText);
    final inviteId = _extractGroupInviteId(previewUrl);
    final hideInviteLinkText =
        inviteId != null && previewUrl != null && bodyText.trim() == previewUrl.trim();
    final meta = _metaStyle(context);
    final q = msg.replyTo;
    const baseRowBottom = 6.0;
    final hasReactions = msg.reactions.isNotEmpty;
    final rowBottomPadding = hasReactions
        ? baseRowBottom +
              _ReactionSummaryBadge.diameter / 2 +
              6 // space below the half-outside reaction circle before the next row
        : baseRowBottom;

    final singleEmojiLayout =
        !showForwardedBanner &&
        (q == null || q.isEmpty) &&
        previewUrl == null &&
        !showEditedBanner &&
        _isSingleGraphemeEmojiOnly(bodyText);

    if (pollEnvelope != null && !singleEmojiLayout) {
      final outgoingState = msg.outbound ?? OutboundDelivery.sent;
      final metaWidget = msg.senderId == myId
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(timeLabel, style: meta),
                const SizedBox(width: 4),
                if (outgoingState == OutboundDelivery.failed && onRetry != null)
                  InkWell(
                    onTap: onRetry,
                    child: Text(
                      'Retry',
                      style: GoogleFonts.ptSans(
                        fontSize: 12,
                        color: const Color(0xFF7DD3FC),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 0.5),
                    child: _OutboundTicks(state: outgoingState),
                  ),
              ],
            )
          : Text(timeLabel, style: meta);
      return Align(
        alignment: msg.senderId == myId ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            decoration: BoxDecoration(
              color: msg.senderId == myId
                  ? _ChatThreadColors.outgoingBubble
                  : _ChatThreadColors.incomingBubble,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ChatPollCard(
              poll: pollEnvelope,
              currentUserId: myId,
              onVote: (id) => onPollVote?.call(id),
              onSeeVotes: () => onPollSeeVotes?.call(),
              trailingMeta: metaWidget,
            ),
          ),
        ),
      );
    }

    if (outgoing) {
      final st = msg.outbound ?? OutboundDelivery.sent;
      final grouped = _groupReactionEmojiCounts(msg.reactions);
      final Widget bubbleCore;
      if (docEnvelope != null && !singleEmojiLayout) {
        bubbleCore = GestureDetector(
          onLongPress: onLongPressBubble,
          onTap: onSelectionTap,
          behavior: HitTestBehavior.deferToChild,
          child: ClipPath(
            clipper: const _OutgoingBubbleClipper(),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: _ChatThreadColors.outgoingBubble),
                ),
                if (selectionHighlight)
                  Positioned.fill(
                    child: ColoredBox(
                      color: _selectionHighlightTint.withValues(
                        alpha: _selectionHighlightOpacity,
                      ),
                    ),
                  ),
                if (jumpHighlightActive)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 260),
                      opacity: jumpHighlightPulse ? 1 : 0.5,
                      child: ColoredBox(
                        color: _jumpHighlightTint.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                      if (showForwardedBanner)
                        _ForwardedBannerRow(count: forwardedCount),
                      if (showEditedBanner) const _EditedBannerRow(),
                      ChatMessageDocumentBubble(
                        payload: docEnvelope,
                        outgoing: true,
                        timeLabel: timeLabel,
                        metaStyle: meta,
                        onTapOpen: onOpenDocument,
                        onRetry:
                            st == OutboundDelivery.failed && onRetry != null
                            ? () => onRetry?.call()
                            : null,
                        trailingMeta: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(timeLabel, style: meta),
                            const SizedBox(width: 4),
                            if (st == OutboundDelivery.failed &&
                                onRetry != null)
                              InkWell(
                                onTap: onRetry,
                                child: Text(
                                  'Retry',
                                  style: GoogleFonts.ptSans(
                                    fontSize: 12,
                                    color: const Color(0xFF7DD3FC),
                                    fontWeight: FontWeight.w700,
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
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (voiceEnvelope != null && !singleEmojiLayout) {
        final voiceUploading =
            st == OutboundDelivery.sending ||
            voiceEnvelope.status == 'uploading' ||
            voiceEnvelope.status == 'pending' ||
            (voiceEnvelope.url.trim().isEmpty &&
                voiceEnvelope.status != 'failed');
        bubbleCore = GestureDetector(
          onLongPress: onLongPressBubble,
          onTap: onSelectionTap,
          behavior: HitTestBehavior.deferToChild,
          child: ClipPath(
            clipper: const _OutgoingBubbleClipper(),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: _ChatThreadColors.outgoingBubble),
                ),
                if (selectionHighlight)
                  Positioned.fill(
                    child: ColoredBox(
                      color: _selectionHighlightTint.withValues(
                        alpha: _selectionHighlightOpacity,
                      ),
                    ),
                  ),
                if (jumpHighlightActive)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 260),
                      opacity: jumpHighlightPulse ? 1 : 0.5,
                      child: ColoredBox(
                        color: _jumpHighlightTint.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 12, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                      if (showForwardedBanner)
                        _ForwardedBannerRow(count: forwardedCount),
                      if (showEditedBanner) const _EditedBannerRow(),
                      ChatMessageVoiceBubble(
                        payload: voiceEnvelope,
                        outgoing: true,
                        metaStyle: meta,
                        timeLabel: timeLabel,
                        onRetry:
                            st == OutboundDelivery.failed && onRetry != null
                            ? () => onRetry?.call()
                            : null,
                        trailingMeta: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (voiceUploading) ...[
                              const Icon(
                                Icons.mic_rounded,
                                size: 13,
                                color: Color(0xFFFF7A90),
                              ),
                              const SizedBox(width: 3),
                            ],
                            if (voiceEnvelope.playedByPeer) ...[
                              const Icon(
                                Icons.mic_rounded,
                                size: 13,
                                color: kPrimaryBlue,
                              ),
                              const SizedBox(width: 3),
                            ],
                            Text(timeLabel, style: meta),
                            const SizedBox(width: 4),
                            if (st == OutboundDelivery.failed &&
                                onRetry != null)
                              InkWell(
                                onTap: onRetry,
                                child: Text(
                                  'Retry',
                                  style: GoogleFonts.ptSans(
                                    fontSize: 12,
                                    color: const Color(0xFF7DD3FC),
                                    fontWeight: FontWeight.w700,
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
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (videoEnvelope != null && !singleEmojiLayout) {
        final prefix = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (q != null && !q.isEmpty) _inlineReplyStrip(q),
            if (showForwardedBanner)
              _ForwardedBannerRow(count: forwardedCount),
            if (showEditedBanner) const _EditedBannerRow(),
          ],
        );
        final hasPrefix =
            (q != null && !q.isEmpty) ||
            showForwardedBanner ||
            showEditedBanner;
        bubbleCore = GestureDetector(
          onLongPress: onLongPressBubble,
          onTap: onSelectionTap,
          behavior: HitTestBehavior.deferToChild,
          child: ClipPath(
            clipper: const _OutgoingBubbleClipper(),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: _ChatThreadColors.outgoingBubble),
                ),
                if (selectionHighlight)
                  Positioned.fill(
                    child: ColoredBox(
                      color: _selectionHighlightTint.withValues(
                        alpha: _selectionHighlightOpacity,
                      ),
                    ),
                  ),
                if (jumpHighlightActive)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 260),
                      opacity: jumpHighlightPulse ? 1 : 0.5,
                      child: ColoredBox(
                        color: _jumpHighlightTint.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                  child: ChatMessageVideoBubble(
                    payload: videoEnvelope,
                    outgoing: true,
                    bubbleColor: _ChatThreadColors.outgoingBubble,
                    metaColor: _ChatThreadColors.bubbleMeta,
                    timeLabel: timeLabel,
                    metaStyle: meta,
                    prefix: hasPrefix ? prefix : null,
                    trailingMeta: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(timeLabel, style: meta),
                        const SizedBox(width: 4),
                        if (st == OutboundDelivery.failed && onRetry != null)
                          InkWell(
                            onTap: onRetry,
                            child: Text(
                              'Retry',
                              style: GoogleFonts.ptSans(
                                fontSize: 12,
                                color: const Color(0xFF7DD3FC),
                                fontWeight: FontWeight.w700,
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
                    onTapVideo: onOpenVideo,
                    onRetry: st == OutboundDelivery.failed && onRetry != null
                        ? () => onRetry?.call()
                        : null,
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (imageEnvelope != null && !singleEmojiLayout) {
        final prefix = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (q != null && !q.isEmpty) _inlineReplyStrip(q),
            if (showForwardedBanner)
              _ForwardedBannerRow(count: forwardedCount),
            if (showEditedBanner) const _EditedBannerRow(),
          ],
        );
        final hasPrefix =
            (q != null && !q.isEmpty) ||
            showForwardedBanner ||
            showEditedBanner;
        bubbleCore = GestureDetector(
          onLongPress: onLongPressBubble,
          onTap: onSelectionTap,
          behavior: HitTestBehavior.deferToChild,
          child: ClipPath(
            clipper: const _OutgoingBubbleClipper(),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: _ChatThreadColors.outgoingBubble),
                ),
                if (selectionHighlight)
                  Positioned.fill(
                    child: ColoredBox(
                      color: _selectionHighlightTint.withValues(
                        alpha: _selectionHighlightOpacity,
                      ),
                    ),
                  ),
                if (jumpHighlightActive)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 260),
                      opacity: jumpHighlightPulse ? 1 : 0.5,
                      child: ColoredBox(
                        color: _jumpHighlightTint.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                  child: ChatMessageImagesBubble(
                    payload: imageEnvelope,
                    outgoing: true,
                    bubbleColor: _ChatThreadColors.outgoingBubble,
                    metaColor: _ChatThreadColors.bubbleMeta,
                    timeLabel: timeLabel,
                    metaStyle: meta,
                    prefix: hasPrefix ? prefix : null,
                    trailingMeta: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(timeLabel, style: meta),
                        const SizedBox(width: 4),
                        if (st == OutboundDelivery.failed && onRetry != null)
                          InkWell(
                            onTap: onRetry,
                            child: Text(
                              'Retry',
                              style: GoogleFonts.ptSans(
                                fontSize: 12,
                                color: const Color(0xFF7DD3FC),
                                fontWeight: FontWeight.w700,
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
                    onTapImage: onOpenImageSlot != null
                        ? (i, _) => onOpenImageSlot!(i)
                        : null,
                    onRetrySlot:
                        st == OutboundDelivery.failed && onRetry != null
                        ? (_) => onRetry?.call()
                        : null,
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (singleEmojiLayout) {
        bubbleCore = GestureDetector(
          onLongPress: onLongPressBubble,
          onTap: onSelectionTap,
          behavior: HitTestBehavior.deferToChild,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerRight,
                children: [
                  if (selectionHighlight)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            color: _selectionHighlightTint.withValues(
                              alpha: _selectionHighlightOpacity,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (jumpHighlightActive)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 260),
                          opacity: jumpHighlightPulse ? 1 : 0.5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              color: _jumpHighlightTint.withValues(alpha: 0.38),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 4, top: 2),
                    child: Text(
                      bodyText,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 62, height: 1.05),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: _ChatThreadColors.outgoingBubble,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                ),
              ),
            ],
          ),
        );
      } else {
        bubbleCore = GestureDetector(
          onLongPress: onLongPressBubble,
          onTap: onSelectionTap,
          behavior: HitTestBehavior.deferToChild,
          child: ClipPath(
            clipper: const _OutgoingBubbleClipper(),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: _ChatThreadColors.outgoingBubble),
                ),
                if (selectionHighlight)
                  Positioned.fill(
                    child: ColoredBox(
                      color: _selectionHighlightTint.withValues(
                        alpha: _selectionHighlightOpacity,
                      ),
                    ),
                  ),
                if (jumpHighlightActive)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 260),
                      opacity: jumpHighlightPulse ? 1 : 0.5,
                      child: ColoredBox(
                        color: _jumpHighlightTint.withValues(alpha: 0.38),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 18, 8),
                  child: IntrinsicWidth(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                        if (showForwardedBanner)
                          _ForwardedBannerRow(count: forwardedCount),
                        if (showEditedBanner) const _EditedBannerRow(),
                        if (previewUrl != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: (inviteId != null)
                                ? GroupInvitePreviewWidget(
                                    key: ValueKey('gi:${msg.id}|$previewUrl'),
                                    inviteId: inviteId,
                                    outgoing: true,
                                  )
                                : ChatLinkPreviewCard(
                                    key: ValueKey('lp:${msg.id}|$previewUrl'),
                                    url: previewUrl,
                                    isOutgoing: true,
                                  ),
                          ),
                        if (!hideInviteLinkText)
                          _LinkifiedMessageBody(
                            text: bodyText,
                            baseStyle: GoogleFonts.ptSans(textStyle: _bodyStyle),
                            onEmailTap: onEmailTap,
                          ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(timeLabel, style: meta),
                            const SizedBox(width: 4),
                            if (st == OutboundDelivery.failed &&
                                onRetry != null)
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
              ],
            ),
          ),
        );
      }
      final bubble = Padding(
        padding: EdgeInsets.only(
          left: 56,
          right: 0,
          bottom: rowBottomPadding,
          top: 2,
        ),
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
      return _SwipeToReplyWrap(onReply: onSwipeReply!, child: bubble);
    }

    final groupedIn = _groupReactionEmojiCounts(msg.reactions);
    final Widget incomingCore;
    if (docEnvelope != null && !singleEmojiLayout) {
      incomingCore = GestureDetector(
        onLongPress: onLongPressBubble,
        onTap: onSelectionTap,
        behavior: HitTestBehavior.deferToChild,
        child: ClipPath(
          clipper: const _IncomingBubbleClipper(),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              const Positioned.fill(
                child: ColoredBox(color: _ChatThreadColors.incomingBubble),
              ),
              if (selectionHighlight)
                Positioned.fill(
                  child: ColoredBox(
                    color: _selectionHighlightTint.withValues(
                      alpha: _selectionHighlightOpacity,
                    ),
                  ),
                ),
              if (jumpHighlightActive)
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    opacity: jumpHighlightPulse ? 1 : 0.5,
                    child: ColoredBox(
                      color: _jumpHighlightTint.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isGroupConversation) groupSenderInlineLabel,
                    if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                    if (showForwardedBanner)
                      _ForwardedBannerRow(count: forwardedCount),
                    if (showEditedBanner) const _EditedBannerRow(),
                    ChatMessageDocumentBubble(
                      payload: docEnvelope,
                      outgoing: false,
                      timeLabel: timeLabel,
                      metaStyle: meta,
                      onTapOpen: onOpenDocument,
                      trailingMeta: Text(timeLabel, style: meta),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } else if (voiceEnvelope != null && !singleEmojiLayout) {
      incomingCore = GestureDetector(
        onLongPress: onLongPressBubble,
        onTap: onSelectionTap,
        behavior: HitTestBehavior.deferToChild,
        child: ClipPath(
          clipper: const _IncomingBubbleClipper(),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              const Positioned.fill(
                child: ColoredBox(color: _ChatThreadColors.incomingBubble),
              ),
              if (selectionHighlight)
                Positioned.fill(
                  child: ColoredBox(
                    color: _selectionHighlightTint.withValues(
                      alpha: _selectionHighlightOpacity,
                    ),
                  ),
                ),
              if (jumpHighlightActive)
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    opacity: jumpHighlightPulse ? 1 : 0.5,
                    child: ColoredBox(
                      color: _jumpHighlightTint.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isGroupConversation) groupSenderInlineLabel,
                    if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                    if (showForwardedBanner)
                      _ForwardedBannerRow(count: forwardedCount),
                    if (showEditedBanner) const _EditedBannerRow(),
                    ChatMessageVoiceBubble(
                      payload: voiceEnvelope,
                      outgoing: false,
                      metaStyle: meta,
                      timeLabel: timeLabel,
                      onFirstPlayStarted: onIncomingVoiceFirstPlay,
                      trailingMeta: Text(timeLabel, style: meta),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } else if (videoEnvelope != null && !singleEmojiLayout) {
      final prefixIn = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isGroupConversation) groupSenderInlineLabel,
          if (q != null && !q.isEmpty) _inlineReplyStrip(q),
          if (showForwardedBanner)
            _ForwardedBannerRow(count: forwardedCount),
          if (showEditedBanner) const _EditedBannerRow(),
        ],
      );
      final hasPrefixIn =
          (q != null && !q.isEmpty) || showForwardedBanner || showEditedBanner;
      incomingCore = GestureDetector(
        onLongPress: onLongPressBubble,
        onTap: onSelectionTap,
        behavior: HitTestBehavior.deferToChild,
        child: ClipPath(
          clipper: const _IncomingBubbleClipper(),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              const Positioned.fill(
                child: ColoredBox(color: _ChatThreadColors.incomingBubble),
              ),
              if (selectionHighlight)
                Positioned.fill(
                  child: ColoredBox(
                    color: _selectionHighlightTint.withValues(
                      alpha: _selectionHighlightOpacity,
                    ),
                  ),
                ),
              if (jumpHighlightActive)
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    opacity: jumpHighlightPulse ? 1 : 0.5,
                    child: ColoredBox(
                      color: _jumpHighlightTint.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
                child: ChatMessageVideoBubble(
                  payload: videoEnvelope,
                  outgoing: false,
                  bubbleColor: _ChatThreadColors.incomingBubble,
                  metaColor: _ChatThreadColors.bubbleMeta,
                  timeLabel: timeLabel,
                  metaStyle: meta,
                  prefix: hasPrefixIn ? prefixIn : null,
                  trailingMeta: Text(timeLabel, style: meta),
                  onTapVideo: onOpenVideo,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (imageEnvelope != null && !singleEmojiLayout) {
      final prefixIn = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isGroupConversation) groupSenderInlineLabel,
          if (q != null && !q.isEmpty) _inlineReplyStrip(q),
          if (showForwardedBanner)
            _ForwardedBannerRow(count: forwardedCount),
          if (showEditedBanner) const _EditedBannerRow(),
        ],
      );
      final hasPrefixIn =
          (q != null && !q.isEmpty) || showForwardedBanner || showEditedBanner;
      incomingCore = GestureDetector(
        onLongPress: onLongPressBubble,
        onTap: onSelectionTap,
        behavior: HitTestBehavior.deferToChild,
        child: ClipPath(
          clipper: const _IncomingBubbleClipper(),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              const Positioned.fill(
                child: ColoredBox(color: _ChatThreadColors.incomingBubble),
              ),
              if (selectionHighlight)
                Positioned.fill(
                  child: ColoredBox(
                    color: _selectionHighlightTint.withValues(
                      alpha: _selectionHighlightOpacity,
                    ),
                  ),
                ),
              if (jumpHighlightActive)
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    opacity: jumpHighlightPulse ? 1 : 0.5,
                    child: ColoredBox(
                      color: _jumpHighlightTint.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
                child: ChatMessageImagesBubble(
                  payload: imageEnvelope,
                  outgoing: false,
                  bubbleColor: _ChatThreadColors.incomingBubble,
                  metaColor: _ChatThreadColors.bubbleMeta,
                  timeLabel: timeLabel,
                  metaStyle: meta,
                  prefix: hasPrefixIn ? prefixIn : null,
                  trailingMeta: Text(timeLabel, style: meta),
                  onTapImage: onOpenImageSlot != null
                      ? (i, _) => onOpenImageSlot!(i)
                      : null,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (singleEmojiLayout) {
      incomingCore = GestureDetector(
        onLongPress: onLongPressBubble,
        onTap: onSelectionTap,
        behavior: HitTestBehavior.deferToChild,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                if (selectionHighlight)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: _selectionHighlightTint.withValues(
                            alpha: _selectionHighlightOpacity,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (jumpHighlightActive)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 260),
                        opacity: jumpHighlightPulse ? 1 : 0.5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            color: _jumpHighlightTint.withValues(alpha: 0.38),
                          ),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4, top: 2),
                  child: Text(
                    bodyText,
                    textAlign: TextAlign.left,
                    style: const TextStyle(fontSize: 62, height: 1.05),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            DecoratedBox(
              decoration: BoxDecoration(
                color: _ChatThreadColors.incomingBubble,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text(timeLabel, style: meta)],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      incomingCore = GestureDetector(
        onLongPress: onLongPressBubble,
        onTap: onSelectionTap,
        behavior: HitTestBehavior.deferToChild,
        child: ClipPath(
          clipper: const _IncomingBubbleClipper(),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              const Positioned.fill(
                child: ColoredBox(color: _ChatThreadColors.incomingBubble),
              ),
              if (selectionHighlight)
                Positioned.fill(
                  child: ColoredBox(
                    color: _selectionHighlightTint.withValues(
                      alpha: _selectionHighlightOpacity,
                    ),
                  ),
                ),
              if (jumpHighlightActive)
                Positioned.fill(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    opacity: jumpHighlightPulse ? 1 : 0.5,
                    child: ColoredBox(
                      color: _jumpHighlightTint.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    if (isGroupConversation) groupSenderInlineLabel,
                      if (q != null && !q.isEmpty) _inlineReplyStrip(q),
                      if (showForwardedBanner)
                        _ForwardedBannerRow(count: forwardedCount),
                      if (showEditedBanner) const _EditedBannerRow(),
                      if (previewUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: (inviteId != null)
                              ? GroupInvitePreviewWidget(
                                  key: ValueKey('gi:${msg.id}|$previewUrl'),
                                  inviteId: inviteId,
                                  outgoing: false,
                                )
                              : ChatLinkPreviewCard(
                                  key: ValueKey('lp:${msg.id}|$previewUrl'),
                                  url: previewUrl,
                                  isOutgoing: false,
                                ),
                        ),
                      if (!hideInviteLinkText)
                        _LinkifiedMessageBody(
                          text: bodyText,
                          baseStyle: GoogleFonts.ptSans(textStyle: _bodyStyle),
                          onEmailTap: onEmailTap,
                        ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [Text(timeLabel, style: meta)],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final incomingBubbleCore = Align(
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
    );
    final incomingBubble = isGroupConversation
        ? Padding(
            padding: EdgeInsets.only(right: 16, bottom: rowBottomPadding, top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: CircleAvatar(
                    radius: 13,
                    backgroundColor: const Color(0xFF334155),
                    child: Text(
                      senderLabel.isEmpty ? '?' : senderLabel.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 56),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 170),
                      child: incomingBubbleCore,
                    ),
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: EdgeInsets.only(right: 56, bottom: rowBottomPadding, top: 2),
            child: incomingBubbleCore,
          );
    if (onSwipeReply == null) return incomingBubble;
    return _SwipeToReplyWrap(onReply: onSwipeReply!, child: incomingBubble);
  }
}

class _ThreadComposer extends StatefulWidget {
  const _ThreadComposer({
    required this.controller,
    required this.focusNode,
    this.replyBanner,
    this.composerHint = 'Type a message',
    required this.onSend,
    required this.onSendVoice,
    required this.onVoiceRecordingChanged,
    required this.onAttach,
    required this.onTextChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Widget? replyBanner;
  final String composerHint;
  final VoidCallback onSend;
  final Future<void> Function(String localPath, Duration duration) onSendVoice;
  final ValueChanged<bool> onVoiceRecordingChanged;
  final VoidCallback onAttach;
  final ValueChanged<String> onTextChanged;

  @override
  State<_ThreadComposer> createState() => _ThreadComposerState();
}

enum _ComposerVoiceState { idle, recording, uploading, sent, failed }

class _ThreadComposerState extends State<_ThreadComposer> {
  static const _maxVoiceRecord = Duration(minutes: 2);
  static const _minVoiceRecordToSend = Duration(milliseconds: 350);

  bool _emojiPanelOpen = false;
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _voiceTimer;
  DateTime? _voiceStartAt;
  Duration _voiceElapsed = Duration.zero;
  _ComposerVoiceState _voiceState = _ComposerVoiceState.idle;
  bool _voiceBusy = false;

  void _onControllerText() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerText);
    widget.focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus && _emojiPanelOpen) {
      setState(() => _emojiPanelOpen = false);
    }
  }

  @override
  void didUpdateWidget(covariant _ThreadComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerText);
      widget.controller.addListener(_onControllerText);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    _voiceTimer?.cancel();
    if (_isRecording) {
      widget.onVoiceRecordingChanged(false);
    }
    unawaited(_recorder.dispose());
    widget.controller.removeListener(_onControllerText);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  bool get _hasTypedText => widget.controller.text.trim().isNotEmpty;

  void _notifyTextChanged() {
    widget.onTextChanged(widget.controller.text);
  }

  void _toggleEmojiPanel() {
    if (_emojiPanelOpen) {
      setState(() => _emojiPanelOpen = false);
      widget.focusNode.requestFocus();
    } else {
      setState(() => _emojiPanelOpen = true);
      widget.focusNode.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  static Config _emojiPickerConfig() => _chatThreadEmojiPickerConfig();

  String _fmtVoice(Duration d) {
    final total = d.inSeconds;
    final m = (total ~/ 60).toString().padLeft(1, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  bool get _isRecording => _voiceState == _ComposerVoiceState.recording;

  Future<void> _startVoiceRecord() async {
    if (_voiceBusy || _isRecording || _hasTypedText) return;
    try {
      final has = await _recorder.hasPermission();
      if (!has) return;
      final dir = await getTemporaryDirectory();
      final p =
          '${dir.path}/sealpost_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: p,
      );
      _voiceTimer?.cancel();
      _voiceStartAt = DateTime.now();
      setState(() {
        _voiceElapsed = Duration.zero;
        _voiceState = _ComposerVoiceState.recording;
      });
      widget.onVoiceRecordingChanged(true);
      _voiceTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final start = _voiceStartAt;
        if (!mounted || !_isRecording || start == null) return;
        final elapsed = DateTime.now().difference(start);
        if (elapsed >= _maxVoiceRecord) {
          unawaited(_stopVoiceRecord(send: true));
          return;
        }
        setState(() => _voiceElapsed = elapsed);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _voiceState = _ComposerVoiceState.failed;
      });
      widget.onVoiceRecordingChanged(false);
    }
  }

  Future<void> _stopVoiceRecord({required bool send}) async {
    if (_voiceBusy || !_isRecording) return;
    _voiceBusy = true;
    _voiceTimer?.cancel();
    String? path;
    try {
      if (await _recorder.isRecording()) {
        path = await _recorder.stop();
      }
    } catch (_) {}
    final elapsed = _voiceElapsed;
    final trimmedPath = (path ?? '').trim();
    final shouldSend = send &&
        trimmedPath.isNotEmpty &&
        elapsed >= _minVoiceRecordToSend;
    if (mounted) {
      setState(() {
        _voiceElapsed = Duration.zero;
        _voiceStartAt = null;
        _voiceState = shouldSend
            ? _ComposerVoiceState.uploading
            : _ComposerVoiceState.idle;
      });
    }
    widget.onVoiceRecordingChanged(false);
    if (!shouldSend) {
      if (trimmedPath.isNotEmpty) {
        try {
          await File(trimmedPath).delete();
        } catch (_) {}
      }
      _voiceBusy = false;
      return;
    }
    try {
      await widget.onSendVoice(trimmedPath, elapsed);
      if (mounted) {
        setState(() => _voiceState = _ComposerVoiceState.sent);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _voiceState = _ComposerVoiceState.failed);
      }
    } finally {
      _voiceBusy = false;
      if (mounted &&
          (_voiceState == _ComposerVoiceState.sent ||
              _voiceState == _ComposerVoiceState.failed)) {
        Future<void>.delayed(const Duration(milliseconds: 900), () {
          if (!mounted || _isRecording) return;
          setState(() => _voiceState = _ComposerVoiceState.idle);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _hasTypedText;
    final composerPreviewUrl = LinkPreviewService.extractFirstHttpUrl(
      widget.controller.text,
    );
    final composerPreviewMaxW = (MediaQuery.sizeOf(context).width - 24).clamp(
      220.0,
      400.0,
    );
    return PopScope(
      canPop: !_emojiPanelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _emojiPanelOpen) {
          setState(() => _emojiPanelOpen = false);
        }
      },
      child: Material(
        color: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
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
                if (composerPreviewUrl != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ChatLinkPreviewCard(
                        key: ValueKey('composer-lp|$composerPreviewUrl'),
                        url: composerPreviewUrl,
                        isOutgoing: true,
                        maxWidth: composerPreviewMaxW,
                      ),
                    ),
                  ),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        decoration: BoxDecoration(
                          color: _ChatThreadColors.composerField,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: _isRecording
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  10,
                                  14,
                                  10,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.mic_rounded,
                                      color: Color(0xFF22C55E),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _fmtVoice(_voiceElapsed),
                                      style: GoogleFonts.ptSans(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Recording...',
                                        style: GoogleFonts.ptSans(
                                          color: Colors.white.withValues(
                                            alpha: 0.72,
                                          ),
                                          fontSize: 14.5,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () =>
                                          unawaited(_stopVoiceRecord(send: false)),
                                      tooltip: 'Cancel recording',
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.only(
                                      left: 4,
                                      right: 2,
                                    ),
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
                                      focusNode: widget.focusNode,
                                      minLines: 1,
                                      maxLines: 5,
                                      cursorColor: _ChatThreadColors.onComposer,
                                      textCapitalization:
                                          TextCapitalization.sentences,
                                      style: GoogleFonts.ptSans(
                                        fontSize: 16,
                                        color: _ChatThreadColors.onComposer,
                                      ),
                                      onChanged: widget.onTextChanged,
                                      decoration: InputDecoration(
                                        hintText: widget.composerHint,
                                        hintStyle: GoogleFonts.ptSans(
                                          color:
                                              _ChatThreadColors.hintOnComposer,
                                          fontSize: 16,
                                        ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.fromLTRB(
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
                                    padding: const EdgeInsets.only(
                                      left: 2,
                                      right: 4,
                                    ),
                                    constraints: const BoxConstraints(
                                      minWidth: 40,
                                      minHeight: 44,
                                    ),
                                    icon: Icon(
                                      Icons.attach_file_rounded,
                                      color: _ChatThreadColors.onComposer
                                          .withValues(alpha: 0.92),
                                      size: 22,
                                    ),
                                    onPressed: widget.onAttach,
                                  ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_isRecording)
                      Material(
                        color: const Color(0xFF00A884),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => unawaited(_stopVoiceRecord(send: true)),
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
                    else if (_voiceState == _ComposerVoiceState.uploading)
                      Material(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: const CircleBorder(),
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      )
                    else if (hasText)
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
                          onTap: () => unawaited(_startVoiceRecord()),
                          child: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(
                              Icons.mic_rounded,
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
