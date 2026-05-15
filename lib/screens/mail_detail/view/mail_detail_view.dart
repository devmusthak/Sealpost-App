import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../data/auth/auth_repository.dart';
import '../../../data/mail/mail_address.dart';
import '../../../data/mail/mail_attachment.dart';
import '../../../data/mail/mail_detail.dart';
import '../../../data/mail/mail_list_item.dart';
import '../../../data/chat/chat_contact.dart';
import '../../../data/chat/chat_repository.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/delete_mail_confirmation_dialog.dart';
import '../../../widgets/linkable_selectable_text.dart';
import '../../chat/chat_open_thread.dart';
import '../../compose/view/compose_view.dart';
import '../controller/mail_detail_controller.dart';

class MailDetailScreen extends StatefulWidget {
  const MailDetailScreen({
    super.key,
    required this.mailId,
    required this.preview,
    required this.folderKey,
  });

  final String mailId;
  final MailListItem preview;
  final String folderKey;

  @override
  State<MailDetailScreen> createState() => _MailDetailScreenState();
}

class _MailDetailScreenState extends State<MailDetailScreen> {
  late final MailDetailController _controller;

  static const _overlay = Color(0xFF121212);

  static const _avatars = [
    Color(0xFF7C4DFF),
    Color(0xFF448AFF),
    Color(0xFF26A69A),
    Color(0xFFFFA726),
    Color(0xFFEC407A),
  ];

  @override
  void initState() {
    super.initState();
    _controller = Get.put(
      MailDetailController(
        mailId: widget.mailId,
        preview: widget.preview,
        folderLabel: widget.folderKey,
      ),
    );
  }

  @override
  void dispose() {
    if (Get.isRegistered<MailDetailController>()) {
      Get.delete<MailDetailController>();
    }
    super.dispose();
  }

  void _openReply(BuildContext context) {
    final d = _controller.detail.value;
    final p = widget.preview;
    final to = _replyRecipientEmails(d, p);
    if (to.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No reply address is available for this message.',
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
      return;
    }
    final plain = _plainBodyFromDetail(d, p);
    final subjRaw = (d?.subject ?? p.subject)?.trim();
    unawaited(
      Get.to<void>(
        () => ComposeScreen(
          prefill: ComposePrefill(
            toAddresses: to,
            subject: _withReplySubject(subjRaw),
            body: _replyQuotedBody(d, p, plain),
          ),
        ),
      ),
    );
  }

  void _openForward(BuildContext context) {
    final d = _controller.detail.value;
    final p = widget.preview;
    final plain = _plainBodyFromDetail(d, p);
    final subjRaw = (d?.subject ?? p.subject)?.trim();
    unawaited(
      Get.to<void>(
        () => ComposeScreen(
          prefill: ComposePrefill(
            subject: _withForwardSubject(subjRaw),
            body: _forwardQuotedBody(d, p, plain),
          ),
        ),
      ),
    );
  }

  Future<void> _onEmailTapFromMailBody(String email) async {
    final target = email.trim().toLowerCase();
    if (target.isEmpty) return;
    final auth = Get.find<AuthRepository>();
    final myEmail = auth.session?.email.trim().toLowerCase() ?? '';
    if (target == myEmail) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "It's your email",
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
      return;
    }

    try {
      final users = await Get.find<ChatRepository>().searchUsersByEmail(target);
      final match = users.firstWhereOrNull(
        (u) => u.email.trim().toLowerCase() == target,
      );
      if (!mounted) return;
      if (match == null) {
        await Get.to<void>(
          () => ComposeScreen(
            prefill: ComposePrefill(
              toAddresses: [email.trim()],
              subject: '',
              body: '',
            ),
          ),
        );
        return;
      }

      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: const Color(0xFF000000),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white),
                title: const Text('Open chat', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  final contact = ChatContact(
                    id: match.id,
                    name: match.name.isNotEmpty ? match.name : match.email,
                    email: match.email,
                    isOnline: match.isOnline,
                    lastSeenAt: null,
                    relationStatus: match.relationStatus,
                    lastMessage: '',
                    timeLabel: '',
                    unreadCount: 0,
                  );
                  openChatThread(context, contact);
                },
              ),
              ListTile(
                leading: const Icon(Icons.mail_outline_rounded, color: Colors.white),
                title: const Text('Compose email', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(
                    Get.to<void>(
                      () => ComposeScreen(
                        prefill: ComposePrefill(
                          toAddresses: [email.trim()],
                          subject: '',
                          body: '',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await Get.to<void>(
        () => ComposeScreen(
          prefill: ComposePrefill(
            toAddresses: [email.trim()],
            subject: '',
            body: '',
          ),
        ),
      );
    }
  }

  List<String> _replyRecipientEmails(MailDetail? d, MailListItem p) {
    final outbound = widget.folderKey == 'Sent' ||
        d?.messageType == 'sent' ||
        p.messageType == 'sent';
    if (outbound) {
      final emails = _uniqueEmailsFromAddresses(d?.to ?? []);
      if (emails.isNotEmpty) return emails;
    } else {
      final emails = _uniqueEmailsFromAddresses(d?.from ?? []);
      if (emails.isNotEmpty) return emails;
    }
    final fb = p.fromAddress?.trim();
    if (fb != null && fb.isNotEmpty) return [fb];
    return [];
  }

  List<String> _uniqueEmailsFromAddresses(List<MailAddress> addrs) {
    final out = <String>[];
    for (final a in addrs) {
      final e = a.address?.trim() ?? '';
      if (e.isNotEmpty && !out.contains(e)) out.add(e);
    }
    return out;
  }

  String _withReplySubject(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return 'Re: (No subject)';
    final lower = t.toLowerCase();
    if (lower.startsWith('re:')) return t;
    return 'Re: $t';
  }

  String _withForwardSubject(String? raw) {
    final t = (raw ?? '').trim();
    if (t.isEmpty) return 'Fwd: (No subject)';
    final lower = t.toLowerCase();
    if (lower.startsWith('fwd:') || lower.startsWith('fw:')) return t;
    return 'Fwd: $t';
  }

  String _composeHeaderFromLine(MailDetail? d, MailListItem p) {
    if (d != null && d.from.isNotEmpty) {
      return d.from.map((a) => a.displayLine).join(', ');
    }
    final n = p.fromName.trim();
    final a = p.fromAddress?.trim() ?? '';
    if (n.isNotEmpty && a.isNotEmpty) return '$n <$a>';
    if (a.isNotEmpty) return a;
    return n.isNotEmpty ? n : 'Unknown';
  }

  String _composeHeaderToLine(MailDetail? d) {
    if (d != null && d.to.isNotEmpty) {
      return d.to.map((a) => a.displayLine).join(', ');
    }
    return '';
  }

  String _formatMailDateForQuote(String? iso) {
    if (iso == null || iso.isEmpty) return 'unknown date';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    final local = dt.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd $hh:$min';
  }

  String _replyQuotedBody(MailDetail? d, MailListItem p, String plainBody) {
    final fromLine = _composeHeaderFromLine(d, p);
    final dateStr = _formatMailDateForQuote(d?.date ?? p.date);
    final body =
        plainBody.trim().isEmpty ? '(No message text)' : plainBody.trim();
    return '\n\n---------- Reply message ----------\n'
        'On $dateStr, $fromLine wrote:\n\n'
        '$body';
  }

  String _forwardQuotedBody(MailDetail? d, MailListItem p, String plainBody) {
    final fromLine = _composeHeaderFromLine(d, p);
    final toLine = _composeHeaderToLine(d);
    final rawSubj = (d?.subject ?? p.subject)?.trim();
    final subj = (rawSubj == null || rawSubj.isEmpty) ? '(No subject)' : rawSubj;
    final dateStr = _formatMailDateForQuote(d?.date ?? p.date);
    final body =
        plainBody.trim().isEmpty ? '(No message text)' : plainBody.trim();
    final toPart =
        toLine.isNotEmpty ? 'To: $toLine\n' : '';
    return '\n\n---------- Forwarded message ----------\n'
        'From: $fromLine\n'
        'Date: $dateStr\n'
        'Subject: $subj\n'
        '$toPart'
        '\n'
        '$body';
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final appBarBottom = topInset + kToolbarHeight;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _overlay,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: kToolbarHeight,
          iconTheme: IconThemeData(
            color: Colors.white.withValues(alpha: 0.92),
            size: 24,
          ),
          actionsIconTheme: IconThemeData(
            color: Colors.white.withValues(alpha: 0.92),
            size: 22,
          ),
          leading: IconButton(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.chevron_left_rounded, size: 28),
            onPressed: () => Get.back<void>(),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.reply_rounded),
              onPressed: () => _openReply(context),
            ),
            IconButton(
              icon: const Icon(Icons.forward_rounded),
              onPressed: () => _openForward(context),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/chat.jpeg',
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
            ColoredBox(
              color: _overlay.withValues(alpha: 0.88),
            ),
            Padding(
              padding: EdgeInsets.only(top: appBarBottom),
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Obx(() {
                      final err = _controller.errorMessage.value;
                      final loading = _controller.isLoading.value;
                      if (err != null &&
                          err.isNotEmpty &&
                          _controller.detail.value == null &&
                          !loading) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  err,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                const SizedBox(height: 16),
                                TextButton(
                                  onPressed: _controller.retry,
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      final d = _controller.detail.value;
                      final p = widget.preview;
                      final rawSubject = (d?.subject ?? p.subject)?.trim();
                      final subject = (rawSubject != null && rawSubject.isNotEmpty)
                          ? rawSubject
                          : '(No subject)';
                      final index = p.id.hashCode.abs();
                      final fromName = (d?.from.isNotEmpty == true)
                          ? d?.from.first.displayName ?? ''
                          : p.fromName;
                      final letter = _firstInitial(
                        fromName.trim().isNotEmpty ? fromName : '?',
                      );
                      final avatarColor = _avatars[index % _avatars.length];
                      final dateIso = d?.date ?? p.date;
                      final body = _plainBodyFromDetail(d, p);
                      final folderChip = _folderChipLabel(
                        d?.folder ?? widget.folderKey,
                      );

                      return SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    subject,
                                    style: GoogleFonts.ptSans(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    child: Text(
                                      folderChip.toUpperCase(),
                                      style: GoogleFonts.ptSans(
                                        color: Colors.white.withValues(
                                          alpha: 0.75,
                                        ),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 22,
                                  backgroundColor: avatarColor,
                                  child: Text(
                                    letter,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.baseline,
                                        textBaseline: TextBaseline.alphabetic,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              fromName,
                                              style: GoogleFonts.ptSans(
                                                color: Colors.white,
                                                fontSize: 16,
                                                fontWeight: FontWeight.w700,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          Text(
                                            _relativeTimeLabel(dateIso),
                                            style: GoogleFonts.ptSans(
                                              color: Colors.white54,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                      _RecipientsExpansion(
                                        detail: d,
                                        messageDateIso: dateIso,
                                        userEmail: Get.find<AuthRepository>()
                                            .session
                                            ?.email,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(
                                2,
                                2,
                                2,
                                24,
                              ),
                              child: loading && d == null
                                  ? Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 40,
                                      ),
                                      child: Center(
                                        child: SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: kPrimaryBlue.withValues(
                                              alpha: 0.9,
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : body.isEmpty
                                      ? SelectableText(
                                          'No message body',
                                          style: GoogleFonts.ptSans(
                                            color: Colors.white.withValues(
                                              alpha: 0.82,
                                            ),
                                            fontSize: 15,
                                            height: 1.5,
                                          ),
                                        )
                                      : LinkableSelectableText(
                                          text: body,
                                          style: GoogleFonts.ptSans(
                                            color: Colors.white.withValues(
                                              alpha: 0.82,
                                            ),
                                            fontSize: 15,
                                            height: 1.5,
                                          ),
                                          onEmailTap: _onEmailTapFromMailBody,
                                        ),
                            ),
                            if (d != null && d.attachments.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                              const SizedBox(height: 16),
                              _MailAttachmentsSection(
                                attachments: d.attachments,
                              ),
                            ],
                          ],
                        ),
                      );
                    }),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final subject =
        _controller.detail.value?.subject ?? widget.preview.subject ?? '';
    final deleted = await showDeleteMailConfirmationDialog(
      context,
      subjectLine: subject,
      onConfirmDelete: _controller.deleteMail,
    );
    if (!context.mounted) return;
    if (deleted) {
      Get.back(result: true);
    }
  }
}

class _MailAttachmentsSection extends StatelessWidget {
  const _MailAttachmentsSection({required this.attachments});

  final List<MailAttachment> attachments;

  int get _count => attachments.length;

  @override
  Widget build(BuildContext context) {
    final countLabel =
        _count == 1 ? '1 attachment' : '$_count attachments';
    final metaStyle = GoogleFonts.ptSans(
      color: Colors.white.withValues(alpha: 0.72),
      fontSize: 13,
      height: 1.25,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(countLabel, style: metaStyle),
                  Text(
                    '•',
                    style: metaStyle.copyWith(
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Scanned by LivConnect',
                        style: metaStyle,
                      ),
                      Tooltip(
                        message:
                            'LivConnect reviews attachments to help keep your inbox safer.',
                        triggerMode: TooltipTriggerMode.tap,
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 16,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        GridView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.92,
          ),
          itemCount: attachments.length,
          itemBuilder: (context, index) {
            return _AttachmentPreviewCard(
              attachment: attachments[index],
            );
          },
        ),
      ],
    );
  }
}

class _AttachmentPreviewCard extends StatelessWidget {
  const _AttachmentPreviewCard({required this.attachment});

  final MailAttachment attachment;

  static const _cardHeight = 128.0;

  bool get _isSvg {
    final ct = attachment.contentType?.toLowerCase() ?? '';
    if (ct.contains('svg')) return true;
    return attachment.filename?.toLowerCase().endsWith('.svg') ?? false;
  }

  /// Raster images only (SVG uses [_isSvg] + [SvgPicture]).
  bool get _isRasterImage {
    final ct = attachment.contentType?.toLowerCase() ?? '';
    if (ct.startsWith('image/') && !ct.contains('svg')) return true;
    final n = attachment.filename?.toLowerCase() ?? '';
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.heic');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: attachment.hasInlineData
            ? () {
                unawaited(_handleAttachmentTap(context, attachment));
              }
            : null,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: double.infinity,
          height: _cardHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.white.withValues(alpha: 0.08),
                        child: _previewFill(),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: CustomPaint(
                          size: const Size(24, 24),
                          painter: _DogEarCornerPainter(),
                        ),
                      ),
                      if (attachment.hasInlineData)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () {
                                      unawaited(_shareInlineAttachmentFromCard(
                                        context,
                                        attachment,
                                      ));
                                    },
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(6),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.ios_share_rounded,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                                Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () {
                                      unawaited(
                                        _downloadInlineAttachmentFromCard(
                                          context,
                                          attachment,
                                        ),
                                      );
                                    },
                                    borderRadius: const BorderRadius.horizontal(
                                      right: Radius.circular(6),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.download_rounded,
                                        color: Colors.white,
                                        size: 18,
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
                ),
              ),
              const SizedBox(height: 4),
              Text(
                attachment.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.ptSans(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewFill() {
    if (!attachment.hasInlineData) {
      return _genericFilePreview();
    }
    if (_classifyAttachment(attachment) == _AttachmentPreviewKind.pdf) {
      return Center(
        child: Icon(
          Icons.picture_as_pdf_rounded,
          size: 48,
          color: Colors.red.shade300,
        ),
      );
    }
    try {
      final bytes = base64Decode(attachment.dataBase64!);
      if (_isSvg) {
        final markup = utf8.decode(bytes, allowMalformed: true).trim();
        if (markup.isEmpty) return _genericFilePreview();
        return SvgPicture.string(
          markup,
          fit: BoxFit.cover,
          allowDrawingOutsideViewBox: true,
          errorBuilder: (_, _, _) => _genericFilePreview(),
        );
      }
      if (_isRasterImage) {
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _genericFilePreview(),
        );
      }
    } catch (_) {
      return _genericFilePreview();
    }
    return _genericFilePreview();
  }

  Widget _genericFilePreview() {
    return Center(
      child: Icon(
        Icons.description_rounded,
        size: 44,
        color: Colors.white.withValues(alpha: 0.45),
      ),
    );
  }
}

/// Small page-fold at bottom-right (Gmail-style attachment thumb).
class _DogEarCornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const fold = 20.0;
    final w = size.width;
    final h = size.height;
    final shadow = Path()
      ..moveTo(w, h)
      ..lineTo(w - fold - 0.5, h)
      ..lineTo(w, h - fold - 0.5)
      ..close();
    canvas.drawPath(
      shadow,
      Paint()..color = Colors.black.withValues(alpha: 0.22),
    );
    final paper = Path()
      ..moveTo(w, h)
      ..lineTo(w - fold, h)
      ..lineTo(w, h - fold)
      ..close();
    canvas.drawPath(
      paper,
      Paint()..color = const Color(0xFFE8EAED),
    );
    canvas.drawLine(
      Offset(w - fold, h),
      Offset(w, h - fold),
      Paint()
        ..color = const Color(0xFFB0B4B9)
        ..strokeWidth = 0.9,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

String _fileExtensionForAttachment(MailAttachment a) {
  final fn = a.filename;
  if (fn != null && fn.contains('.')) {
    return fn.substring(fn.lastIndexOf('.'));
  }
  final ct = (a.contentType ?? '').toLowerCase();
  if (ct.contains('pdf')) return '.pdf';
  if (ct.contains('png')) return '.png';
  if (ct.contains('jpeg') || ct.contains('jpg')) return '.jpg';
  if (ct.contains('gif')) return '.gif';
  if (ct.contains('webp')) return '.webp';
  if (ct.contains('text/plain')) return '.txt';
  if (ct.contains('svg')) return '.svg';
  return '.bin';
}

String _safeAttachmentFileName(MailAttachment a) {
  final ext = _fileExtensionForAttachment(a);
  var base = (a.filename ?? 'attachment').trim();
  if (base.isEmpty) base = 'attachment';
  base = base.replaceAll(RegExp(r'[^\w\-\.\s]+'), '_').trim();
  if (base.isEmpty) base = 'attachment';
  if (!base.toLowerCase().endsWith(ext.toLowerCase())) {
    base = base.endsWith('.') ? '$base${ext.replaceFirst('.', '')}' : '$base$ext';
  }
  return base;
}

enum _AttachmentPreviewKind { image, video, pdf, other }

/// PDF files start with ASCII `%PDF` (some servers send wrong MIME types).
bool _bytesLookLikePdf(Uint8List bytes) {
  var i = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    i = 3;
  }
  if (bytes.length - i < 4) return false;
  return bytes[i] == 0x25 &&
      bytes[i + 1] == 0x50 &&
      bytes[i + 2] == 0x44 &&
      bytes[i + 3] == 0x46;
}

_AttachmentPreviewKind _classifyAttachment(MailAttachment a) {
  final ct = (a.contentType ?? '').toLowerCase().trim();
  final name = (a.filename ?? '').toLowerCase().trim();

  if (name.endsWith('.pdf') ||
      ct == 'application/pdf' ||
      ct.contains('pdf')) {
    return _AttachmentPreviewKind.pdf;
  }

  if (ct.startsWith('video/')) {
    return _AttachmentPreviewKind.video;
  }
  const videoExt = [
    '.mp4',
    '.m4v',
    '.mov',
    '.webm',
    '.avi',
    '.mkv',
    '.3gp',
    '.mpeg',
    '.mpg',
  ];
  for (final e in videoExt) {
    if (name.endsWith(e)) {
      return _AttachmentPreviewKind.video;
    }
  }

  if (ct.startsWith('image/')) {
    return _AttachmentPreviewKind.image;
  }
  const imageExt = [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
    '.svg',
  ];
  for (final e in imageExt) {
    if (name.endsWith(e)) {
      return _AttachmentPreviewKind.image;
    }
  }

  return _AttachmentPreviewKind.other;
}

bool _isSvgAttachment(MailAttachment a) {
  final ct = (a.contentType ?? '').toLowerCase();
  if (ct.contains('svg')) return true;
  return (a.filename ?? '').toLowerCase().endsWith('.svg');
}

/// Loads PDF via temp file — more reliable than [PdfDocument.openData] on some Android devices.
Future<PdfDocument> _openPdfDocumentFromBytes(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/sealpost_preview_${DateTime.now().microsecondsSinceEpoch}.pdf',
  );
  await file.writeAsBytes(bytes, flush: true);
  return PdfDocument.openFile(file.path);
}

Future<File> _materializeTempFile(
  MailAttachment attachment,
  Uint8List bytes,
) async {
  final dir = await getTemporaryDirectory();
  final name = _safeAttachmentFileName(attachment);
  final file = File(
    '${dir.path}/sp_${DateTime
        .now()
        .microsecondsSinceEpoch}_$name',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> _downloadAttachmentWithPathSnackbar(
  BuildContext context,
  MailAttachment attachment,
  Uint8List bytes,
) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/LivConnect');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final name = _safeAttachmentFileName(attachment);
    final file = File(
      '${folder.path}/${DateTime.now().millisecondsSinceEpoch}_$name',
    );
    await file.writeAsBytes(bytes, flush: true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved to:\n${file.path}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save file: $e')),
      );
    }
  }
}

Future<void> _handleAttachmentTap(
  BuildContext context,
  MailAttachment attachment,
) async {
  if (!attachment.hasInlineData) return;
  late final Uint8List bytes;
  try {
    bytes = base64Decode(attachment.dataBase64!);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read attachment')),
      );
    }
    return;
  }

  var kind = _classifyAttachment(attachment);
  if (_bytesLookLikePdf(bytes)) {
    kind = _AttachmentPreviewKind.pdf;
  }

  switch (kind) {
    case _AttachmentPreviewKind.image:
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (ctx) => _ImagePreviewScreen(
            bytes: bytes,
            title: attachment.displayName,
            attachment: attachment,
            isSvg: _isSvgAttachment(attachment),
          ),
        ),
      );
    case _AttachmentPreviewKind.video:
      final file = await _materializeTempFile(attachment, bytes);
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (ctx) => _VideoPreviewScreen(
            path: file.path,
            title: attachment.displayName,
            attachment: attachment,
          ),
        ),
      );
    case _AttachmentPreviewKind.pdf:
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (ctx) => _PdfPreviewScreen(
            bytes: bytes,
            title: attachment.displayName,
            attachment: attachment,
          ),
        ),
      );
    case _AttachmentPreviewKind.other:
      await _downloadAttachmentWithPathSnackbar(context, attachment, bytes);
  }
}

Future<void> _shareInlineAttachmentFromCard(
  BuildContext context,
  MailAttachment attachment,
) async {
  if (!attachment.hasInlineData) return;
  try {
    final bytes = base64Decode(attachment.dataBase64!);
    if (!context.mounted) return;
    await _shareAttachmentFromBytes(context, attachment, bytes);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read attachment')),
      );
    }
  }
}

Future<void> _downloadInlineAttachmentFromCard(
  BuildContext context,
  MailAttachment attachment,
) async {
  if (!attachment.hasInlineData) return;
  try {
    final bytes = base64Decode(attachment.dataBase64!);
    if (!context.mounted) return;
    await _downloadAttachmentWithPathSnackbar(context, attachment, bytes);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read attachment')),
      );
    }
  }
}

Future<void> _shareFileAtPath(BuildContext context, String filePath) async {
  try {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(filePath)]),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share: $e')),
      );
    }
  }
}

Future<void> _shareAttachmentFromBytes(
  BuildContext context,
  MailAttachment attachment,
  Uint8List bytes,
) async {
  try {
    final dir = await getTemporaryDirectory();
    final name = _safeAttachmentFileName(attachment);
    final file = File(
      '${dir.path}/sp_share_${DateTime.now().microsecondsSinceEpoch}_$name',
    );
    await file.writeAsBytes(bytes, flush: true);
    if (!context.mounted) return;
    await _shareFileAtPath(context, file.path);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share: $e')),
      );
    }
  }
}

Future<void> _downloadFromSourcePath(
  BuildContext context,
  MailAttachment attachment,
  String sourcePath,
) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory('${docs.path}/LivConnect');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final name = _safeAttachmentFileName(attachment);
    final dest = File(
      '${folder.path}/${DateTime.now().millisecondsSinceEpoch}_$name',
    );
    await File(sourcePath).copy(dest.path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved to:\n${dest.path}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }
}

class _ImagePreviewScreen extends StatelessWidget {
  const _ImagePreviewScreen({
    required this.bytes,
    required this.title,
    required this.attachment,
    this.isSvg = false,
  });

  final Uint8List bytes;
  final String title;
  final MailAttachment attachment;
  final bool isSvg;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          title,
          style: GoogleFonts.ptSans(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () {
              unawaited(
                _shareAttachmentFromBytes(context, attachment, bytes),
              );
            },
          ),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded),
            onPressed: () {
              unawaited(
                _downloadAttachmentWithPathSnackbar(
                  context,
                  attachment,
                  bytes,
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: isSvg ? _buildSvg(context) : _buildRaster(),
        ),
      ),
    );
  }

  Widget _buildSvg(BuildContext context) {
    final markup = utf8.decode(bytes, allowMalformed: true).trim();
    if (markup.isEmpty) {
      return _svgError('Empty SVG');
    }
    final size = MediaQuery.sizeOf(context);
    final h = (size.height * 0.78).clamp(200.0, 900.0);
    return SizedBox(
      width: size.width,
      height: h,
      child: SvgPicture.string(
        markup,
        width: size.width,
        height: h,
        fit: BoxFit.contain,
        allowDrawingOutsideViewBox: true,
        errorBuilder: (ctx, error, stackTrace) =>
            _svgError('$error'),
      ),
    );
  }

  Widget _svgError(String message) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        'Could not display SVG\n$message',
        textAlign: TextAlign.center,
        style: GoogleFonts.ptSans(color: Colors.white70, fontSize: 14),
      ),
    );
  }

  Widget _buildRaster() {
    return Image.memory(
      bytes,
      errorBuilder: (_, _, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Could not display image',
          style: GoogleFonts.ptSans(color: Colors.white70),
        ),
      ),
    );
  }
}

class _VideoPreviewScreen extends StatefulWidget {
  const _VideoPreviewScreen({
    required this.path,
    required this.title,
    required this.attachment,
  });

  final String path;
  final String title;
  final MailAttachment attachment;

  @override
  State<_VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<_VideoPreviewScreen> {
  late final VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_controller.value.isInitialized) return;
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title,
          style: GoogleFonts.ptSans(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () {
              unawaited(_shareFileAtPath(context, widget.path));
            },
          ),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded),
            onPressed: () {
              unawaited(
                _downloadFromSourcePath(
                  context,
                  widget.attachment,
                  widget.path,
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: _controller.value.isInitialized
            ? GestureDetector(
                onTap: _togglePlay,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _controller.value.aspectRatio == 0
                          ? 16 / 9
                          : _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                    if (!_controller.value.isPlaying)
                      Icon(
                        Icons.play_circle_filled_rounded,
                        size: 64,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                  ],
                ),
              )
            : const CircularProgressIndicator(color: Colors.white54),
      ),
    );
  }
}

class _PdfPreviewScreen extends StatefulWidget {
  const _PdfPreviewScreen({
    required this.bytes,
    required this.title,
    required this.attachment,
  });

  final Uint8List bytes;
  final String title;
  final MailAttachment attachment;

  @override
  State<_PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

class _PdfPreviewScreenState extends State<_PdfPreviewScreen> {
  late final PdfControllerPinch _pdfController;

  @override
  void initState() {
    super.initState();
    _pdfController = PdfControllerPinch(
      document: _openPdfDocumentFromBytes(widget.bytes),
    );
  }

  @override
  void dispose() {
    _pdfController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title,
          style: GoogleFonts.ptSans(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () {
              unawaited(
                _shareAttachmentFromBytes(
                  context,
                  widget.attachment,
                  widget.bytes,
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_rounded),
            onPressed: () {
              unawaited(
                _downloadAttachmentWithPathSnackbar(
                  context,
                  widget.attachment,
                  widget.bytes,
                ),
              );
            },
          ),
        ],
      ),
      body: PdfViewPinch(
        controller: _pdfController,
        onDocumentError: (err) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not load PDF: $err')),
            );
            Navigator.of(context).pop();
          }
        },
        backgroundDecoration: const BoxDecoration(color: Color(0xFF1E1E1E)),
      ),
    );
  }
}

class _RecipientsExpansion extends StatelessWidget {
  const _RecipientsExpansion({
    this.detail,
    required this.messageDateIso,
    this.userEmail,
  });

  final MailDetail? detail;
  final String? messageDateIso;
  final String? userEmail;

  @override
  Widget build(BuildContext context) {
    final to = detail?.to ?? [];
    final cc = detail?.cc ?? [];
    final me = userEmail?.toLowerCase().trim() ?? '';
    final showMeChip = me.isNotEmpty &&
        to.any(
          (a) => (a.address ?? '').toLowerCase() == me,
        );

    final title = Text(
      showMeChip || (to.isEmpty && cc.isEmpty) ? 'to me' : 'Recipients',
      style: GoogleFonts.ptSans(
        color: Colors.white70,
        fontSize: 13,
        height: 1.15,
      ),
    );

    final dateLine = _fullDateTimeLabel(
      detail?.date ?? messageDateIso,
    );

    final from = detail?.from ?? [];
    final bcc = detail?.bcc ?? [];

    final children = <Widget>[
      _textRow('Date', dateLine.isEmpty ? '—' : dateLine),
      from.isEmpty
          ? _textRow('From', '—')
          : _addrBlock('From', from),
      to.isEmpty ? _textRow('To', '—') : _addrBlock('To', to),
      if (cc.isNotEmpty) _addrBlock('Cc', cc),
      if (bcc.isNotEmpty) _addrBlock('Bcc', bcc),
    ];

    return Theme(
      data: Theme.of(context).copyWith(
        visualDensity: VisualDensity.compact,
        dividerColor: Colors.transparent,
        splashColor: Colors.white10,
        highlightColor: Colors.white10,
        listTileTheme: const ListTileThemeData(
          dense: true,
          minVerticalPadding: 0,
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
        expansionTileTheme: const ExpansionTileThemeData(
          tilePadding: EdgeInsets.zero,
          expandedAlignment: Alignment.centerLeft,
        ),
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        collapsedIconColor: Colors.white70,
        iconColor: Colors.white70,
        title: title,
        childrenPadding: const EdgeInsets.only(bottom: 6, right: 4),
        children: children,
      ),
    );
  }

  static Widget _textRow(String label, String value) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.ptSans(
                color: const Color(0xFF9AA8C4),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: GoogleFonts.ptSans(
                color: const Color(0xFFE8EAED),
                fontSize: 13,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _addrBlock(String label, List<MailAddress> rows) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.ptSans(
                color: const Color(0xFF9AA8C4),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            ...rows.map(
              (a) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  a.displayLine,
                  style: GoogleFonts.ptSans(
                    color: const Color(0xFFE8EAED),
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _folderChipLabel(String folder) {
  switch (folder.toUpperCase()) {
    case 'INBOX':
      return 'Inbox';
    case 'SENT':
    case 'SENT ITEMS':
      return 'Sent';
    case 'SPAM':
    case 'JUNK':
      return 'Spam';
    case 'TRASH':
    case 'DELETED':
      return 'Trash';
    default:
      if (folder.isEmpty) return 'Inbox';
      return folder[0].toUpperCase() + folder.substring(1).toLowerCase();
  }
}

String _firstInitial(String s) {
  final t = s.trim();
  if (t.isEmpty) return '?';
  return t[0].toUpperCase();
}

const _monthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Full local date + 12h time for the recipients tile (e.g. `Apr 10, 2026 · 9:41 AM`).
String _fullDateTimeLabel(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final local = d.toLocal();
  var h = local.hour;
  final m = local.minute;
  final am = h >= 12 ? 'PM' : 'AM';
  h = h % 12;
  if (h == 0) h = 12;
  final mm = m.toString().padLeft(2, '0');
  return '${_monthNames[local.month - 1]} ${local.day}, ${local.year} · $h:$mm $am';
}

String _relativeTimeLabel(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.isNegative) return 'Just now';
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (diff.inDays < 30) {
    final w = (diff.inDays / 7).floor();
    return '${w}w ago';
  }
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
  return '${(diff.inDays / 365).floor()}y ago';
}

String _plainBodyFromDetail(MailDetail? d, MailListItem preview) {
  if (d != null) {
    final t = d.text?.trim();
    if (t != null && t.isNotEmpty) return t;
    final h = d.html?.trim();
    if (h != null && h.isNotEmpty) return _stripHtml(h);
    final s = d.snippet?.trim();
    if (s != null && s.isNotEmpty) return s;
  }
  return preview.snippet.trim();
}

String _stripHtml(String html) {
  return html
      .replaceAll(
        RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('&nbsp;', ' ')
      .trim();
}
