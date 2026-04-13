import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/app_theme.dart';
import 'hex_header_background.dart';

/// Same canvas as [HomeScreen] (`0xFF121212`).
const _dialogSurface = Color(0xFF121212);

const _dialogOnSurface = Color(0xFFE8EAED);

const _dialogMuted = Color(0xFF9AA0A6);

/// Modal: soft hex header, logo, copy, checkbox, actions — dark like home.
Future<bool> showDeleteMailConfirmationDialog(
  BuildContext context, {
  required String subjectLine,
  required Future<String?> Function() onConfirmDelete,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (ctx) => _DeleteMailDialog(
      subjectLine: subjectLine,
      onConfirmDelete: onConfirmDelete,
    ),
  );
  return ok ?? false;
}

class _DeleteMailDialog extends StatefulWidget {
  const _DeleteMailDialog({
    required this.subjectLine,
    required this.onConfirmDelete,
  });

  final String subjectLine;
  final Future<String?> Function() onConfirmDelete;

  @override
  State<_DeleteMailDialog> createState() => _DeleteMailDialogState();
}

class _DeleteMailDialogState extends State<_DeleteMailDialog> {
  bool _understood = false;
  bool _busy = false;
  String? _error;

  Future<void> _onDelete() async {
    if (!_understood || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onConfirmDelete();
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final displaySubject =
        widget.subjectLine.trim().isEmpty ? 'this message' : widget.subjectLine.trim();
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Material(
        color: _dialogSurface,
        elevation: 24,
        shadowColor: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 132,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const CustomPaint(
                    painter: HexHeaderPainter(),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          kHexHeaderBaseColor.withValues(alpha: 0),
                          _dialogSurface,
                        ],
                        stops: const [0.35, 1],
                      ),
                    ),
                  ),
                  const Align(
                    alignment: Alignment(0, 0.35),
                    child: SealpostLogoCircleBadge(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
              child: Column(
                children: [
                  Text(
                    'Delete ‘$displaySubject’?',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.ptSans(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                      color: _dialogOnSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This message will be deleted permanently. '
                    "You can't take it back or recover it later.",
                    textAlign: TextAlign.center,
                    style: GoogleFonts.ptSans(
                      fontSize: 14,
                      height: 1.45,
                      color: _dialogMuted,
                    ),
                  ),
                  const SizedBox(height: 20),
                  InkWell(
                    onTap: _busy
                        ? null
                        : () => setState(() => _understood = !_understood),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _understood,
                              onChanged: _busy
                                  ? null
                                  : (v) =>
                                      setState(() => _understood = v ?? false),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              checkColor: Colors.white,
                              fillColor: WidgetStateProperty.resolveWith(
                                (states) {
                                  if (states.contains(WidgetState.selected)) {
                                    return kPrimaryBlue;
                                  }
                                  if (states.contains(WidgetState.disabled)) {
                                    return Colors.white.withValues(alpha: 0.06);
                                  }
                                  return Colors.transparent;
                                },
                              ),
                              side: const BorderSide(
                                color: Color(0xFF5F6368),
                                width: 1.4,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              'I understand it will not be recoverable',
                              style: GoogleFonts.ptSans(
                                fontSize: 14,
                                color: _dialogMuted,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.ptSans(
                        fontSize: 13,
                        color: scheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed:
                              _busy ? null : () => Navigator.of(context).pop(false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _dialogOnSurface,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            'Keep message',
                            style: GoogleFonts.ptSans(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: (_understood && !_busy) ? _onDelete : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFE53935),
                            disabledBackgroundColor:
                                Colors.white.withValues(alpha: 0.08),
                            disabledForegroundColor:
                                Colors.white.withValues(alpha: 0.35),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _busy
                              ? SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white.withValues(alpha: 0.9),
                                  ),
                                )
                              : Text(
                                  'Delete message',
                                  style: GoogleFonts.ptSans(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
