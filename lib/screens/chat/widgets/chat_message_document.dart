import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pdfx/pdfx.dart';

import '../../../data/chat/chat_image_message.dart';

/// In-memory cache: document hash/url -> local file path.
final chatDocumentFileCache = <String, String>{};

class ChatMessageDocumentBubble extends StatefulWidget {
  const ChatMessageDocumentBubble({
    super.key,
    required this.payload,
    required this.outgoing,
    required this.timeLabel,
    required this.metaStyle,
    this.trailingMeta,
    this.onRetry,
    this.onTapOpen,
  });

  final ChatDocumentMessage payload;
  final bool outgoing;
  final String timeLabel;
  final TextStyle metaStyle;
  final Widget? trailingMeta;
  final VoidCallback? onRetry;
  final VoidCallback? onTapOpen;

  @override
  State<ChatMessageDocumentBubble> createState() =>
      _ChatMessageDocumentBubbleState();
}

class _ChatMessageDocumentBubbleState extends State<ChatMessageDocumentBubble> {
  ImageProvider? _pdfPreview;

  @override
  void initState() {
    super.initState();
    _preparePdfPreview();
  }

  @override
  void didUpdateWidget(covariant ChatMessageDocumentBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload.localPath != widget.payload.localPath ||
        oldWidget.payload.url != widget.payload.url ||
        oldWidget.payload.hash != widget.payload.hash) {
      _pdfPreview = null;
      _preparePdfPreview();
    }
  }

  Future<void> _preparePdfPreview() async {
    final p = widget.payload;
    if (!p.isPdf) return;
    final lp = p.localPath?.trim() ?? '';
    if (lp.isEmpty || !File(lp).existsSync()) return;
    try {
      final doc = await PdfDocument.openFile(lp);
      final page = await doc.getPage(1);
      final img = await page.render(
        width: 900,
        height: 550,
        format: PdfPageImageFormat.jpeg,
      );
      await page.close();
      await doc.close();
      if (!mounted || img == null) return;
      setState(() => _pdfPreview = MemoryImage(img.bytes));
    } catch (_) {}
  }

  String _sizeLabel(int bytes) {
    if (bytes <= 0) return '0 B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final pdfStyle = p.isPdf;
    final loading = p.status == 'uploading' || p.status == 'pending';
    final failed = p.status == 'failed';
    final ext = p.ext.toUpperCase();
    final leftPad = pdfStyle ? 14.0 : (widget.outgoing ? 11.0 : 13.0);
    final rightPad = pdfStyle ? 14.0 : (widget.outgoing ? 13.0 : 11.0);

    return SizedBox(
      width: pdfStyle ? 265 : 248,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTapOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (pdfStyle)
                    SizedBox(
                      height: 124,
                      child: _pdfPreview != null
                          ? Image(image: _pdfPreview!, fit: BoxFit.cover)
                          : DecoratedBox(
                              decoration: const BoxDecoration(
                                color: Color(0xFFF2F2F2),
                              ),
                              child: Center(
                                child: Icon(
                                  Icons.picture_as_pdf_rounded,
                                  color: Colors.red.shade400,
                                  size: 38,
                                ),
                              ),
                            ),
                    ),
                  if (pdfStyle) ...[
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        leftPad,
                        10,
                        rightPad,
                        8,
                      ),
                      child: Text(
                        p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.ptSans(
                          color: Colors.white.withValues(alpha: 0.95),
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.12,
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        leftPad,
                        0,
                        rightPad,
                        8,
                      ),
                      child: Text(
                        '${p.pages != null ? '${p.pages} pages • ' : ''}${_sizeLabel(p.sizeBytes)} • ${ext.isEmpty ? 'FILE' : ext}',
                        style: GoogleFonts.ptSans(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ] else
                    Padding(
                      padding: EdgeInsets.fromLTRB(leftPad, 9, rightPad, 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                ext.isEmpty ? 'DOC' : ext,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.ptSans(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.ptSans(
                                    color: Colors.white.withValues(alpha: 0.95),
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                    height: 1.05,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${_sizeLabel(p.sizeBytes)} • ${ext.isEmpty ? 'FILE' : ext}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.ptSans(
                                    color: Colors.white.withValues(alpha: 0.62),
                                    fontSize: 11.25,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (loading)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        leftPad,
                        0,
                        rightPad,
                        pdfStyle ? 8 : 4,
                      ),
                      child: LinearProgressIndicator(
                        minHeight: 2,
                        value: p.progress <= 0 ? null : p.progress,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF53C5FF),
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      leftPad,
                      0,
                      pdfStyle ? 10 : (widget.outgoing ? 11 : 9),
                      pdfStyle ? 8 : 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (failed && widget.onRetry != null)
                          InkWell(
                            onTap: widget.onRetry,
                            child: Text(
                              'Retry',
                              style: GoogleFonts.ptSans(
                                fontSize: 12,
                                color: const Color(0xFF7DD3FC),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        else ...[
                          if (widget.trailingMeta != null) widget.trailingMeta!,
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
