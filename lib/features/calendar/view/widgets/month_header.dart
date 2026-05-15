import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'calendar_palette.dart';

/// Month row: **←** month year **→** (title centered between chevrons).
class MonthHeader extends StatelessWidget {
  const MonthHeader({
    super.key,
    required this.visibleMonth,
    required this.onPrev,
    required this.onNext,
  });

  final DateTime visibleMonth;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static const double _arrowSlot = 36;

  @override
  Widget build(BuildContext context) {
    final label = '${_months[visibleMonth.month - 1]} ${visibleMonth.year}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: _arrowSlot,
            child: IconButton(
              onPressed: onPrev,
              padding: EdgeInsets.zero,
              tooltip: 'Previous month',
              icon: Icon(
                Icons.chevron_left,
                color: CalendarPalette.primaryText.withValues(alpha: 0.9),
                size: 22,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.ptSans(
                color: CalendarPalette.primaryText,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
          SizedBox(
            width: _arrowSlot,
            child: IconButton(
              onPressed: onNext,
              padding: EdgeInsets.zero,
              tooltip: 'Next month',
              icon: Icon(
                Icons.chevron_right,
                color: CalendarPalette.primaryText.withValues(alpha: 0.9),
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
