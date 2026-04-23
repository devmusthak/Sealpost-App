import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../theme/app_theme.dart';

/// Full-screen playback for a chat video on disk — stacked overlay chrome, centered video.
class ChatVideoViewerScreen extends StatefulWidget {
  const ChatVideoViewerScreen({super.key, required this.localPath});

  final String localPath;

  @override
  State<ChatVideoViewerScreen> createState() => _ChatVideoViewerScreenState();
}

class _ChatVideoViewerScreenState extends State<ChatVideoViewerScreen> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initController());
  }

  void _onVideoTick() {
    if (mounted) setState(() {});
  }

  Future<void> _initController() async {
    final f = File(widget.localPath);
    if (!await f.exists()) {
      if (mounted) {
        setState(() {
          _failed = true;
          _initializing = false;
        });
      }
      return;
    }
    final controller = VideoPlayerController.file(f);
    controller.addListener(_onVideoTick);
    try {
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
      await controller.play();
    } catch (_) {
      controller.dispose();
      if (mounted) {
        setState(() {
          _failed = true;
          _initializing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final p = widget.localPath;
    if (!File(p).existsSync()) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(p)]));
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

  static String _formatDuration(Duration d) {
    final s = d.inSeconds.clamp(0, 1 << 20);
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_initializing)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white70,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Loading video…',
                    style: GoogleFonts.ptSans(
                      fontSize: 14,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            )
          else if (_failed || c == null || !c.value.isInitialized)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not open video',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.ptSans(color: Colors.white70, fontSize: 15),
                ),
              ),
            )
          else
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final ar = c.value.aspectRatio;
                  final maxW = constraints.maxWidth;
                  final maxH = constraints.maxHeight;
                  var w = maxW;
                  var h = w / ar;
                  if (h > maxH) {
                    h = maxH;
                    w = h * ar;
                  }
                  w = math.min(w, maxW);
                  h = math.min(h, maxH);
                  return Center(
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: Stack(
                        alignment: Alignment.center,
                        fit: StackFit.expand,
                        children: [
                          VideoPlayer(c),
                          if (!c.value.isPlaying)
                            ColoredBox(
                              color: Colors.black.withValues(alpha: 0.22),
                              child: Center(
                                child: Icon(
                                  Icons.play_circle_filled_rounded,
                                  size: 72,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              ),
                            ),
                          Positioned.fill(
                            child: GestureDetector(
                              onTap: _togglePlay,
                              behavior: HitTestBehavior.translucent,
                              child: const ColoredBox(color: Colors.transparent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.55),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Back',
                            icon: const Icon(Icons.arrow_back_rounded),
                            color: Colors.white,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Share',
                            icon: const Icon(Icons.share_rounded),
                            color: Colors.white,
                            onPressed: _share,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!_initializing && c != null && c.value.isInitialized)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.65),
                        Colors.black.withValues(alpha: 0.35),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
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
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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
              ),
            ),
        ],
      ),
    );
  }
}
