import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/mailto/mailto_link_service.dart';
import '../../../data/auth/auth_repository.dart';
import 'package:sealpost/data/mail/compose_prefill.dart';
import '../../../data/mail/mail_repository.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/discard_compose_confirmation_dialog.dart';

export 'package:sealpost/data/mail/compose_prefill.dart';

/// Dark compose screen — From, To, Cc, Subject, body.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({
    super.key,
    this.prefill,
    this.mailtoSourceUri,
  });

  final ComposePrefill? prefill;

  /// Original `mailto:` URI when opened from a deep link or in-app mailto tap.
  /// When set, leaving this screen marks it consumed so the same link cannot reopen compose.
  final Uri? mailtoSourceUri;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  static const _canvas = Colors.black;
  static const _labelColor = Color(0xFF9AA0A6);
  static const _dividerColor = Color(0xFF3C4043);

  late final String _fromEmail;
  late final String _fromName;

  /// To addresses shown as chips only when [length >= 2]. One address stays in [_toInputController] only.
  final List<String> _toRecipients = [];
  final List<String> _ccRecipients = [];

  final _toInputController = TextEditingController();
  final _ccInputController = TextEditingController();
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();

  final List<MailOutgoingAttachment> _attachments = [];
  bool _sending = false;

  final _toFocus = FocusNode();
  final _ccFocus = FocusNode();
  final _subjectFocus = FocusNode();
  final _bodyFocus = FocusNode();

  TextStyle get _labelStyle => GoogleFonts.ptSans(
        color: _labelColor,
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w400,
      );

  TextStyle get _inputStyle => GoogleFonts.ptSans(
        color: Colors.white,
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w400,
      );

  InputDecoration _lineDecoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.ptSans(
        color: _labelColor,
        fontSize: 15,
        height: 1.35,
      ),
      isDense: true,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      contentPadding: EdgeInsets.zero,
      filled: false,
    );
  }

  @override
  void initState() {
    super.initState();
    final session = Get.find<AuthRepository>().session;
    _fromEmail = session?.email ?? '';
    _fromName = session?.name ?? '';
    final pre = widget.prefill;
    if (pre != null) {
      _applyPrefill(pre);
    }
    final mailto = widget.mailtoSourceUri;
    if (mailto != null && Get.isRegistered<MailtoLinkService>()) {
      Get.find<MailtoLinkService>().markComposeOpenedFromMailto(mailto);
    }
  }

  void _applyPrefill(ComposePrefill pre) {
    final addrs =
        pre.toAddresses.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (addrs.length >= 2) {
      _toRecipients.addAll(addrs);
    } else if (addrs.length == 1) {
      _toInputController.text = addrs.first;
    }
    final cc = pre.ccLine?.trim();
    if (cc != null && cc.isNotEmpty) {
      final ccParts = _parseToParts(cc);
      if (ccParts.length >= 2) {
        _ccRecipients.addAll(ccParts);
      } else if (ccParts.length == 1) {
        _ccInputController.text = ccParts.first;
      }
    }
    _subjectController.text = pre.subject;
    _bodyController.text = pre.body;
  }

  @override
  void dispose() {
    final mailto = widget.mailtoSourceUri;
    if (mailto != null && Get.isRegistered<MailtoLinkService>()) {
      Get.find<MailtoLinkService>().consumeMailtoSource(mailto);
    }
    _toInputController.dispose();
    _ccInputController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    _toFocus.dispose();
    _ccFocus.dispose();
    _subjectFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  static const int _maxAttachmentBytes = 18 * 1024 * 1024;

  String _guessMimeType(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.csv')) return 'text/csv';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  Future<void> _onAttach() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final added = <MailOutgoingAttachment>[];
      for (final f in result.files) {
        var bytes = f.bytes;
        if ((bytes == null || bytes.isEmpty) && f.path != null) {
          bytes = await File(f.path!).readAsBytes();
        }
        if (bytes == null || bytes.isEmpty) continue;
        if (bytes.length > _maxAttachmentBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '"${f.name}" is too large (max 18 MB).',
                  style: GoogleFonts.ptSans(fontSize: 14),
                ),
              ),
            );
          }
          continue;
        }
        final name = f.name.trim().isEmpty ? 'attachment' : f.name.trim();
        added.add(
          MailOutgoingAttachment(
            filename: name,
            contentType: _guessMimeType(name),
            bytes: bytes,
          ),
        );
      }
      if (added.isEmpty) return;
      setState(() => _attachments.addAll(added));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not add attachment: $e',
              style: GoogleFonts.ptSans(fontSize: 14),
            ),
          ),
        );
      }
    }
  }

  /// Split pasted lists like `a@x.com, b@y.com` into addresses.
  static final _addressSplitPattern = RegExp(r'[,;\s]+');

  List<String> _parseToParts(String raw) {
    return raw
        .split(_addressSplitPattern)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  bool get _useToChips => _toRecipients.isNotEmpty;

  void _addParsedToAddresses(String raw) {
    for (final a in _parseToParts(raw)) {
      if (!_toRecipients.contains(a)) {
        _toRecipients.add(a);
      }
    }
  }

  /// If only one chip remains, move back to plain text field (no tags).
  void _collapseToSingleToFieldIfNeeded() {
    if (_toRecipients.length != 1) return;
    _toInputController.text = _toRecipients.first;
    _toRecipients.clear();
  }

  /// Merges chip list + optional text field (for Send / validation).
  List<String> _allToRecipientEmails() {
    if (_useToChips) {
      final out = List<String>.from(_toRecipients);
      for (final p in _parseToParts(_toInputController.text)) {
        if (!out.contains(p)) {
          out.add(p);
        }
      }
      return out;
    }
    return _parseToParts(_toInputController.text);
  }

  bool get _useCcChips => _ccRecipients.isNotEmpty;

  void _addParsedCcAddresses(String raw) {
    for (final a in _parseToParts(raw)) {
      if (!_ccRecipients.contains(a)) {
        _ccRecipients.add(a);
      }
    }
  }

  void _collapseToSingleCcFieldIfNeeded() {
    if (_ccRecipients.length != 1) return;
    _ccInputController.text = _ccRecipients.first;
    _ccRecipients.clear();
  }

  List<String> _allCcRecipientEmails() {
    if (_useCcChips) {
      final out = List<String>.from(_ccRecipients);
      for (final p in _parseToParts(_ccInputController.text)) {
        if (!out.contains(p)) {
          out.add(p);
        }
      }
      return out;
    }
    return _parseToParts(_ccInputController.text);
  }

  void _commitPendingCcInput() {
    final raw = _ccInputController.text.trim();
    if (raw.isEmpty) return;

    if (_useCcChips) {
      _addParsedCcAddresses(raw);
      _ccInputController.clear();
      if (mounted) setState(() {});
      return;
    }

    final parts = _parseToParts(raw);
    if (parts.length >= 2) {
      _ccRecipients.clear();
      for (final p in parts) {
        if (!_ccRecipients.contains(p)) {
          _ccRecipients.add(p);
        }
      }
      _ccInputController.clear();
    }
    if (mounted) setState(() {});
  }

  void _onCcInputChanged(String value) {
    if (value.isEmpty) return;
    final last = value[value.length - 1];
    if (last == ',' || last == ';') {
      final head = value.substring(0, value.length - 1).trim();
      _ccInputController.text = '';
      if (head.isNotEmpty) {
        _addParsedCcAddresses(head);
      }
      if (mounted) setState(() {});
    }
  }

  void _commitPendingToInput() {
    final raw = _toInputController.text.trim();
    if (raw.isEmpty) return;

    if (_useToChips) {
      _addParsedToAddresses(raw);
      _toInputController.clear();
      if (mounted) setState(() {});
      return;
    }

    final parts = _parseToParts(raw);
    if (parts.length >= 2) {
      _toRecipients.clear();
      for (final p in parts) {
        if (!_toRecipients.contains(p)) {
          _toRecipients.add(p);
        }
      }
      _toInputController.clear();
    }
    if (mounted) setState(() {});
  }

  void _onToInputChanged(String value) {
    if (value.isEmpty) return;
    final last = value[value.length - 1];
    if (last == ',' || last == ';') {
      final head = value.substring(0, value.length - 1).trim();
      _toInputController.text = '';
      if (head.isNotEmpty) {
        _addParsedToAddresses(head);
      }
      if (mounted) setState(() {});
    }
  }

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  Future<void> _onSend() async {
    _dismissKeyboard();
    _commitPendingToInput();
    _commitPendingCcInput();
    final allTo = _allToRecipientEmails();
    if (allTo.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Add at least one recipient in To.',
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
      _toFocus.requestFocus();
      return;
    }

    if (_bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Add message content before sending.',
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
      _bodyFocus.requestFocus();
      return;
    }

    setState(() => _sending = true);
    try {
      await Get.find<MailRepository>().sendComposeMail(
        to: allTo,
        cc: _allCcRecipientEmails(),
        subject: _subjectController.text.trim(),
        text: _bodyController.text,
        attachments: List<MailOutgoingAttachment>.from(_attachments),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Message sent.',
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
      Get.back<void>();
    } on DioException catch (e) {
      if (!mounted) return;
      final msg = e.message ?? 'Could not send';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$e',
            style: GoogleFonts.ptSans(fontSize: 14),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onComposeMenu(String value) {
    if (value == 'discard') {
      unawaited(_discardFromMenu());
    }
  }

  Future<void> _discardFromMenu() async {
    if (await _confirmDiscardIfNeeded()) {
      if (mounted) Get.back<void>();
    }
  }

  Future<bool> _confirmDiscardIfNeeded() async {
    final dirty = _allToRecipientEmails().isNotEmpty ||
        _allCcRecipientEmails().isNotEmpty ||
        _subjectController.text.trim().isNotEmpty ||
        _bodyController.text.trim().isNotEmpty ||
        _attachments.isNotEmpty;
    if (!dirty) return true;
    if (!context.mounted) return false;
    return showDiscardComposeConfirmationDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmDiscardIfNeeded()) {
          if (context.mounted) Get.back<void>();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
          child: Theme(
          data: Theme.of(context).copyWith(
            splashColor: Colors.white12,
            highlightColor: Colors.white10,
          ),
          child: Scaffold(
            backgroundColor: _canvas,
            appBar: AppBar(
              backgroundColor: _canvas,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              iconTheme: IconThemeData(
                color: Colors.white.withValues(alpha: 0.92),
              ),
              leading: IconButton(
                padding: EdgeInsets.zero,
                icon: Icon(
                  Icons.chevron_left_rounded,
                  size: 28,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
                onPressed: () async {
                  if (await _confirmDiscardIfNeeded()) {
                    if (context.mounted) Get.back<void>();
                  }
                },
              ),
              actions: [
                IconButton(
                  tooltip: 'Attach',
                  icon: Icon(
                    Icons.attach_file_rounded,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  onPressed: _sending ? null : _onAttach,
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: _sending
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        )
                      : Icon(
                          Icons.send_rounded,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                  onPressed: _sending ? null : () => unawaited(_onSend()),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  color: const Color(0xFF2C2C2C),
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  onSelected: _onComposeMenu,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'discard',
                      child: Text(
                        'Discard',
                        style: GoogleFonts.ptSans(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissKeyboard,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _divider,
                  _fromRow(),
                  _divider,
                  _labeledField(
                    label: 'To',
                    field: _toRecipientsField(),
                  ),
                  _divider,
                  _labeledField(
                    label: 'Cc',
                    field: _ccRecipientsField(),
                  ),
                  _divider,
                  _labeledField(
                    label: 'Subject',
                    field: TextField(
                      controller: _subjectController,
                      focusNode: _subjectFocus,
                      style: _inputStyle,
                      cursorColor: kPrimaryBlue,
                      textInputAction: TextInputAction.next,
                      decoration: _lineDecoration(),
                      onTapOutside: (_) => _dismissKeyboard(),
                      onSubmitted: (_) => _bodyFocus.requestFocus(),
                    ),
                  ),
                  _divider,
                  if (_attachments.isNotEmpty) ...[
                    _composeAttachmentsSection(),
                    _divider,
                  ],
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.only(left: 16, right: 16, top: 10),
                      child: TextField(
                        controller: _bodyController,
                        focusNode: _bodyFocus,
                        style: _inputStyle,
                        cursorColor: kPrimaryBlue,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        onTapOutside: (_) => _dismissKeyboard(),
                        decoration: _lineDecoration(
                          hint: 'Compose Email',
                        ).copyWith(
                          alignLabelWithHint: true,
                        ),
                      ),
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

  Widget get _divider => Divider(
        height: 1,
        thickness: 1,
        color: _dividerColor.withValues(alpha: 0.85),
      );

  /// Same grid + card pattern as [mail_detail_view] `_MailAttachmentsSection`.
  Widget _composeAttachmentsSection() {
    final count = _attachments.length;
    final metaStyle = GoogleFonts.ptSans(
      color: Colors.white.withValues(alpha: 0.72),
      fontSize: 13,
      height: 1.25,
    );
    final countLabel = count == 1 ? '1 attachment' : '$count attachments';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(countLabel, style: metaStyle),
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
            itemCount: count,
            itemBuilder: (context, i) {
              return _ComposeOutgoingAttachmentCard(
                attachment: _attachments[i],
                onRemove: _sending
                    ? null
                    : () => setState(() => _attachments.removeAt(i)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _toRecipientsField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_useToChips)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height: _toChipsRowHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: _toRecipients.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) => _toChip(_toRecipients[i]),
              ),
            ),
          ),
        TextField(
          controller: _toInputController,
          focusNode: _toFocus,
          style: _inputStyle,
          cursorColor: kPrimaryBlue,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          decoration: _lineDecoration(
            hint: _useToChips
                ? 'Add another'
                : 'Email (comma separates more than one)',
          ),
          onTapOutside: (_) => _dismissKeyboard(),
          onChanged: _onToInputChanged,
          onSubmitted: (_) {
            _commitPendingToInput();
            _ccFocus.requestFocus();
          },
        ),
      ],
    );
  }

  /// Single-line chip strip height (horizontal scroll).
  static const double _toChipsRowHeight = 40;

  /// Dark pill so addresses stay readable (global theme is light — M3 chips were white-on-white).
  static const _toChipFill = Color(0xFF3A3D42);
  static const _toChipTextColor = Color(0xFFE8EAED);
  static const _toChipBorderColor = Color(0xFF5F6368);

  Widget _toChip(String email) {
    final labelStyle = GoogleFonts.ptSans(
      fontSize: 13,
      color: _toChipTextColor,
      height: 1.25,
      fontWeight: FontWeight.w400,
    );
    return Theme(
      data: Theme.of(context).copyWith(
        canvasColor: _toChipFill,
        colorScheme: Theme.of(context).colorScheme.copyWith(
          surface: _toChipFill,
          onSurface: _toChipTextColor,
          surfaceContainerHighest: _toChipFill,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: _toChipFill,
          selectedColor: _toChipFill,
          disabledColor: _toChipFill,
          deleteIconColor: const Color(0xFF9AA0A6),
          labelStyle: labelStyle,
          secondaryLabelStyle: labelStyle,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          side: const BorderSide(color: _toChipBorderColor),
          elevation: 0,
          pressElevation: 0,
        ),
      ),
      child: InputChip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
        color: WidgetStateProperty.all<Color>(_toChipFill),
        side: const WidgetStateBorderSide.fromMap(
          <WidgetStatesConstraint, BorderSide>{
            WidgetState.any: BorderSide(color: _toChipBorderColor),
          },
        ),
        label: Text(email, style: labelStyle),
        onDeleted: () {
          setState(() {
            _toRecipients.remove(email);
            _collapseToSingleToFieldIfNeeded();
          });
        },
        deleteIcon: const Icon(
          Icons.close_rounded,
          size: 16,
          color: Color(0xFF9AA0A6),
        ),
      ),
    );
  }

  Widget _ccRecipientsField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_useCcChips)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height: _toChipsRowHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                itemCount: _ccRecipients.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) => _ccChip(_ccRecipients[i]),
              ),
            ),
          ),
        TextField(
          controller: _ccInputController,
          focusNode: _ccFocus,
          style: _inputStyle,
          cursorColor: kPrimaryBlue,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          decoration: _lineDecoration(
            hint: _useCcChips
                ? 'Add another'
                : 'Email (comma separates more than one)',
          ),
          onTapOutside: (_) => _dismissKeyboard(),
          onChanged: _onCcInputChanged,
          onSubmitted: (_) {
            _commitPendingCcInput();
            _subjectFocus.requestFocus();
          },
        ),
      ],
    );
  }

  Widget _ccChip(String email) {
    final labelStyle = GoogleFonts.ptSans(
      fontSize: 13,
      color: _toChipTextColor,
      height: 1.25,
      fontWeight: FontWeight.w400,
    );
    return Theme(
      data: Theme.of(context).copyWith(
        canvasColor: _toChipFill,
        colorScheme: Theme.of(context).colorScheme.copyWith(
          surface: _toChipFill,
          onSurface: _toChipTextColor,
          surfaceContainerHighest: _toChipFill,
        ),
        chipTheme: ChipThemeData(
          backgroundColor: _toChipFill,
          selectedColor: _toChipFill,
          disabledColor: _toChipFill,
          deleteIconColor: const Color(0xFF9AA0A6),
          labelStyle: labelStyle,
          secondaryLabelStyle: labelStyle,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          side: const BorderSide(color: _toChipBorderColor),
          elevation: 0,
          pressElevation: 0,
        ),
      ),
      child: InputChip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
        color: WidgetStateProperty.all<Color>(_toChipFill),
        side: const WidgetStateBorderSide.fromMap(
          <WidgetStatesConstraint, BorderSide>{
            WidgetState.any: BorderSide(color: _toChipBorderColor),
          },
        ),
        label: Text(email, style: labelStyle),
        onDeleted: () {
          setState(() {
            _ccRecipients.remove(email);
            _collapseToSingleCcFieldIfNeeded();
          });
        },
        deleteIcon: const Icon(
          Icons.close_rounded,
          size: 16,
          color: Color(0xFF9AA0A6),
        ),
      ),
    );
  }

  /// Slightly off-white so it stays readable on black regardless of theme merges.
  static const _fromEmailColor = Color(0xFFE8EAED);
  String get _fromDisplay {
    final email = _fromEmail.trim();
    final name = _fromName.trim();
    if (name.isEmpty) return email.isEmpty ? '—' : email;
    if (email.isEmpty) return name;
    return '$name <$email>';
  }

  Widget _fromRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text('From', style: _labelStyle),
            ),
          ),
          Expanded(
            child: SelectableText(
              _fromDisplay,
              style: GoogleFonts.ptSans(
                color: _fromEmailColor,
                fontSize: 15,
                height: 1.35,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _labeledField({
    required String label,
    required Widget field,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(label, style: _labelStyle),
            ),
          ),
          Expanded(child: field),
        ],
      ),
    );
  }
}

/// Outgoing attachment tile — matches mail detail `_AttachmentPreviewCard` (grid thumb + dog-ear + remove).
class _ComposeOutgoingAttachmentCard extends StatelessWidget {
  const _ComposeOutgoingAttachmentCard({
    required this.attachment,
    this.onRemove,
  });

  final MailOutgoingAttachment attachment;
  final VoidCallback? onRemove;

  static const _cardHeight = 128.0;

  bool get _isSvg {
    final ct = attachment.contentType.toLowerCase();
    if (ct.contains('svg')) return true;
    return attachment.filename.toLowerCase().endsWith('.svg');
  }

  bool get _isRasterImage {
    final ct = attachment.contentType.toLowerCase();
    if (ct.startsWith('image/') && !ct.contains('svg')) return true;
    final n = attachment.filename.toLowerCase();
    return n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.heic');
  }

  bool get _isPdf {
    final ct = attachment.contentType.toLowerCase();
    if (ct.contains('pdf')) return true;
    return attachment.filename.toLowerCase().endsWith('.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
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
                        painter: _ComposeDogEarPainter(),
                      ),
                    ),
                    if (onRemove != null)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: onRemove,
                              borderRadius: BorderRadius.circular(6),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.close_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              attachment.filename,
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
    );
  }

  Widget _previewFill() {
    if (_isPdf) {
      return Center(
        child: Icon(
          Icons.picture_as_pdf_rounded,
          size: 48,
          color: Colors.red.shade300,
        ),
      );
    }
    try {
      final bytes = attachment.bytes;
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

/// Same fold as mail detail `_DogEarCornerPainter`.
class _ComposeDogEarPainter extends CustomPainter {
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
