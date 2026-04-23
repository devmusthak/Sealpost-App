import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../data/chat/chat_image_message.dart';
import '../../../data/chat/chat_media_repository.dart';

/// In-memory path cache: content hash → local file path (downloaded video).
final chatVideoFileCache = <String, String>{};

String _hashShort(String hash) {
  final h = hash.trim();
  if (h.length <= 14) return h;
  return '${h.substring(0, 8)}…${h.substring(h.length - 4)}';
}

class ChatMessageVideoBubble extends StatelessWidget {
  const ChatMessageVideoBubble({
    super.key,
    required this.payload,
    required this.outgoing,
    required this.bubbleColor,
    required this.metaColor,
    required this.timeLabel,
    required this.metaStyle,
    this.prefix,
    this.captionBelowVideo = true,
    this.onTapVideo,
    this.onRetry,
    this.trailingMeta,
  });

  final ChatVideoMessage payload;
  final bool outgoing;
  final Color bubbleColor;
  final Color metaColor;
  final String timeLabel;
  final TextStyle metaStyle;
  final Widget? prefix;
  final bool captionBelowVideo;
  final VoidCallback? onTapVideo;
  final VoidCallback? onRetry;
  final Widget? trailingMeta;

  static double _gridWidthFor(BuildContext context, {required bool outgoing}) {
    final screenW = MediaQuery.sizeOf(context).width;
    if (outgoing) {
      return (screenW - 68).clamp(240.0, 340.0);
    }
    return (screenW - 96).clamp(210.0, 300.0);
  }

  @override
  Widget build(BuildContext context) {
    final cap = payload.caption.trim();
    final gridW = _gridWidthFor(context, outgoing: outgoing);
    const innerOther = 8.0;
    final innerLeft = outgoing ? 4.0 : 8.0;
    final usableW = gridW - innerLeft - innerOther;

    return SizedBox(
      width: gridW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (prefix != null) SizedBox(width: gridW, child: prefix),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ColoredBox(
                  color: bubbleColor,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      innerLeft,
                      innerOther - 8,
                      innerOther,
                      innerOther - 8,
                    ),
                    child: _InlineChatVideo(
                      width: usableW,
                      item: payload.item,
                      outgoing: outgoing,
                      onTap: onTapVideo,
                      onRetry: onRetry,
                    ),
                  ),
                ),
                if (trailingMeta != null)
                  Positioned(
                    right: innerOther,
                    bottom: innerOther,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: trailingMeta,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (captionBelowVideo && cap.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: EdgeInsets.only(left: innerLeft),
              child: Text(
                cap,
                style: GoogleFonts.ptSans(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
            ),
          ],
          if (trailingMeta == null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(timeLabel, style: metaStyle),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineChatVideo extends StatefulWidget {
  const _InlineChatVideo({
    required this.width,
    required this.item,
    required this.outgoing,
    this.onTap,
    this.onRetry,
  });

  final double width;
  final ChatImageItem item;
  final bool outgoing;
  final VoidCallback? onTap;
  final VoidCallback? onRetry;

  @override
  State<_InlineChatVideo> createState() => _InlineChatVideoState();
}

class _InlineChatVideoState extends State<_InlineChatVideo> {
  VideoPlayerController? _controller;
  bool _busy = true;
  String? _err;
  double _dlProgress = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void didUpdateWidget(covariant _InlineChatVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url ||
        oldWidget.item.hash != widget.item.hash ||
        oldWidget.item.localPath != widget.item.localPath) {
      _disposeController();
      unawaited(_prepare());
    }
  }

  void _disposeController() {
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  Future<void> _prepare() async {
    final it = widget.item;
    setState(() {
      _busy = true;
      _err = null;
      _dlProgress = 0;
    });

    final lp = it.localPath?.trim() ?? '';
    if (lp.isNotEmpty && File(lp).existsSync()) {
      final c = VideoPlayerController.file(File(lp));
      try {
        await c.initialize();
        await c.setLooping(true);
        await c.pause();
        if (!mounted) return;
        setState(() {
          _controller = c;
          _busy = false;
        });
      } catch (_) {
        c.dispose();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _err = 'Could not open video';
        });
      }
      return;
    }

    final h = it.hash.trim().toLowerCase();
    if (h.isNotEmpty && chatVideoFileCache.containsKey(h)) {
      final p = chatVideoFileCache[h]!;
      if (File(p).existsSync()) {
        final c = VideoPlayerController.file(File(p));
        try {
          await c.initialize();
          await c.setLooping(true);
          await c.pause();
          if (!mounted) return;
          setState(() {
            _controller = c;
            _busy = false;
          });
        } catch (_) {
          c.dispose();
          if (!mounted) return;
          setState(() {
            _busy = false;
            _err = 'Could not open video';
          });
        }
        return;
      }
    }

    final url = it.url.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      if (!mounted) return;
      setState(() {
        _busy = false;
      });
      return;
    }

    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/chat_vid_$h.mp4';
      final f = File(path);
      if (await f.exists() && await f.length() > 0) {
        chatVideoFileCache[h] = path;
        final c = VideoPlayerController.file(f);
        await c.initialize();
        await c.setLooping(true);
        await c.pause();
        if (!mounted) return;
        setState(() {
          _controller = c;
          _busy = false;
        });
        return;
      }
      final media = Get.find<ChatMediaRepository>();
      final bytes = await media.downloadUrl(
        url,
        onProgress: (a, b) {
          if (!mounted || b <= 0) return;
          setState(() => _dlProgress = (a / b).clamp(0.0, 1.0));
        },
      );
      await f.writeAsBytes(bytes, flush: true);
      chatVideoFileCache[h] = path;
      final c = VideoPlayerController.file(f);
      await c.initialize();
      await c.setLooping(true);
      await c.pause();
      if (!mounted) return;
      setState(() {
        _controller = c;
        _busy = false;
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = 'Could not load video';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _err = 'Could not load video';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final showProgress = widget.outgoing &&
        (it.status == 'uploading' ||
            it.status == 'pending' ||
            (it.status == null && it.url.isEmpty));
    final upProg = it.progress.clamp(0.0, 1.0);
    final h = widget.width * 9 / 16;

    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: widget.width,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_controller != null && _controller!.value.isInitialized)
                  FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _controller!.value.size.width,
                      height: _controller!.value.size.height,
                      child: VideoPlayer(_controller!),
                    ),
                  )
                else
                  ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
                if (_controller != null && _controller!.value.isInitialized)
                  Center(
                    child: IgnorePointer(
                      child: Icon(
                        Icons.play_circle_filled_rounded,
                        size: 56,
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                    ),
                  ),
                if (_busy || _controller == null || !_controller!.value.isInitialized)
                  Container(
                    alignment: Alignment.center,
                    color: Colors.black.withValues(alpha: 0.35),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            value: showProgress
                                ? (upProg <= 0 ? null : upProg)
                                : (_busy ? (_dlProgress <= 0 ? null : _dlProgress) : null),
                            color: Colors.white.withValues(alpha: 0.92),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            _hashShort(it.hash),
                            textAlign: TextAlign.center,
                            style: GoogleFonts.ptSans(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.85),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_err != null && !showProgress)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 0.5),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          _err!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.ptSans(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (it.status == 'failed' && widget.onRetry != null)
                  Positioned.fill(
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.45),
                      child: InkWell(
                        onTap: widget.onRetry,
                        child: Icon(
                          Icons.refresh_rounded,
                          color: Colors.white.withValues(alpha: 0.92),
                          size: 32,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
