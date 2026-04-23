import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_media_repository.dart';
import '../../../data/chat/chat_repository.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({
    super.key,
    required this.friendContacts,
    this.editGroupId,
    this.initialName,
    this.initialDescription,
    this.initialImageUrl,
    this.initialMemberIds = const [],
  });

  final List<ChatContact> friendContacts;
  final String? editGroupId;
  final String? initialName;
  final String? initialDescription;
  final String? initialImageUrl;
  final List<String> initialMemberIds;

  bool get isEditMode => editGroupId != null && editGroupId!.trim().isNotEmpty;

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _pickedMemberIds = <String>{};
  XFile? _pickedImage;
  String _initialImageUrl = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = (widget.initialName ?? '').trim();
    _descCtrl.text = (widget.initialDescription ?? '').trim();
    _initialImageUrl = (widget.initialImageUrl ?? '').trim();
    if (widget.initialMemberIds.isNotEmpty) {
      final allowed = widget.friendContacts.map((e) => e.id).toSet();
      for (final id in widget.initialMemberIds) {
        if (allowed.contains(id)) _pickedMemberIds.add(id);
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickGroupImage() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1400,
    );
    if (!mounted || file == null) return;
    setState(() => _pickedImage = file);
  }

  Future<void> _submitGroup() async {
    if (_busy) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name is required')),
      );
      return;
    }
    if (!widget.isEditMode && _pickedMemberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      String imageUrl = _initialImageUrl;
      final picked = _pickedImage;
      if (picked != null) {
        final up = await Get.find<ChatMediaRepository>().uploadImage(picked);
        imageUrl = up.url;
      }
      if (widget.isEditMode) {
        final groupId = widget.editGroupId!.trim();
        await Get.find<ChatRepository>().updateGroupInfo(
          groupId: groupId,
          groupName: name,
          description: _descCtrl.text.trim(),
          groupImage: imageUrl,
        );
        final initialSet = widget.initialMemberIds.toSet();
        final addIds = _pickedMemberIds.where((id) => !initialSet.contains(id)).toList();
        if (addIds.isNotEmpty) {
          await Get.find<ChatRepository>().addGroupMembers(
            groupId: groupId,
            memberIds: addIds,
          );
        }
      } else {
        await Get.find<ChatRepository>().createGroup(
          groupName: name,
          groupImage: imageUrl.isEmpty ? null : imageUrl,
          description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
          memberIds: _pickedMemberIds.toList(),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isEditMode
                ? 'Could not update group: $e'
                : 'Could not create group: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF202124),
        foregroundColor: Colors.white,
        title: Text(widget.isEditMode ? 'Edit Group' : 'Create Group'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  InkWell(
                    onTap: _pickGroupImage,
                    borderRadius: BorderRadius.circular(36),
                    child: CircleAvatar(
                      radius: 32,
                      backgroundColor: const Color(0xFF3A3B3C),
                      backgroundImage: _pickedImage != null
                          ? FileImage(File(_pickedImage!.path))
                          : (_initialImageUrl.isNotEmpty
                                ? NetworkImage(_initialImageUrl)
                                : null),
                      child: _pickedImage == null
                          ? (_initialImageUrl.isEmpty
                                ? const Icon(Icons.group, color: Colors.white, size: 28)
                                : null)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Group name *',
                        labelStyle: TextStyle(color: Colors.white70),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF53C5FF)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _descCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  labelStyle: TextStyle(color: Colors.white70),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF53C5FF)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text(
                    'Add members (${_pickedMemberIds.length})',
                    style: GoogleFonts.ptSans(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.friendContacts.length,
                itemBuilder: (context, i) {
                  final c = widget.friendContacts[i];
                  final selected = _pickedMemberIds.contains(c.id);
                  return CheckboxListTile(
                    value: selected,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _pickedMemberIds.add(c.id);
                        } else {
                          _pickedMemberIds.remove(c.id);
                        }
                      });
                    },
                    title: Text(
                      c.name,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      c.email,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.62)),
                    ),
                    activeColor: const Color(0xFF53C5FF),
                    checkColor: Colors.black,
                    controlAffinity: ListTileControlAffinity.trailing,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submitGroup,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF53C5FF),
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(46),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(widget.isEditMode ? 'Save Group' : 'Create Group'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
