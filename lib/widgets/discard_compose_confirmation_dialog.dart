import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'hex_header_background.dart';

/// Same shell as [showDeleteMailConfirmationDialog] (hex header, logo, dark card).
const _dialogSurface = Color(0xFF121212);
const _dialogOnSurface = Color(0xFFE8EAED);
const _dialogMuted = Color(0xFF9AA0A6);

/// Returns `true` if the user chose to discard the draft.
Future<bool> showDiscardComposeConfirmationDialog(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (ctx) => const _DiscardComposeDialog(),
  );
  return ok ?? false;
}

class _DiscardComposeDialog extends StatelessWidget {
  const _DiscardComposeDialog();

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
              child: Column(
                children: [
                  Text(
                    'Discard draft?',
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
                    'You have unsaved changes. If you leave now, this message '
                    'will not be saved.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.ptSans(
                      fontSize: 14,
                      height: 1.45,
                      color: _dialogMuted,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
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
                            'Keep editing',
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
                          onPressed: () => Navigator.of(context).pop(true),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFE53935),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            'Discard',
                            style: GoogleFonts.ptSans(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
