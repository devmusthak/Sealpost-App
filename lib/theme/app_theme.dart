import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Brand blue from [assets/logo.svg].
const Color kPrimaryBlue = Color(0xFF375DFB);

const Color kDarkBg = Color(0xFF0D0D1B);

/// Boldonse for the **LIVCONNECT** wordmark only (beside icon / under splash mark).
TextStyle sealpostWordmarkStyle({
  required Color color,
  double fontSize = 20,
  double letterSpacing = 1.15,
}) {
  return GoogleFonts.boldonse(
    color: color,
    fontSize: fontSize,
    letterSpacing: letterSpacing,
    height: 1.0,
  );
}

/// PT Sans for inputs and any non-[AppText] widgets. Merges on top of PT Sans.
TextStyle appTextStyle([TextStyle? merge]) {
  return GoogleFonts.ptSans().merge(merge);
}
