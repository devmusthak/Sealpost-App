import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'my_day_event_tile.dart';

/// Date and time selectors on one horizontal row.
class InlineDateTimeRow extends StatelessWidget {
  const InlineDateTimeRow({
    super.key,
    required this.date,
    required this.time,
    required this.onPickDate,
    required this.onPickTime,
    this.enabled = true,
  });

  final DateTime date;
  final TimeOfDay time;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final bool enabled;

  static const _months = [
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

  String get _dateLabel {
    final w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1];
    return '$w, ${_months[date.month - 1]} ${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    final label = GoogleFonts.ptSans(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w500,
    );
    final border = Border.all(color: Colors.white.withValues(alpha: 0.14));
    final radius = BorderRadius.circular(12);

    Widget cell({required VoidCallback onTap, required Widget child}) {
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            splashColor: Colors.white.withValues(alpha: 0.06),
            highlightColor: Colors.white.withValues(alpha: 0.04),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                border: border,
                borderRadius: radius,
              ),
              child: child,
            ),
          ),
        ),
      );
    }

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        cell(
          onTap: onPickDate,
          child: Row(
            children: [
              Icon(Icons.calendar_today_outlined, size: 18, color: Colors.white.withValues(alpha: 0.55)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_dateLabel, style: label, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        cell(
          onTap: onPickTime,
          child: Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: Colors.white.withValues(alpha: 0.55)),
              const SizedBox(width: 10),
              Text(MyDayEventTile.format24(time), style: label),
            ],
          ),
        ),
      ],
    );

    if (!enabled) {
      return IgnorePointer(
        child: Opacity(
          opacity: 0.85,
          child: row,
        ),
      );
    }
    return row;
  }
}
