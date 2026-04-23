import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/chat/chat_repository.dart';

class GroupInvitePreviewWidget extends StatefulWidget {
  const GroupInvitePreviewWidget({
    super.key,
    required this.inviteId,
    required this.outgoing,
  });

  final String inviteId;
  final bool outgoing;

  @override
  State<GroupInvitePreviewWidget> createState() => _GroupInvitePreviewWidgetState();
}

class _GroupInvitePreviewWidgetState extends State<GroupInvitePreviewWidget> {
  Map<String, dynamic>? _info;
  bool _busy = false;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final info = await Get.find<ChatRepository>().fetchGroupInviteInfo(widget.inviteId);
      if (!mounted) return;
      setState(() => _info = info);
    } catch (_) {
      // Keep compact fallback UI.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    try {
      await Get.find<ChatRepository>().joinGroupByInvite(widget.inviteId);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Joined group')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not join group: $e')),
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _info;
    if (_busy && data == null) {
      return const SizedBox(
        height: 88,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final name = '${data?['groupName'] ?? 'Group invite'}'.trim();
    final image = '${data?['groupImage'] ?? ''}'.trim();
    final count = '${data?['memberCount'] ?? ''}'.trim();
    final alreadyJoined = data?['alreadyJoined'] == true;

    return Container(
      decoration: BoxDecoration(
        color: widget.outgoing ? Colors.black26 : Colors.black38,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: const Color(0xFF2A2B2C),
            backgroundImage: image.isNotEmpty ? NetworkImage(image) : null,
            child: image.isEmpty ? const Icon(Icons.groups_2_rounded, color: Colors.white) : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name.isNotEmpty ? name : 'Group invite',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ptSans(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  count.isNotEmpty ? '$count members' : 'Invite to group',
                  style: GoogleFonts.ptSans(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: alreadyJoined || _joining ? null : _join,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: Colors.black,
              minimumSize: const Size(62, 34),
            ),
            child: Text(alreadyJoined ? 'Joined' : (_joining ? '...' : 'Join')),
          ),
        ],
      ),
    );
  }
}

