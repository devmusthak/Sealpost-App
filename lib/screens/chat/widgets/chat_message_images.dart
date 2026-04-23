import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/chat/chat_image_message.dart';
import '../../../data/chat/chat_media_repository.dart';

/// In-memory path cache: content hash → local file path.
final chatImageFileCache = <String, String>{};

String _hashShort(String hash) {
  final h = hash.trim();
  if (h.length <= 14) return h;
  return '${h.substring(0, 8)}…${h.substring(h.length - 4)}';
}

class ChatMessageImagesBubble extends StatelessWidget {
  const ChatMessageImagesBubble({
    super.key,
    required this.payload,
    required this.outgoing,
    required this.bubbleColor,
    required this.metaColor,
    required this.timeLabel,
    required this.metaStyle,
    this.prefix,
    this.captionBelowImages = true,
    this.onTapImage,
    this.onRetrySlot,
    this.trailingMeta,
  });

  final ChatImageMessage payload;
  final bool outgoing;
  final Color bubbleColor;
  final Color metaColor;
  final String timeLabel;
  final TextStyle metaStyle;
  final Widget? prefix;
  final bool captionBelowImages;
  final void Function(int index, ChatImageItem item)? onTapImage;
  final void Function(int index)? onRetrySlot;
  final Widget? trailingMeta;

  /// Max width for the image area. Incoming uses a slightly smaller cap so the bubble
  /// does not extend as far toward the right edge.
  static double _gridWidthFor(BuildContext context, {required bool outgoing}) {
    final screenW = MediaQuery.sizeOf(context).width;
    if (outgoing) {
      return (screenW - 68).clamp(240.0, 340.0);
    }
    return (screenW - 96).clamp(210.0, 300.0);
  }

  static const _gap = 8.0;

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
                    child: _ImageGrid(
                      gridWidth: usableW,
                      items: payload.items,
                      outgoing: outgoing,
                      onTap: onTapImage,
                      onRetry: onRetrySlot,
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
          if (captionBelowImages && cap.isNotEmpty) ...[
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

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({
    required this.gridWidth,
    required this.items,
    required this.outgoing,
    this.onTap,
    this.onRetry,
  });

  /// Inner width after padding (tiles fill this).
  final double gridWidth;
  final List<ChatImageItem> items;
  final bool outgoing;
  final void Function(int index, ChatImageItem item)? onTap;
  final void Function(int index)? onRetry;

  @override
  Widget build(BuildContext context) {
    final n = items.length;
    final w = gridWidth;
    final g = ChatMessageImagesBubble._gap;
    if (n == 1) {
      return _slot(0, w, w);
    }
    final half = (w - g) / 2;
    if (n == 2) {
      return Row(
        children: [
          Expanded(child: _slot(0, 999, half)),
          SizedBox(width: g),
          Expanded(child: _slot(1, 999, half)),
        ],
      );
    }
    if (n == 3) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: _slot(0, 999, half)),
              SizedBox(width: g),
              Expanded(child: _slot(1, 999, half)),
            ],
          ),
          SizedBox(height: g),
          _slot(2, w, half),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: _slot(0, 999, half)),
            SizedBox(width: g),
            Expanded(child: _slot(1, 999, half)),
          ],
        ),
        SizedBox(height: g),
        Row(
          children: [
            Expanded(child: _slot(2, 999, half)),
            SizedBox(width: g),
            Expanded(child: _slot(3, 999, half)),
          ],
        ),
      ],
    );
  }

  Widget _slot(int i, double w, double h) {
    return _ChatImageSlot(
      index: i,
      item: items[i],
      outgoing: outgoing,
      width: w,
      height: h,
      onTap: onTap != null ? () => onTap!(i, items[i]) : null,
      onRetry: onRetry != null && items[i].status == 'failed'
          ? () => onRetry!(i)
          : null,
    );
  }
}

class _ChatImageSlot extends StatefulWidget {
  const _ChatImageSlot({
    required this.index,
    required this.item,
    required this.outgoing,
    required this.width,
    required this.height,
    this.onTap,
    this.onRetry,
  });

  final int index;
  final ChatImageItem item;
  final bool outgoing;
  final double width;
  final double height;
  final VoidCallback? onTap;
  final VoidCallback? onRetry;

  @override
  State<_ChatImageSlot> createState() => _ChatImageSlotState();
}

class _ChatImageSlotState extends State<_ChatImageSlot> {
  String? _cachedPath;
  double _dlProgress = 0;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _ChatImageSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.url != widget.item.url ||
        oldWidget.item.hash != widget.item.hash ||
        oldWidget.item.localPath != widget.item.localPath) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final it = widget.item;
    final lp = it.localPath?.trim() ?? '';
    if (lp.isNotEmpty && File(lp).existsSync()) {
      setState(() {
        _cachedPath = lp;
        _loading = false;
      });
      return;
    }
    final url = it.url.trim();
    final h = it.hash.trim().toLowerCase();
    if (h.isNotEmpty && chatImageFileCache.containsKey(h)) {
      final p = chatImageFileCache[h]!;
      if (File(p).existsSync()) {
        setState(() {
          _cachedPath = p;
          _loading = false;
        });
        return;
      }
    }
    if (url.isEmpty || !url.startsWith('http')) {
      setState(() {
        _cachedPath = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _dlProgress = 0;
    });
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/chat_img_$h.jpg';
      final f = File(path);
      if (await f.exists() && await f.length() > 0) {
        chatImageFileCache[h] = path;
        if (!mounted) return;
        setState(() {
          _cachedPath = path;
          _loading = false;
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
      chatImageFileCache[h] = path;
      if (!mounted) return;
      setState(() {
        _cachedPath = path;
        _loading = false;
      });
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final showProgress = widget.outgoing &&
        (it.status == 'uploading' || it.status == 'pending' || (it.status == null && it.url.isEmpty));
    final upProg = it.progress.clamp(0.0, 1.0);

    return Material(
      color: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: widget.width == 999 ? double.infinity : widget.width,
            height: widget.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_cachedPath != null)
                  Image.file(
                    File(_cachedPath!),
                    fit: BoxFit.cover,
                  )
                else
                  ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
                if (_cachedPath == null || _loading)
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
                                : (_loading ? (_dlProgress <= 0 ? null : _dlProgress) : null),
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
