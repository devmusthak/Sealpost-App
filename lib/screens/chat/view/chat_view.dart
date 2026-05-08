import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../../core/share/share_receive_service.dart';
import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_list_last_message_preview.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_repository.dart';
import '../../../data/chat/chat_user.dart';
import '../../../data/session/account_session_manager.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/chat_action_dialog.dart';
import '../../../widgets/account_switch_sheet.dart';
import '../../chat_policy/view/chat_policy_view.dart';
import '../../data_processing_agreement/view/data_processing_agreement_view.dart';
import '../../terms_of_service/view/terms_of_service_view.dart';
import '../chat_open_thread.dart';
import '../controller/chat_controller.dart';
import 'create_group_view.dart';
import 'chat_search_delegate.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.forwardMessageBodies});

  /// One outgoing bubble per entry when the user picks a chat (forward flow).
  final List<String>? forwardMessageBodies;

  static const overlay = Color(0xFF121212);
  static const appBarSurface = Color(0xFF202124);
  static const searchHint = Color(0xFF9AA0A6);
  static const appBarIcon = Color(0xFFE8EAED);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final ChatController _controller;

  bool get _pickingForward =>
      widget.forwardMessageBodies != null &&
      widget.forwardMessageBodies!.any((s) => s.trim().isNotEmpty);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Get.isRegistered<ChatController>()) {
      _controller = Get.find<ChatController>();
    } else {
      _controller = Get.put(ChatController());
    }
    unawaited(_controller.refreshContacts());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_pickingForward) {
      Get.delete<ChatController>();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {});
  }

  /// Matches in-app presence: green while foreground / inactive; gray when backgrounded or killed.
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

  Future<void> _onSearchUserTap(ChatUser user) async {
    if (!mounted) return;
    if (user.relationStatus == 'friends') {
      _openChatThread(_chatContactFromUser(user));
      return;
    }
    await _showActionModal(user);
  }

  Future<void> _openAddFriendSearch() async {
    if (!mounted) return;
    // Let popup menu dismissal finish before pushing SearchDelegate route.
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

  ChatContact _chatContactFromUser(ChatUser u) {
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

  Future<void> _openCreateGroup() async {
    final friends = _controller.contacts
        .where((c) => c.relationStatus == 'friends' && !c.isGroupConversation)
        .toList();
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CreateGroupScreen(friendContacts: friends),
      ),
    );
    if (created == true) {
      await _controller.refreshContacts();
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
      return;
    }
  }

  void _openChatThread(ChatContact contact) {
    if (!mounted) return;
    final raw = widget.forwardMessageBodies;
    List<String>? filtered;
    if (raw != null && raw.isNotEmpty) {
      filtered = raw.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (filtered.isEmpty) filtered = null;
    }
    List<SharedMediaFile>? share;
    if (!_pickingForward && Get.isRegistered<ShareReceiveService>()) {
      final s = Get.find<ShareReceiveService>();
      final p = s.pending.value;
      if (p != null && p.isNotEmpty) {
        share = List<SharedMediaFile>.from(p);
        unawaited(s.clearPending());
      }
    }
    openChatThread(
      context,
      contact,
      forwardBodies: filtered,
      shareMediaOnOpen: share,
    );
  }

  Future<void> _showActionModal(ChatUser user) {
    if (!mounted) return Future.value();
    final parentContext = context;
    final subtitle =
        '${user.name.isEmpty ? user.email : user.name}  ${user.isOnline ? '• Online' : '• Offline'}\n${user.email}';

    return showDialog<void>(
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
                await _controller.refreshContacts();
                if (!mounted || !parentContext.mounted) return;
                ScaffoldMessenger.of(parentContext).showSnackBar(
                  const SnackBar(content: Text('Friend request accepted')),
                );
                _openChatThread(_chatContactFromUser(user));
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
                await _notifySentRequestUser(user);
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
                _openChatThread(_chatContactFromUser(user));
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
    await _controller.refreshContacts();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Friend request sent')));
  }

  Future<void> _notifySentRequestUser(ChatUser user) async {
    if (user.relationStatus != 'request_sent') return;
    final repo = Get.find<ChatRepository>();
    await repo.notifyFriendRequestUser(user.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Notification sent')));
  }

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthRepository>().session;
    final userName = auth?.name ?? '';
    final initial = _firstInitial(
      userName.isNotEmpty ? userName : (auth?.email ?? '?'),
    );

    final scaffold = Scaffold(
      backgroundColor: ChatScreen.overlay,
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
                if (_pickingForward)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 12, 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back',
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        Expanded(
                          child: Text(
                            'Select a chat to forward',
                            style: GoogleFonts.ptSans(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Obx(() {
                  if (!Get.isRegistered<ShareReceiveService>()) {
                    return const SizedBox.shrink();
                  }
                  final pending = Get.find<ShareReceiveService>().pending.value;
                  if (pending == null || pending.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 12, 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Cancel share',
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            unawaited(
                              Get.find<ShareReceiveService>().clearPending(),
                            );
                          },
                        ),
                        Expanded(
                          child: Text(
                            'Sharing — tap a friend to send',
                            style: GoogleFonts.ptSans(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: _ChatSearchHeader(
                    surfaceColor: ChatScreen.appBarSurface,
                    hintColor: ChatScreen.searchHint,
                    iconColor: ChatScreen.appBarIcon,
                    initial: initial,
                    isSelfOnline: _selfOnlineUi,
                    onUserTap: _onSearchUserTap,
                    onMenuSelected: _onHeaderMenuSelected,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
                  child: _ChatSectionLabel(),
                ),
                Expanded(
                  child: Obx(() {
                    final typingTick = _controller.typingPeerIds.length;
                    if (typingTick < 0) {
                      return const SizedBox.shrink();
                    }
                    if (_controller.isLoading.value &&
                        _controller.contacts.isEmpty) {
                      return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    if (_controller.contacts.isEmpty) {
                      return Center(
                        child: Text(
                          'No friends yet',
                          style: GoogleFonts.ptSans(color: Colors.white70),
                        ),
                      );
                    }
                    return _ChatList(
                      items: _controller.contacts,
                      onTap: _onContactTap,
                      isPeerTyping: _controller.isPeerTyping,
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return scaffold;
  }

  Future<void> _onContactTap(ChatContact item) async {
    if (item.isGroupConversation) {
      if (item.isGroupInvitePending) {
        final parent = context;
        final groupLabel = item.name.trim().isEmpty ? 'this group' : item.name;
        await showDialog<void>(
          context: parent,
          builder: (dialogContext) {
            return ChatActionDialog(
              title: 'Group invitation',
              subtitle: 'You are invited to join $groupLabel',
              primaryText: 'Accept',
              secondaryText: 'Reject',
              primaryFilled: true,
              onPrimary: () async {
                Navigator.of(dialogContext).pop();
                await Get.find<ChatRepository>().respondGroupInvite(
                  groupId: item.conversationId,
                  accept: true,
                );
                await _controller.refreshContacts();
                if (!mounted || !parent.mounted) return;
                ScaffoldMessenger.of(parent).showSnackBar(
                  const SnackBar(content: Text('Group invitation accepted')),
                );
              },
              onSecondary: () async {
                Navigator.of(dialogContext).pop();
                await Get.find<ChatRepository>().respondGroupInvite(
                  groupId: item.conversationId,
                  accept: false,
                );
                await _controller.refreshContacts();
                if (!mounted || !parent.mounted) return;
                ScaffoldMessenger.of(parent).showSnackBar(
                  const SnackBar(content: Text('Group invitation rejected')),
                );
              },
            );
          },
        );
        return;
      }
      _openChatThread(item);
      return;
    }
    if (item.relationStatus == 'friends') {
      _openChatThread(item);
      return;
    }
    if (item.relationStatus != 'request_received' &&
        item.relationStatus != 'request_sent') {
      return;
    }
    if (!mounted) return;
    final parentContext = context;
    await showDialog<void>(
      context: parentContext,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (dialogContext) {
        final isReceived = item.relationStatus == 'request_received';
        return ChatActionDialog(
          title: isReceived ? 'Friend request' : 'Request pending',
          subtitle:
              '${item.name}  ${item.isOnline ? '• Online' : '• Offline'}\n${item.email}',
          primaryText: isReceived ? 'Accept' : 'Notify user',
          secondaryText: 'Close',
          onPrimary: () async {
            Navigator.of(dialogContext).pop();
            if (isReceived) {
              await Get.find<ChatRepository>().acceptFriendRequest(item.id);
              await _controller.refreshContacts();
              if (!mounted || !parentContext.mounted) return;
              ScaffoldMessenger.of(parentContext).showSnackBar(
                const SnackBar(content: Text('Friend request accepted')),
              );
              _openChatThread(
                ChatContact(
                  id: item.id,
                  name: item.name,
                  email: item.email,
                  isOnline: item.isOnline,
                  lastSeenAt: item.lastSeenAt,
                  relationStatus: 'friends',
                  lastMessage: item.lastMessage,
                  timeLabel: item.timeLabel,
                  lastMessageAt: item.lastMessageAt,
                  unreadCount: 0,
                ),
              );
            } else {
              await Get.find<ChatRepository>().notifyFriendRequestUser(item.id);
              if (!mounted || !parentContext.mounted) return;
              ScaffoldMessenger.of(parentContext).showSnackBar(
                const SnackBar(content: Text('Notification sent')),
              );
            }
          },
          onSecondary: () => Navigator.of(dialogContext).pop(),
        );
      },
    );
  }
}

class _ChatSearchHeader extends StatelessWidget {
  const _ChatSearchHeader({
    required this.surfaceColor,
    required this.hintColor,
    required this.iconColor,
    required this.initial,
    required this.isSelfOnline,
    required this.onUserTap,
    required this.onMenuSelected,
  });

  final Color surfaceColor;
  final Color hintColor;
  final Color iconColor;
  final String initial;
  final bool isSelfOnline;
  final Future<void> Function(ChatUser user) onUserTap;
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
            child: InkWell(
              onTap: () async {
                await showSearch(
                  context: context,
                  delegate: ChatSearchDelegate(
                    repo: Get.find<ChatRepository>(),
                    onUserTap: onUserTap,
                  ),
                );
              },
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 24, color: hintColor),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Search in chats',
                        style: GoogleFonts.ptSans(
                          color: hintColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          height: 1.25,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        PopupMenuButton<String>(
          tooltip: 'Chat menu',
          color: ChatScreen.appBarSurface,
          constraints: const BoxConstraints(minWidth: 190),
          elevation: 14,
          position: PopupMenuPosition.under,
          itemBuilder: (context) => const [
            PopupMenuItem<String>(
              value: 'Create group',
              child: _ProfileMenuItem(
                icon: Icons.group_add_outlined,
                label: 'Create group',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Add friend',
              child: _ProfileMenuItem(
                icon: Icons.person_add_alt_1_outlined,
                label: 'Add friend',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Switch account',
              child: _ProfileMenuItem(
                icon: Icons.switch_account_rounded,
                label: 'Switch account',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Terms of Service',
              child: _ProfileMenuItem(
                icon: Icons.gavel_rounded,
                label: 'Terms of Service',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Data Processing Agreement',
              child: _ProfileMenuItem(
                icon: Icons.privacy_tip_outlined,
                label: 'Data Processing Agreement',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Chat Policy',
              child: _ProfileMenuItem(
                icon: Icons.policy_outlined,
                label: 'Chat Policy',
              ),
            ),
            PopupMenuDivider(height: 1, color: Color(0x14FFFFFF)),
            PopupMenuItem<String>(
              value: 'Logout',
              child: _ProfileMenuItem(
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
                    color: isSelfOnline
                        ? const Color(0xFF22C55E)
                        : const Color(0xFF6B7280),
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



class _ChatSectionLabel extends StatelessWidget {
  const _ChatSectionLabel();

  @override
  Widget build(BuildContext context) {
    return Text(
      'RECENT CHATS',
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

class _ChatList extends StatelessWidget {
  const _ChatList({
    required this.items,
    required this.onTap,
    required this.isPeerTyping,
  });
  final List<ChatContact> items;
  final Future<void> Function(ChatContact item) onTap;
  final bool Function(String peerId) isPeerTyping;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 100),
      itemCount: items.length,
      separatorBuilder: (context, index) => Divider(
        color: Colors.white.withValues(alpha: 0.05),
        height: 2,
      ),
      itemBuilder: (context, index) {
        return _ChatThreadTile(
          item: items[index],
          index: index,
          isPeerTyping: isPeerTyping(items[index].id),
          onTap: () => onTap(items[index]),
        );
      },
    );
  }
}

class _ChatThreadTile extends StatelessWidget {
  const _ChatThreadTile({
    required this.item,
    required this.index,
    required this.isPeerTyping,
    required this.onTap,
  });

  final ChatContact item;
  final int index;
  final bool isPeerTyping;
  final VoidCallback onTap;

  static const _avatars = [
    Color(0xFF7C4DFF),
    Color(0xFF448AFF),
    Color(0xFF26A69A),
    Color(0xFFFFA726),
    Color(0xFFEC407A),
  ];

  @override
  Widget build(BuildContext context) {
    final avatarColor = _avatars[index % _avatars.length];
    final initial = item.name.trim().isEmpty ? '?' : item.name.trim()[0].toUpperCase();
    final showTyping = !item.isGroupConversation &&
        item.relationStatus == 'friends' &&
        isPeerTyping;
    final groupLogo = item.groupImage.trim();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: ClipOval(
                      child: groupLogo.isNotEmpty
                          ? Image.network(
                              groupLogo,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return DecoratedBox(
                                  decoration: BoxDecoration(color: avatarColor),
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
                              },
                            )
                          : DecoratedBox(
                              decoration: BoxDecoration(color: avatarColor),
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
                            ),
                    ),
                  ),
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: item.isGroupConversation
                        ? Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F2937),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: ChatScreen.overlay,
                                width: 1.4,
                              ),
                            ),
                            child: const Icon(
                              Icons.groups_2_rounded,
                              size: 9,
                              color: Colors.white,
                            ),
                          )
                        : Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: item.isOnline
                                  ? const Color(0xFF22C55E)
                                  : const Color(0xFF6B7280),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: ChatScreen.overlay,
                                width: 1.6,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showTyping) ...[
                      const SizedBox(height: 4),
                      Text(
                        'typing...',
                        style: GoogleFonts.ptSans(
                          color: const Color(0xFF22C55E),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ] else if (item.isGroupInvitePending) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Group invite pending',
                        style: GoogleFonts.ptSans(
                          color: const Color(0xFFFDE68A),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ] else if (item.relationStatus == 'friends' &&
                        item.lastMessage.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.chatListSubtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 14,
                          height: 1.25,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ] else if (item.lastSeenSubtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.lastSeenSubtitle!,
                        style: GoogleFonts.ptSans(
                          color: Colors.white.withValues(alpha: 0.48),
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          height: 1.25,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ] else if (item.lastMessage.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.chatListSubtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 14,
                          height: 1.25,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (item.chatHomeTimeLabel.trim().isNotEmpty)
                    Text(
                      item.chatHomeTimeLabel,
                      style: GoogleFonts.ptSans(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  if (item.chatHomeTimeLabel.trim().isNotEmpty)
                    const SizedBox(height: 8),
                  if (item.unreadCount > 0)
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: kPrimaryBlue,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(
                        '${item.unreadCount}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileMenuItem extends StatelessWidget {
  const _ProfileMenuItem({required this.icon, required this.label});

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

String _firstInitial(String s) {
  final t = s.trim();
  if (t.isEmpty) return '?';
  return t[0].toUpperCase();
}
