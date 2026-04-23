import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_group.dart';
import '../../../data/chat/chat_repository.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
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
      setState(() => _info = info);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEditGroupDialog() async {
    final info = _info;
    final nameCtrl = TextEditingController(
      text: info?.groupName.isNotEmpty == true ? info!.groupName : widget.contact.name,
    );
    final descCtrl = TextEditingController(
      text: info?.description ?? widget.contact.groupDescription,
    );
    final imgCtrl = TextEditingController(
      text: info?.groupImage.isNotEmpty == true ? info!.groupImage : widget.contact.groupImage,
    );
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF202124),
              title: const Text('Edit group', style: TextStyle(color: Colors.white)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Group name',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: imgCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Group image URL',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final nextName = nameCtrl.text.trim();
                          if (nextName.isEmpty) return;
                          setLocal(() => busy = true);
                          try {
                            final updated = await Get.find<ChatRepository>().updateGroupInfo(
                              groupId: widget.contact.conversationId,
                              groupName: nextName,
                              description: descCtrl.text.trim(),
                              groupImage: imgCtrl.text.trim(),
                            );
                            if (!mounted || !dialogContext.mounted) return;
                            setState(() => _info = updated);
                            Navigator.of(dialogContext).pop();
                          } catch (e) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Could not update group: $e')),
                            );
                            setLocal(() => busy = false);
                          }
                        },
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    nameCtrl.dispose();
    descCtrl.dispose();
    imgCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final title = (info?.groupName.isNotEmpty == true
            ? info!.groupName
            : widget.contact.name)
        .trim();
    final initial = title.isEmpty ? '?' : title.substring(0, 1).toUpperCase();
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF202124),
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
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
                children: [
                  SizedBox(
                    width: 88,
                    height: 88,
                    child: ClipOval(
                      child: (info?.groupImage ?? widget.contact.groupImage).trim().isNotEmpty
                          ? Image.network(
                              (info?.groupImage ?? widget.contact.groupImage).trim(),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF53C5FF).withValues(alpha: 0.22),
                                  ),
                                  child: Center(
                                    child: Text(
                                      initial,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 28,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          : DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xFF53C5FF).withValues(alpha: 0.22),
                              ),
                              child: Center(
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 28,
                                  ),
                                ),
                              ),
                            ),
                    ),
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
                  const SizedBox(height: 20),
                  Text(
                    'Members',
                    style: GoogleFonts.ptSans(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...((info?.members ?? const <ChatGroupMember>[]) .map((m) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF3A3B3C),
                        child: Text(
                          m.name.trim().isEmpty ? '?' : m.name.trim()[0].toUpperCase(),
                        ),
                      ),
                      title: Text(
                        m.name.isNotEmpty ? m.name : m.email,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        m.isAdmin ? 'Admin' : m.status,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                    );
                  })),
                ],
              ),
            ),
    );
  }
}
