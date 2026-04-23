import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../../theme/app_theme.dart';

/// Preview a single gallery video before sending (caption + send).
class ChatVideoPreviewScreen extends StatefulWidget {
  const ChatVideoPreviewScreen({super.key, required this.file});

  final XFile file;

  @override
  State<ChatVideoPreviewScreen> createState() => _ChatVideoPreviewScreenState();
}

class _ChatVideoPreviewScreenState extends State<ChatVideoPreviewScreen> {
  VideoPlayerController? _controller;
  final _caption = TextEditingController();

  static const _bar = Color(0xFF121212);
  static const _field = Color(0xFF3A3A3A);

  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.file.path))
      ..initialize().then((_) {
        if (!mounted) return;
        _controller!.addListener(_onVideoTick);
        setState(() {});
      });
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _caption.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  void _onVideoSurfaceTap() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
      setState(() {});
    }
  }

  static String _formatDuration(Duration d) {
    final s = d.inSeconds.clamp(0, 1 << 20);
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Widget _videoPreviewStack(VideoPlayerController c) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.hardEdge,
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: VideoPlayer(c),
        ),
        if (!c.value.isPlaying)
          ColoredBox(
            color: Colors.black.withValues(alpha: 0.28),
          ),
        if (!c.value.isPlaying)
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _togglePlay,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Icon(
                  Icons.play_circle_filled_rounded,
                  size: 88,
                  color: Colors.white.withValues(alpha: 0.95),
                ),
              ),
            ),
          ),
        if (c.value.isPlaying)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _onVideoSurfaceTap,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.black.withValues(alpha: 0.45),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VideoProgressIndicator(
                  c,
                  allowScrubbing: true,
                  padding: EdgeInsets.zero,
                  colors: VideoProgressColors(
                    playedColor: kPrimaryBlue,
                    bufferedColor: Colors.white30,
                    backgroundColor: Colors.white12,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(c.value.position),
                        style: GoogleFonts.ptSans(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                      Text(
                        _formatDuration(c.value.duration),
                        style: GoogleFonts.ptSans(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
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
          'Video',
          style: GoogleFonts.ptSans(fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: c != null && c.value.isInitialized
                ? LayoutBuilder(
                    builder: (context, constraints) {
                      final maxW = constraints.maxWidth;
                      final ar = c.value.aspectRatio;
                      final intrinsicH = maxW / ar;
                      return ClipRect(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: maxW,
                            height: intrinsicH,
                            child: _videoPreviewStack(c),
                          ),
                        ),
                      );
                    },
                  )
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  ),
          ),
          SafeArea(
            top: false,
            minimum: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      style: GoogleFonts.ptSans(color: Colors.white, fontSize: 15),
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Add a caption… · max 20 MB',
                        hintStyle: GoogleFonts.ptSans(color: Colors.white54, fontSize: 14),
                        filled: true,
                        fillColor: _field,
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Material(
                    color: kPrimaryBlue,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: c != null && c.value.isInitialized
                          ? () {
                              Navigator.of(context).pop(
                                ChatVideoPreviewResult(
                                  file: widget.file,
                                  caption: _caption.text,
                                ),
                              );
                            }
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.send_rounded,
                          color: c != null && c.value.isInitialized
                              ? Colors.white
                              : Colors.white38,
                          size: 22,
                        ),
                      ),
                    ),
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

class ChatVideoPreviewResult {
  const ChatVideoPreviewResult({
    required this.file,
    required this.caption,
  });

  final XFile file;
  final String caption;
}
