import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/chat/link_preview_service.dart';

/// Rich link preview (first URL only) for chat bubbles / composer — non-blocking; uses [LinkPreviewService] cache.
class ChatLinkPreviewCard extends StatefulWidget {
  const ChatLinkPreviewCard({
    super.key,
    required this.url,
    required this.isOutgoing,
    this.maxWidth,
  });

  final String url;
  final bool isOutgoing;

  /// When set (e.g. composer), caps preview width; otherwise uses screen-based clamp.
  final double? maxWidth;

  @override
  State<ChatLinkPreviewCard> createState() => _ChatLinkPreviewCardState();
}

class _ChatLinkPreviewCardState extends State<ChatLinkPreviewCard> {
  // Session-level memory cache to avoid loading flicker on route re-entry.
  static final Map<String, LinkPreviewData> _previewCache =
      <String, LinkPreviewData>{};

  late Future<LinkPreviewData> _future;

  String get _cacheKey => LinkPreviewService.cacheKeyForUrl(widget.url);

  @override
  void initState() {
    super.initState();
    final cached =
        _previewCache[_cacheKey] ?? LinkPreviewService.instance.peek(widget.url);
    if (cached != null) {
      _previewCache[_cacheKey] = cached;
    }
    _future = LinkPreviewService.instance.get(widget.url);
  }

  @override
  void didUpdateWidget(ChatLinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      final cached =
          _previewCache[_cacheKey] ?? LinkPreviewService.instance.peek(widget.url);
      if (cached != null) {
        _previewCache[_cacheKey] = cached;
      }
      _future = LinkPreviewService.instance.get(widget.url);
    }
  }

  Future<void> _openUrl(String url) async {
    final u = Uri.tryParse(url);
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final maxW = widget.maxWidth ??
        (MediaQuery.sizeOf(context).width - 72).clamp(200.0, 320.0);

    return FutureBuilder<LinkPreviewData>(
      future: _future,
      builder: (context, snap) {
        if (snap.data != null) {
          _previewCache[_cacheKey] = snap.data!;
        }
        final data =
            _previewCache[_cacheKey] ??
            LinkPreviewService.instance.peek(widget.url) ??
            snap.data;
        if (data == null &&
            snap.connectionState == ConnectionState.waiting) {
          return _PreviewSkeleton(maxWidth: maxW, isOutgoing: widget.isOutgoing);
        }
        if (data == null) {
          return const SizedBox.shrink();
        }
        return RepaintBoundary(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openUrl(data.url),
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.isOutgoing
                        ? Colors.black.withValues(alpha: 0.22)
                        : Colors.black.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.10),
                    ),
                  ),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PreviewThumb(imageUrl: data.imageUrl),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  data.title ?? data.domain,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.ptSans(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                    color: Colors.white.withValues(alpha: 0.96),
                                  ),
                                ),
                                if (data.description != null &&
                                    data.description!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    data.description!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.ptSans(
                                      fontSize: 12,
                                      height: 1.3,
                                      color: Colors.white.withValues(
                                        alpha: 0.55,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Text(
                                  data.domain,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.ptSans(
                                    fontSize: 11,
                                    height: 1.2,
                                    color: Colors.white.withValues(
                                      alpha: 0.42,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Many CDNs require a browser-like User-Agent for hotlinked OG images.
const _kPreviewImageHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
};

class _PreviewThumb extends StatelessWidget {
  const _PreviewThumb({required this.imageUrl});

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    const size = 88.0;
    final border = BorderRadius.only(
      topLeft: const Radius.circular(9),
      bottomLeft: const Radius.circular(9),
    );

    Widget placeholder() {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: border,
        ),
        child: Center(
          child: Icon(
            Icons.link_rounded,
            size: 30,
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
      );
    }

    if (imageUrl == null || imageUrl!.isEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: border,
          child: placeholder(),
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: border,
        child: Image.network(
          imageUrl!,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          headers: _kPreviewImageHeaders,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return ColoredBox(
              color: Colors.white.withValues(alpha: 0.06),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) => placeholder(),
        ),
      ),
    );
  }
}

class _PreviewSkeleton extends StatelessWidget {
  const _PreviewSkeleton({
    required this.maxWidth,
    required this.isOutgoing,
  });

  final double maxWidth;
  final bool isOutgoing;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isOutgoing
                ? Colors.black.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: SizedBox(
            height: 88,
            child: Row(
              children: [
                Container(
                  width: 88,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(9),
                      bottomLeft: Radius.circular(9),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 12,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 10,
                          width: 120,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const Spacer(),
                        Container(
                          height: 8,
                          width: 80,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
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
