import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../../theme/app_theme.dart';

/// Strip tile size — image thumbnails and “add” tile use the same square.
const double _kChatImageThumbExtent = 72;
const double _kChatImageThumbRadius = 10;
const double _kChatImageThumbBorderIdle = 1.5;
const double _kChatImageThumbBorderSelected = 2.5;

/// WhatsApp-style preview: swipe main image, thumbnail strip, caption, send.
class ChatImagePreviewScreen extends StatefulWidget {
  const ChatImagePreviewScreen({
    super.key,
    required this.initialFiles,
    this.maxImages = 4,
  });

  final List<XFile> initialFiles;
  final int maxImages;

  @override
  State<ChatImagePreviewScreen> createState() => _ChatImagePreviewScreenState();
}

class _ChatImagePreviewScreenState extends State<ChatImagePreviewScreen> {
  late final List<XFile> _files = List<XFile>.from(widget.initialFiles);
  late final PageController _pageCtrl = PageController();
  final _caption = TextEditingController();
  int _index = 0;

  static const _bar = Color(0xFF121212);
  static const _field = Color(0xFF3A3A3A);

  @override
  void dispose() {
    _pageCtrl.dispose();
    _caption.dispose();
    super.dispose();
  }

  Future<void> _addMore() async {
    final room = widget.maxImages - _files.length;
    if (room <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Maximum ${widget.maxImages} images', style: GoogleFonts.ptSans()),
          ),
        );
      }
      return;
    }
    final pick = ImagePicker();
    final more = await pick.pickMultiImage(imageQuality: 85);
    if (!mounted) return;
    if (more.isEmpty) return;
    setState(() {
      for (final f in more) {
        if (_files.length >= widget.maxImages) break;
        _files.add(f);
      }
    });
  }

  void _removeAt(int i) {
    if (_files.length <= 1) return;
    setState(() {
      _files.removeAt(i);
      if (_index >= _files.length) {
        _index = _files.length - 1;
      }
      if (_index < 0) _index = 0;
    });
    if (_pageCtrl.hasClients) {
      _pageCtrl.jumpToPage(_index.clamp(0, _files.length - 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bar,
      appBar: AppBar(
        backgroundColor: _bar,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '${_files.length} photo${_files.length == 1 ? '' : 's'}',
          style: GoogleFonts.ptSans(fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: _files.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (ctx, i) {
                return Center(
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Image.file(
                      File(_files[i].path),
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: SizedBox(
              height: _kChatImageThumbExtent,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _files.length + (widget.maxImages > _files.length ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  if (i == _files.length) {
                    return _ThumbAdd(onTap: _addMore);
                  }
                  final sel = i == _index;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _index = i);
                      _pageCtrl.animateToPage(
                        i,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    },
                    onLongPress: () => _removeAt(i),
                    child: _Thumb(
                      file: _files[i],
                      selected: sel,
                      onRemove: _files.length > 1 ? () => _removeAt(i) : null,
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _caption,
                    style: GoogleFonts.ptSans(color: Colors.white, fontSize: 15),
                    maxLines: 3,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: 'Add a caption…',
                      hintStyle: GoogleFonts.ptSans(color: Colors.white54),
                      filled: true,
                      fillColor: _field,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Swipe photos above · tap thumbnail to select',
                          style: GoogleFonts.ptSans(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                      Material(
                        color: kPrimaryBlue,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () {
                            Navigator.of(context).pop(
                              ChatImagePreviewResult(
                                files: List<XFile>.from(_files),
                                caption: _caption.text,
                              ),
                            );
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Icon(Icons.send_rounded, color: Colors.white, size: 22),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatImagePreviewResult {
  const ChatImagePreviewResult({
    required this.files,
    required this.caption,
  });

  final List<XFile> files;
  final String caption;
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.file,
    required this.selected,
    this.onRemove,
  });

  final XFile file;
  final bool selected;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: _kChatImageThumbExtent,
          height: _kChatImageThumbExtent,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kChatImageThumbRadius),
            border: Border.all(
              color: selected ? kPrimaryBlue : Colors.white.withValues(alpha: 0.38),
              width: selected
                  ? _kChatImageThumbBorderSelected
                  : _kChatImageThumbBorderIdle,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.file(File(file.path), fit: BoxFit.cover),
        ),
        if (onRemove != null)
          Positioned(
            top: -4,
            right: -4,
            child: Material(
              color: Colors.black87,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}

class _ThumbAdd extends StatelessWidget {
  const _ThumbAdd({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_kChatImageThumbRadius),
        child: Ink(
          width: _kChatImageThumbExtent,
          height: _kChatImageThumbExtent,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(_kChatImageThumbRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.38),
              width: _kChatImageThumbBorderIdle,
            ),
          ),
          child: const Center(
            child: Icon(
              Icons.add_photo_alternate_outlined,
              color: Colors.white54,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}
