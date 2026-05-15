import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'calendar_palette.dart';

/// “MY DAY” title only (add/delete use the search bar + event row actions).
class MyDayHeader extends StatelessWidget {
  const MyDayHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final title = GoogleFonts.ptSans(
      color: CalendarPalette.primaryText,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.4,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Center(child: Text('MY DAY', textAlign: TextAlign.center, style: title)),
    );
  }
}
