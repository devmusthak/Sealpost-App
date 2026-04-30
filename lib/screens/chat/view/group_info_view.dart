import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/auth/auth_repository.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_group.dart';
import '../../../data/chat/chat_repository.dart';
import '../../chat/controller/chat_controller.dart';
import 'create_group_view.dart';
import 'group_shared_content_view.dart';

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.contact});

  final ChatContact contact;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  ChatGroupInfo? _info;
  bool _busy = true;
  String? _error;
  final ScrollController _membersScroll = ScrollController();
  final List<ChatGroupMember> _members = <ChatGroupMember>[];
  int _memberPage = 1;
  bool _membersBusy = false;
  bool _hasMoreMembers = true;

  @override
  void initState() {
    super.initState();
    _membersScroll.addListener(() {
      if (_membersScroll.position.pixels >
          _membersScroll.position.maxScrollExtent - 140) {
        unawaited(_loadMoreMembers());
      }
    });
    _load();
  }

  @override
  void dispose() {
    _membersScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final gid = widget.contact.conversationId;
      final info = await Get.find<ChatRepository>().fetchGroupInfo(gid);
      if (!mounted) return;
      setState(() {
        _info = info;
        _members
          ..clear()
          ..addAll(info.members.where((m) => m.isAccepted));
        _memberPage = 1;
        _hasMoreMembers = true;
      });
      unawaited(_loadMoreMembers());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadMoreMembers() async {
    if (_membersBusy || !_hasMoreMembers) return;
    setState(() => _membersBusy = true);
    try {
      final res = await Get.find<ChatRepository>().fetchGroupMembers(
        groupId: widget.contact.conversationId,
        page: _memberPage + 1,
        limit: 25,
      );
      if (!mounted) return;
      setState(() {
        _memberPage += 1;
        _hasMoreMembers = res.hasMore;
        final existing = _members.map((e) => e.userId).toSet();
        for (final m in res.items) {
          if (!m.isAccepted || existing.contains(m.userId)) continue;
          _members.add(m);
        }
      });
    } catch (_) {
      // Keep already loaded members.
    } finally {
      if (mounted) setState(() => _membersBusy = false);
    }
  }

  Future<void> _openAddMembers() async {
    List<ChatContact> all = <ChatContact>[];
    try {
      // Always fetch latest contacts so SearchDelegate has real friend data.
      all = (await Get.find<ChatRepository>().fetchContacts())
          .where((c) => !c.isGroupConversation && c.relationStatus == 'friends')
          .toList();
    } catch (_) {
      // Fallback to in-memory contacts if network refresh fails.
      all = Get.isRegistered<ChatController>()
          ? Get.find<ChatController>().contacts
              .where((c) => !c.isGroupConversation && c.relationStatus == 'friends')
              .toList()
          : <ChatContact>[];
    }
    final existingIds = _members.map((m) => m.userId).toSet();
    final candidates = all.where((c) => !existingIds.contains(c.id)).toList();
    if (candidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No eligible friends to add')),
      );
      return;
    }
    if (!mounted) return;
    final changed = await showSearch<bool>(
      context: context,
      delegate: _GroupAddMembersSearchDelegate(
        groupId: widget.contact.conversationId,
        candidates: candidates,
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  Future<void> _copyInviteLink() async {
    final fallback = 'https://sealpost.app/invite/group/${widget.contact.conversationId}';
    final link = (_info?.inviteLink.trim().isNotEmpty == true) ? _info!.inviteLink.trim() : fallback;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied')),
    );
  }

  Future<void> _openEditGroupDialog() async {
    final info = _info;
    if (info == null) return;
    final all = Get.isRegistered<ChatController>()
        ? Get.find<ChatController>().contacts
            .where((c) => !c.isGroupConversation && c.relationStatus == 'friends')
            .toList()
        : <ChatContact>[];
    final acceptedIds =
        info.members.where((m) => m.isAccepted).map((m) => m.userId).toList();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CreateGroupScreen(
          friendContacts: all,
          editGroupId: widget.contact.conversationId,
          initialName: info.groupName,
          initialDescription: info.description,
          initialImageUrl: info.groupImage,
          initialMemberIds: acceptedIds,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group updated')),
      );
    }
  }

  Color _memberAvatarColor(String key) {
    const palette = <Color>[
      Color(0xFF2563EB),
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
      Color(0xFFEA580C),
      Color(0xFF059669),
      Color(0xFF0891B2),
      Color(0xFF4F46E5),
      Color(0xFF16A34A),
    ];
    final seed = key.trim().isEmpty ? 0 : key.trim().codeUnits.fold<int>(0, (a, b) => a + b);
    return palette[seed % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final meId = Get.find<AuthRepository>().userId?.trim() ?? '';
    final isGroupAdmin = info != null &&
        info.members.any(
          (m) => m.userId == meId && m.isAccepted && m.isAdmin,
        );
    final title = (info?.groupName.isNotEmpty == true
            ? info!.groupName
            : widget.contact.name)
        .trim();
    final initial = title.isEmpty ? '?' : title.substring(0, 1).toUpperCase();
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF000000),
        foregroundColor: Colors.white,
        title: const Text('Group info'),
        actions: [
          IconButton(
            tooltip: 'Edit group',
            icon: const Icon(Icons.edit_rounded),
            onPressed: _busy ? null : _openEditGroupDialog,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
          ? Center(
              child: Text(
                'Could not load group info',
                style: GoogleFonts.ptSans(color: Colors.white70),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                controller: _membersScroll,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
                children: [
                  CircleAvatar(
                    radius: 80,
                    backgroundImage: (info?.groupImage ?? widget.contact.groupImage).trim().isNotEmpty
                        ? NetworkImage((info?.groupImage ?? widget.contact.groupImage).trim())
                        : null,
                    onBackgroundImageError: (_, _) {},
                    child: (info?.groupImage ?? widget.contact.groupImage).trim().isEmpty
                        ? Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 28,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    info?.groupName.isNotEmpty == true
                        ? info!.groupName
                        : widget.contact.name,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.ptSans(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if ((info?.description ?? widget.contact.groupDescription).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        info?.description ?? widget.contact.groupDescription,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.ptSans(
                          color: Colors.white.withValues(alpha: 0.74),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    '${info?.memberCount ?? _members.where((m) => m.isAccepted).length} members',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.ptSans(color: Colors.white60, fontSize: 13),
                  ),
                  if (info?.createdAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Created ${info!.createdAt!.toLocal().toString().split(' ').first}',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.ptSans(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 20),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.perm_media_rounded, color: Colors.white),
                    title: const Text('Media, Links, Documents', style: TextStyle(color: Colors.white)),
                    trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => GroupSharedContentScreen(
                            groupId: widget.contact.conversationId,
                            contact: widget.contact,
                          ),
                        ),
                      );
                    },
                  ),
                  if (isGroupAdmin)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.group_add_rounded, color: Colors.white),
                      title: const Text('Add members', style: TextStyle(color: Colors.white)),
                      onTap: _openAddMembers,
                    ),
                  if (isGroupAdmin)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.link_rounded, color: Colors.white),
                      title: const Text('Invite via link', style: TextStyle(color: Colors.white)),
                      onTap: _copyInviteLink,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Joined members',
                    style: GoogleFonts.ptSans(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...(_members.where((m) => m.isAccepted).map((m) {
                    final avatarKey = m.userId.isNotEmpty ? m.userId : (m.name.isNotEmpty ? m.name : m.email);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: _memberAvatarColor(avatarKey),
                        child: Text(m.name.trim().isEmpty ? '?' : m.name.trim()[0].toUpperCase()),
                      ),
                      title: Text(
                        m.name.isNotEmpty ? m.name : m.email,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        m.isAdmin
                            ? 'Admin'
                            : (m.isOnline ? 'Online' : (m.email.isNotEmpty ? m.email : 'Member')),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                    );
                  })),
                  if (_membersBusy)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                ],
              ),
            ),
    );
  }
}

class _GroupAddMembersSearchDelegate extends SearchDelegate<bool> {
  _GroupAddMembersSearchDelegate({
    required this.groupId,
    required this.candidates,
  });

  final String groupId;
  final List<ChatContact> candidates;

  bool _changed = false;

  @override
  String get searchFieldLabel => 'Search friends';

  List<ChatContact> get _filtered {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return candidates;
    return candidates.where((c) {
      return c.name.toLowerCase().contains(q) || c.email.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _confirmAndAdd(BuildContext context, ChatContact c) async {
    final title = c.name.trim().isNotEmpty ? c.name.trim() : c.email.trim();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF000000),
          title: const Text('Add member', style: TextStyle(color: Colors.white)),
          content: Text(
            'Are you sure to add this person to group?\n\n$title',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Yes'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    try {
      await Get.find<ChatRepository>().addGroupMembers(
        groupId: groupId,
        memberIds: [c.id],
      );
      _changed = true;
      messenger?.showSnackBar(
        SnackBar(content: Text('${title.isEmpty ? 'Member' : title} added to group')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not add member: $e')),
      );
    }
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            query = '';
            showSuggestions(context);
          },
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: () => close(context, _changed),
    );
  }

  Widget _buildResults(BuildContext context) {
    final list = _filtered;
    if (list.isEmpty) {
      return const Center(
        child: Text('No friends found', style: TextStyle(color: Colors.white70)),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final c = list[i];
        final name = c.name.trim().isNotEmpty ? c.name.trim() : c.email.trim();
        return ListTile(
          onTap: () => _confirmAndAdd(context, c),
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF334155),
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          title: Text(name, style: const TextStyle(color: Colors.white)),
          subtitle: Text(
            c.email,
            style: const TextStyle(color: Colors.white60),
          ),
        );
      },
    );
  }

  @override
  ThemeData appBarTheme(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF000000),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000000),
        foregroundColor: Colors.white,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: Colors.white54),
        border: InputBorder.none,
      ),
      textTheme: base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildResults(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildResults(context);
}
