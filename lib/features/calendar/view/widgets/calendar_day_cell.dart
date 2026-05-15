import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../theme/app_theme.dart';
import '../../models/day_calendar_markers.dart';
import 'calendar_day_markers.dart';
import 'calendar_palette.dart';

class CalendarDayCell extends StatelessWidget {
  const CalendarDayCell({
    super.key,
    required this.cellDate,
    required this.visibleMonth,
    required this.selected,
    required this.markers,
    required this.onTap,
  });

  final DateTime cellDate;
  final DateTime visibleMonth;
  final bool selected;
  final DayCalendarMarkers markers;
  final VoidCallback onTap;

  bool get inMonth =>
      cellDate.year == visibleMonth.year && cellDate.month == visibleMonth.month;

  bool get _isToday {
    final n = DateTime.now();
    return cellDate.year == n.year && cellDate.month == n.month && cellDate.day == n.day;
  }

  @override
  Widget build(BuildContext context) {
    final Color color;
    final FontWeight weight;
    if (!inMonth) {
      color = CalendarPalette.mutedText;
      weight = FontWeight.w600;
    } else if (selected) {
      color = kPrimaryBlue;
      weight = FontWeight.w800;
    } else {
      color = CalendarPalette.primaryText;
      weight = FontWeight.w600;
    }

    final textStyle = GoogleFonts.ptSans(
      fontSize: 15,
      fontWeight: weight,
      color: color,
    );

    final dayChip = SizedBox(
      width: 30,
      height: 30,
      child: Center(
        child: Text(
          '${cellDate.day}',
          style: textStyle,
        ),
      ),
    );

    final Widget dayNumber;
    if (_isToday) {
      final borderColor = !inMonth
          ? CalendarPalette.mutedText.withValues(alpha: 0.85)
          : selected
              ? kPrimaryBlue
              : Colors.white.withValues(alpha: 0.42);
      final borderWidth = selected && inMonth ? 2.0 : 1.25;
      dayNumber = Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Center(
          child: Text(
            '${cellDate.day}',
            style: textStyle,
          ),
        ),
      );
    } else {
      dayNumber = dayChip;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  dayNumber,
                  const SizedBox(height: 0),
                  CalendarDayMarkers(markers: markers),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
