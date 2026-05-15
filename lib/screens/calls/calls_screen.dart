import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/app_branding.dart';
import '../../core/call/agora_call_service.dart';
import '../../core/call/incoming_call_kit_coordinator.dart';
import '../../core/call/voice_call_navigation.dart';
import '../../core/permissions/camera_permission_helper.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/calls/call_history_entry.dart';
import '../../data/chat/call_event_chat_message.dart';
import '../../data/chat/chat_contact.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/chat/chat_user.dart';
import '../../data/session/account_session_manager.dart';
import '../../theme/app_theme.dart';
import '../../widgets/account_switch_sheet.dart';
import '../../widgets/chat_action_dialog.dart';
import '../chat/chat_open_thread.dart';
import '../chat/view/chat_search_delegate.dart';
import '../chat/controller/chat_controller.dart';
import '../chat/view/chat_view.dart';
import '../chat/view/create_group_view.dart';
import '../chat_policy/view/chat_policy_view.dart';
import 'calls_history_controller.dart';
import '../data_processing_agreement/view/data_processing_agreement_view.dart';
import '../terms_of_service/view/terms_of_service_view.dart';

/// Call history list — same shell as [ChatScreen] (background + top search bar).
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> with WidgetsBindingObserver {
  static const _waGreen = Color(0xFF25D366);
  static const _missedRed = Color(0xFFE53935);
  static const _subtitle = Color(0xFF9AA0A6);

  /// Same palette as chat home [_ChatThreadTile] avatars.
  static const _callHistoryAvatarColors = [
    Color(0xFF7C4DFF),
    Color(0xFF448AFF),
    Color(0xFF26A69A),
    Color(0xFFFFA726),
    Color(0xFFEC407A),
  ];

  final _searchQuery = ''.obs;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        Get.isRegistered<CallsHistoryController>()) {
      unawaited(Get.find<CallsHistoryController>().refresh(silent: true));
    }
    setState(() {});
  }

  bool get _selfOnlineUi {
    switch (WidgetsBinding.instance.lifecycleState) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        return true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case null:
        return false;
    }
  }

  ChatController _chatController() {
    if (Get.isRegistered<ChatController>()) {
      return Get.find<ChatController>();
    }
    return Get.put(ChatController());
  }

  static String _formatListTime(DateTime at, DateTime now) {
    final diff = now.difference(at);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff < const Duration(hours: 24)) {
      if (diff.inHours < 1) {
        final m = diff.inMinutes.clamp(1, 59);
        return '$m minutes ago';
      }
      final h = diff.inHours;
      return h == 1 ? '1 hour ago' : '$h hours ago';
    }
    if (_isYesterday(at, now)) {
      return 'Yesterday, ${_formatHm(at)}';
    }
    return '${at.day} ${_monthShort(at.month)}, ${_formatHm(at)}';
  }

  static bool _isYesterday(DateTime at, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final y = today.subtract(const Duration(days: 1));
    final d = DateTime(at.year, at.month, at.day);
    return d == y;
  }

  static String _monthShort(int m) {
    const names = [
      '',
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
    if (m < 1 || m > 12) return '';
    return names[m];
  }

  static String _formatHm(DateTime d) {
    final h24 = d.hour;
    final h = h24 > 12 ? h24 - 12 : (h24 == 0 ? 12 : h24);
    final m = d.minute.toString().padLeft(2, '0');
    final ap = h24 >= 12 ? 'pm' : 'am';
    return '$h:$m $ap';
  }

  List<CallHistoryDisplayRow> _filteredRows(List<CallHistoryDisplayRow> rows, String query, DateTime now) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return rows;
    return rows.where((row) {
      final e = row.representative;
      final name = e.peerName.toLowerCase();
      final email = e.peerEmail.toLowerCase();
      final time = _formatListTime(e.createdAt, now).toLowerCase();
      final status = e.status.toLowerCase();
      final dir = e.direction.toLowerCase();
      final type = e.callType.toLowerCase();
      final countStr = row.hasGroupedMisses ? '${row.missedCount}' : '';
      final dur = (e.isEnded && e.durationSeconds > 0)
          ? CallEventChatMessage.formatCallDuration(e.durationSeconds).toLowerCase()
          : '';
      return name.contains(q) ||
          email.contains(q) ||
          time.contains(q) ||
          status.contains(q) ||
          dir.contains(q) ||
          type.contains(q) ||
          (dur.isNotEmpty && dur.contains(q)) ||
          (countStr.isNotEmpty && countStr.contains(q));
    }).toList();
  }

  ChatContact _contactFor(CallHistoryEntry e) {
    return ChatContact(
      id: e.peerId,
      name: e.peerName.isNotEmpty ? e.peerName : 'Unknown',
      email: e.peerEmail,
      isOnline: false,
      relationStatus: 'friends',
      lastMessage: '',
      timeLabel: '',
      unreadCount: 0,
    );
  }

  Future<void> _onRowTap(CallHistoryDisplayRow row) async {
    openChatThread(context, _contactFor(row.representative));
  }

  Future<void> _onSearchUserTap(ChatUser user) async {
    if (!mounted) return;
    if (user.relationStatus == 'friends') {
      openChatThread(
        context,
        ChatContact(
          id: user.id,
          name: user.name.isNotEmpty ? user.name : user.email,
          email: user.email,
          isOnline: user.isOnline,
          lastSeenAt: null,
          relationStatus: 'friends',
          lastMessage: '',
          timeLabel: '',
          unreadCount: 0,
        ),
      );
      return;
    }
    await _showUserActionModal(user);
  }

  Future<void> _showUserActionModal(ChatUser user) async {
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
                await _chatController().refreshContacts();
                if (!mounted || !parentContext.mounted) return;
                ScaffoldMessenger.of(parentContext).showSnackBar(
                  const SnackBar(content: Text('Friend request accepted')),
                );
                await _onSearchUserTap(
                  ChatUser(
                    id: user.id,
                    name: user.name,
                    email: user.email,
                    isOnline: user.isOnline,
                    relationStatus: 'friends',
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
                await Get.find<ChatRepository>().notifyFriendRequestUser(user.id);
                if (!mounted || !parentContext.mounted) return;
                ScaffoldMessenger.of(parentContext).showSnackBar(
                  const SnackBar(content: Text('Notification sent')),
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
                unawaited(_onSearchUserTap(user));
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
                await _sendRequestIfAllowed(user);
              },
              onSecondary: () => Navigator.of(dialogContext).pop(),
            );
        }
      },
    );
  }

  Future<void> _sendRequestIfAllowed(ChatUser user) async {
    if (user.relationStatus != 'none') return;
    final repo = Get.find<ChatRepository>();
    await repo.sendFriendRequest(user.id);
    await _chatController().refreshContacts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Friend request sent')),
    );
  }

  Future<void> _openAddFriendSearch() async {
    if (!mounted) return;
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showSearch(
      context: context,
      delegate: ChatSearchDelegate(
        repo: Get.find<ChatRepository>(),
        onUserTap: _onSearchUserTap,
      ),
    );
  }

  Future<void> _openFriendsCallSearch() async {
    if (!mounted) return;
    await _chatController().refreshContacts();
    if (!mounted) return;
    final friends = _chatController()
        .contacts
        .where((c) => c.relationStatus == 'friends' && !c.isGroupConversation)
        .toList();
    if (friends.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Add friends in Chat to call someone.',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await showSearch(
      context: context,
      delegate: ChatSearchDelegate(
        repo: Get.find<ChatRepository>(),
        friendContacts: friends,
        onUserTap: (user) async {
          await _startVoiceToPeer(
            peerId: user.id,
            peerName: user.name.isNotEmpty ? user.name : user.email,
            conversationId: user.id,
          );
        },
      ),
    );
  }

  Future<void> _openCreateGroup() async {
    final friends = _chatController()
        .contacts
        .where((c) => c.relationStatus == 'friends' && !c.isGroupConversation)
        .toList();
    if (!mounted) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CreateGroupScreen(friendContacts: friends),
      ),
    );
    if (created == true) {
      await _chatController().refreshContacts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group created. Invitations sent.')),
      );
    }
  }

  Future<void> _onHeaderMenuSelected(String value) async {
    if (value == 'Create group') {
      await _openCreateGroup();
      return;
    }
    if (value == 'Add friend') {
      await _openAddFriendSearch();
      return;
    }
    if (value == 'Switch account') {
      await AccountSwitchSheet.show(context);
      return;
    }
    if (value == 'Terms of Service') {
      await Get.to<void>(() => const TermsOfServiceView());
      return;
    }
    if (value == 'Data Processing Agreement') {
      await Get.to<void>(() => const DataProcessingAgreementView());
      return;
    }
    if (value == 'Chat Policy') {
      await Get.to<void>(() => const ChatPolicyView());
      return;
    }
    if (value == 'Logout') {
      await Get.find<AccountSessionManager>().logoutActiveAccount();
    }
  }

  Future<void> _startVoice(CallHistoryEntry e) async {
    await _startVoiceToPeer(
      peerId: e.peerId,
      peerName: e.peerName.isNotEmpty ? e.peerName : 'Contact',
      conversationId: e.peerId,
    );
  }

  Future<void> _startVoiceToPeer({
    required String peerId,
    required String peerName,
    required String conversationId,
  }) async {
    final mic = await Permission.microphone.status;
    final micStatus = mic.isGranted ? mic : await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (micStatus.isPermanentlyDenied || micStatus.isRestricted) {
        await openAppSettings();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Microphone access is required for voice calls.',
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
        peerId: peerId,
        peerName: peerName,
        conversationId: conversationId,
        callerName:
            auth.session?.name ??
            auth.session?.email ??
            auth.userId ??
            AppBranding.defaultUserLabel,
      );
      if (!mounted) return;
      await IncomingCallKitCoordinator.startOutgoingCallkitIfSupported(session: session);
      if (!mounted) return;
      await openVoiceCallScreen(session: session);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError ? error.message : 'Voice call failed to start',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _startVideo(CallHistoryEntry e) async {
    await _startVideoToPeer(
      peerId: e.peerId,
      peerName: e.peerName.isNotEmpty ? e.peerName : 'Contact',
      conversationId: e.peerId,
    );
  }

  Future<void> _startVideoToPeer({
    required String peerId,
    required String peerName,
    required String conversationId,
  }) async {
    final mic = await Permission.microphone.status;
    final micStatus = mic.isGranted ? mic : await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (micStatus.isPermanentlyDenied || micStatus.isRestricted) {
        await openAppSettings();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Microphone access is required for video calls.',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final camGranted = await ensureCameraPermission();
    if (!camGranted) {
      final camStatus = await Permission.camera.status;
      if (camStatus.isPermanentlyDenied || camStatus.isRestricted) {
        await openAppSettings();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Camera access is required for video calls.',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final auth = Get.find<AuthRepository>();
      final svc = Get.find<AgoraCallService>();
      final selfId = (auth.userId ?? '').trim();
      final callerName =
          auth.session?.name ??
          auth.session?.email ??
          auth.userId ??
          AppBranding.defaultUserLabel;
      if (!mounted) return;
      final placeholder = VoiceCallSession.outgoingConnecting(
        peerId: peerId,
        peerName: peerName,
        conversationId: conversationId,
        selfUserId: selfId,
        callType: 'video',
      );
      await openVideoCallScreen(
        session: placeholder,
        outgoingInviteFuture: svc.createAndInviteVideoSession(
          peerId: peerId,
          peerName: peerName,
          conversationId: conversationId,
          callerName: callerName,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError ? error.message : 'Video call failed to start',
            style: GoogleFonts.ptSans(),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _directionIcon(CallHistoryEntry e) {
    if (e.isMissed && !e.isOutgoing) {
      return Icon(Icons.south_west, size: 18, color: _missedRed);
    }
    if (e.isMissed && e.isOutgoing) {
      return Icon(Icons.north_east, size: 18, color: _subtitle);
    }
    if (e.isRejected) {
      return Icon(Icons.call_end, size: 18, color: _subtitle);
    }
    if (e.isOutgoing) {
      return Icon(Icons.north_east, size: 18, color: _waGreen);
    }
    return Icon(Icons.south_west, size: 18, color: _waGreen);
  }

  static String _initialForName(String name) {
    for (final unit in name.runes) {
      final ch = String.fromCharCode(unit).toUpperCase();
      if (ch.trim().isNotEmpty) return ch;
    }
    return '?';
  }

  static String _firstInitial(String s) {
    final t = s.trim();
    if (t.isEmpty) return '?';
    return t[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthRepository>().session;
    final userName = auth?.name ?? '';
    final initial = _firstInitial(
      userName.isNotEmpty ? userName : (auth?.email ?? '?'),
    );
    final now = DateTime.now();

    return Scaffold(
      backgroundColor: ChatScreen.overlay,
      floatingActionButton: FloatingActionButton(
        onPressed: () => unawaited(_openFriendsCallSearch()),
        backgroundColor: kPrimaryBlue,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add_call),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/chat.jpeg',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
          ColoredBox(color: ChatScreen.overlay.withValues(alpha: 0.88)),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: _CallsSearchHeader(
                    surfaceColor: ChatScreen.appBarSurface,
                    hintColor: ChatScreen.searchHint,
                    iconColor: ChatScreen.appBarIcon,
                    initial: initial,
                    isSelfOnline: _selfOnlineUi,
                    searchController: _searchController,
                    onSearchChanged: (v) => _searchQuery.value = v,
                    onMenuSelected: _onHeaderMenuSelected,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: _CallsSectionLabel(),
                ),
                Expanded(
                  child: Obx(() {
                    final hist = Get.isRegistered<CallsHistoryController>()
                        ? Get.find<CallsHistoryController>()
                        : null;
                    if (hist == null) {
                      return Center(
                        child: Text(
                          'Calls are not available.',
                          style: GoogleFonts.ptSans(color: Colors.white70, fontSize: 14),
                        ),
                      );
                    }
                    if (hist.isLoading.value && hist.rows.isEmpty) {
                      return const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: kPrimaryBlue,
                        ),
                      );
                    }
                    if (hist.error.value != null && hist.rows.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                hist.error.value!,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.ptSans(color: Colors.white70, fontSize: 14),
                              ),
                              const SizedBox(height: 16),
                              TextButton(
                                onPressed: () => unawaited(hist.refresh()),
                                child: Text(
                                  'Retry',
                                  style: GoogleFonts.ptSans(color: kPrimaryBlue),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    // Copy so Obx tracks [CallsHistoryController.rows] (RxList) updates.
                    final rowSource = List<CallHistoryDisplayRow>.from(hist.rows);
                    final filtered = _filteredRows(rowSource, _searchQuery.value, now);
                    if (filtered.isEmpty) {
                      return Center(
                        child: Text(
                          rowSource.isEmpty ? 'No call history yet' : 'No matching calls',
                          style: GoogleFonts.ptSans(color: Colors.white70, fontSize: 15),
                        ),
                      );
                    }
                    return RefreshIndicator(
                      color: kPrimaryBlue,
                      onRefresh: () => hist.refresh(),
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 100),
                        itemCount: filtered.length,
                        separatorBuilder: (_, i) => Divider(
                          color: Colors.white.withValues(alpha: 0.05),
                          height: 2,
                        ),
                        itemBuilder: (context, index) {
                          final row = filtered[index];
                          final e = row.representative;
                          final avatarColor =
                              _callHistoryAvatarColors[index % _callHistoryAvatarColors.length];
                          final initial = _initialForName(e.peerName);
                          final missedStyle = e.isMissed && !e.isOutgoing;
                          final nameColor = missedStyle ? _missedRed : Colors.white;
                          final displayName = row.hasGroupedMisses
                              ? '${e.peerName} (${row.missedCount})'
                              : e.peerName;
                          final timeLabel = _formatListTime(e.createdAt, now);
                          final showTalkDuration = e.isEnded && e.durationSeconds > 0;
                          final talkLabel =
                              CallEventChatMessage.formatCallDuration(e.durationSeconds);
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => unawaited(_onRowTap(row)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: ClipOval(
                                        child: e.peerAvatar.trim().isNotEmpty
                                            ? Image.network(
                                                e.peerAvatar.trim(),
                                                fit: BoxFit.cover,
                                                errorBuilder: (context, error, stackTrace) {
                                                  return _callsAvatarColorFill(
                                                    color: avatarColor,
                                                    initial: initial,
                                                  );
                                                },
                                              )
                                            : _callsAvatarColorFill(
                                                color: avatarColor,
                                                initial: initial,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.ptSans(
                                              color: nameColor,
                                              fontSize: 17,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.only(top: 2),
                                                child: _directionIcon(e),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text.rich(
                                                  TextSpan(
                                                    style: GoogleFonts.ptSans(
                                                      color: _subtitle,
                                                      fontSize: 14,
                                                    ),
                                                    children: [
                                                      TextSpan(text: timeLabel),
                                                      if (showTalkDuration) ...[
                                                        const TextSpan(text: ' · '),
                                                        TextSpan(
                                                          text: talkLabel,
                                                          style: const TextStyle(
                                                            fontWeight: FontWeight.w500,
                                                          ),
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (e.isVideo)
                                      IconButton(
                                        tooltip: 'Video call',
                                        onPressed: () => unawaited(_startVideo(e)),
                                        icon: const Icon(
                                          Icons.videocam,
                                          color: Colors.white,
                                        ),
                                      )
                                    else
                                      IconButton(
                                        tooltip: 'Voice call',
                                        onPressed: () => unawaited(_startVoice(e)),
                                        icon: const Icon(
                                          Icons.call,
                                          color: Colors.white,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Colorful fallback / error state for call-history avatars (matches chat list style).
Widget _callsAvatarColorFill({
  required Color color,
  required String initial,
}) {
  return DecoratedBox(
    decoration: BoxDecoration(color: color),
    child: Center(
      child: Text(
        initial,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 18,
        ),
      ),
    ),
  );
}

class _CallsSearchHeader extends StatelessWidget {
  const _CallsSearchHeader({
    required this.surfaceColor,
    required this.hintColor,
    required this.iconColor,
    required this.initial,
    required this.isSelfOnline,
    required this.searchController,
    required this.onSearchChanged,
    required this.onMenuSelected,
  });

  final Color surfaceColor;
  final Color hintColor;
  final Color iconColor;
  final String initial;
  final bool isSelfOnline;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final Future<void> Function(String value) onMenuSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Material(
            color: surfaceColor,
            elevation: 6,
            shadowColor: Colors.black.withValues(alpha: 0.45),
            surfaceTintColor: Colors.transparent,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.search_rounded, size: 24, color: hintColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 24,
                      child: TextField(
                        controller: searchController,
                        onChanged: onSearchChanged,
                        maxLines: 1,
                        textAlignVertical: TextAlignVertical.center,
                        style: ChatScreen.searchPillStyle(Colors.white),
                        cursorColor: iconColor,
                        decoration: InputDecoration(
                          hintText: 'Search call history',
                          hintStyle: ChatScreen.searchPillStyle(hintColor),
                          border: InputBorder.none,
                          isDense: true,
                          isCollapsed: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        PopupMenuButton<String>(
          tooltip: 'Calls menu',
          color: ChatScreen.appBarSurface,
          constraints: const BoxConstraints(minWidth: 190),
          elevation: 14,
          position: PopupMenuPosition.under,
          itemBuilder: (context) => const [
            PopupMenuItem<String>(
              value: 'Create group',
              child: _CallsProfileMenuItem(
                icon: Icons.group_add_outlined,
                label: 'Create group',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Add friend',
              child: _CallsProfileMenuItem(
                icon: Icons.person_add_alt_1_outlined,
                label: 'Add friend',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Switch account',
              child: _CallsProfileMenuItem(
                icon: Icons.switch_account_rounded,
                label: 'Switch account',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Terms of Service',
              child: _CallsProfileMenuItem(
                icon: Icons.gavel_rounded,
                label: 'Terms of Service',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Data Processing Agreement',
              child: _CallsProfileMenuItem(
                icon: Icons.privacy_tip_outlined,
                label: 'Data Processing Agreement',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Chat Policy',
              child: _CallsProfileMenuItem(
                icon: Icons.policy_outlined,
                label: 'Chat Policy',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Logout',
              child: _CallsProfileMenuItem(
                icon: Icons.logout_rounded,
                label: 'Logout',
              ),
            ),
          ],
          onSelected: (value) => unawaited(onMenuSelected(value)),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: kPrimaryBlue.withValues(alpha: 0.92),
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    height: 1,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: isSelfOnline ? const Color(0xFF22C55E) : const Color(0xFF6B7280),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ChatScreen.overlay,
                      width: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CallsSectionLabel extends StatelessWidget {
  const _CallsSectionLabel();

  @override
  Widget build(BuildContext context) {
    return Text(
      'RECENT CALLS',
      style: GoogleFonts.ptSans(
        color: Colors.white.withValues(alpha: 0.72),
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.35,
        height: 1.2,
      ),
    );
  }
}

class _CallsProfileMenuItem extends StatelessWidget {
  const _CallsProfileMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.92)),
        const SizedBox(width: 10),
        Text(
          label,
          style: GoogleFonts.ptSans(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
