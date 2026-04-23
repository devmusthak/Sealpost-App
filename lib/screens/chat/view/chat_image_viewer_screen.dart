import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

/// Full-screen zoom + save + share.
class ChatImageViewerScreen extends StatefulWidget {
  const ChatImageViewerScreen({
    super.key,
    required this.paths,
    this.initialIndex = 0,
  });

  /// Local file paths (must exist).
  final List<String> paths;
  final int initialIndex;

  @override
  State<ChatImageViewerScreen> createState() => _ChatImageViewerScreenState();
}

class _ChatImageViewerScreenState extends State<ChatImageViewerScreen> {
  late final PageController _ctrl =
      PageController(initialPage: widget.initialIndex.clamp(0, widget.paths.length - 1));
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _i = widget.initialIndex.clamp(0, widget.paths.length - 1);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = widget.paths[_i];
    final f = File(p);
    if (!await f.exists()) return;
    try {
      await Gal.putImage(p);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to gallery', style: GoogleFonts.ptSans())),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e', style: GoogleFonts.ptSans())),
      );
    }
  }

  Future<void> _share() async {
    final p = widget.paths[_i];
    final f = File(p);
    if (!await f.exists()) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(p)]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.download_rounded),
            onPressed: _save,
          ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_rounded),
            onPressed: _share,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _ctrl,
        itemCount: widget.paths.length,
        onPageChanged: (v) => setState(() => _i = v),
        itemBuilder: (ctx, i) {
          final path = widget.paths[i];
          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
              ),
            ),
          );
        },
      ),
    );
  }
}
