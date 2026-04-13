import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Base fill behind the hex grid (delete dialog + drawer brand band).
const kHexHeaderBaseColor = Color(0xFF1E1E1E);

/// Hex grid in the top band; pair with a gradient to [fadeToColor] underneath.
class HexHeaderPainter extends CustomPainter {
  const HexHeaderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = kHexHeaderBaseColor;
    canvas.drawRect(Offset.zero & size, bg);

    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;

    const r = 11.0;
    final dx = math.sqrt(3) * r;
    final dy = r * 1.5;

    for (var row = -1; row * dy < size.height + dy; row++) {
      final y = row * dy + r;
      final offsetRow = row.isEven ? 0.0 : dx / 2;
      for (var col = -1; col * dx < size.width + dx; col++) {
        final x = col * dx + offsetRow + dx * 0.25;
        _drawHex(canvas, Offset(x, y), r, stroke);
      }
    }
  }

  void _drawHex(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final ang = -math.pi / 2 + i * math.pi / 3;
      final x = c.dx + r * math.cos(ang);
      final y = c.dy + r * math.sin(ang);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Circular logo treatment used in the delete-mail dialog header.
class SealpostLogoCircleBadge extends StatelessWidget {
  const SealpostLogoCircleBadge({
    super.key,
    this.diameter = 76,
    this.logoPadding = 14,
  });

  final double diameter;
  final double logoPadding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: EdgeInsets.all(logoPadding),
      child: SvgPicture.asset(
        'assets/logo.svg',
        fit: BoxFit.contain,
      ),
    );
  }
}
