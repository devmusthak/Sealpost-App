import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/calendar_event.dart';
import '../../models/day_calendar_markers.dart';
import 'calendar_day_cell.dart';
import 'calendar_palette.dart';

/// Sunday-first week row (`Su Mo … Sa`) and 6×7 grid.
class CalendarGrid extends StatelessWidget {
  const CalendarGrid({
    super.key,
    required this.visibleMonth,
    required this.selectedDate,
    required this.markersForDay,
    required this.onSelectDay,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DayCalendarMarkers Function(DateTime day) markersForDay;
  final ValueChanged<DateTime> onSelectDay;

  static const _weekdays = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(visibleMonth.year, visibleMonth.month);
    final leading = firstOfMonth.weekday % 7;

    final weekdayRow = Row(
      children: [
        for (final w in _weekdays)
          Expanded(
            child: Center(
              child: Text(
                w,
                style: GoogleFonts.ptSans(
                  color: CalendarPalette.weekdayLabel,
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
      ],
    );

    final cells = <Widget>[];
    for (var i = 0; i < 42; i++) {
      final cell = firstOfMonth.add(Duration(days: i - leading));
      final inMonth = cell.month == visibleMonth.month && cell.year == visibleMonth.year;
      final markers = markersForDay(cell);
      final selected = CalendarEvent.isSameDate(cell, selectedDate) && inMonth;

      cells.add(
        CalendarDayCell(
          cellDate: cell,
          visibleMonth: visibleMonth,
          selected: selected,
          markers: markers,
          onTap: () => onSelectDay(cell),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Column(
        children: [
          weekdayRow,
          const SizedBox(height: 2),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 0,
            crossAxisSpacing: 2,
            // Larger ratio → shorter rows (less vertical calendar height).
            childAspectRatio: 1.03,
            children: cells,
          ),
        ],
      ),
    );
  }
}
