import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/calendar_event.dart';
import 'calendar_palette.dart';

class MyDayEventTile extends StatelessWidget {
  const MyDayEventTile({
    super.key,
    required this.event,
    required this.onRowTap,
    this.onLongPressEdit,
  });

  final CalendarEvent event;
  final VoidCallback onRowTap;
  final VoidCallback? onLongPressEdit;

  /// 24h compact style like reference "09:30".
  static String format24(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final timeStyle = GoogleFonts.ptSans(
      color: CalendarPalette.primaryText.withValues(alpha: event.isCompleted ? 0.55 : 1),
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    final titleStyle = GoogleFonts.ptSans(
      color: CalendarPalette.primaryText.withValues(alpha: event.isCompleted ? 0.55 : 1),
      fontSize: 15,
      fontWeight: FontWeight.w700,
      decoration: event.isCompleted ? TextDecoration.lineThrough : TextDecoration.none,
      decorationColor: CalendarPalette.primaryText,
    );
    final metaStyle = GoogleFonts.ptSans(
      color: CalendarPalette.primaryText.withValues(alpha: event.isCompleted ? 0.45 : 0.85),
      fontSize: 12,
      fontWeight: FontWeight.w500,
    );

    final durationLabel = '${event.durationMinutes} Mins';

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(MyDayEventTile.format24(event.startTime), style: timeStyle),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10, left: 2),
            child: SizedBox(
              height: 44,
              width: 1,
              child: ColoredBox(
                color: Colors.white.withValues(alpha: event.isCompleted ? 0.2 : 0.35),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      event.category,
                      style: metaStyle.copyWith(color: event.categoryColor.withValues(alpha: event.isCompleted ? 0.55 : 1)),
                    ),
                    Text(' · ', style: metaStyle),
                    Text(durationLabel, style: metaStyle),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _StatusCircle(event: event, dimmed: event.isCompleted),
          ),
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onRowTap,
        onLongPress: onLongPressEdit,
        splashColor: Colors.white.withValues(alpha: 0.06),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: Opacity(
          opacity: event.isCompleted ? 0.72 : 1,
          child: content,
        ),
      ),
    );
  }
}

class _StatusCircle extends StatelessWidget {
  const _StatusCircle({required this.event, required this.dimmed});

  final CalendarEvent event;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    const size = 26.0;
    if (event.isCompleted) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: CalendarPalette.primaryText.withValues(alpha: dimmed ? 0.75 : 1),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.check,
          size: 16,
          color: CalendarPalette.selectedFg.withValues(alpha: dimmed ? 0.9 : 1),
        ),
      );
    }
    if (event.hasReminder) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: CalendarPalette.primaryText.withValues(alpha: 0.9), width: 1.4),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.notifications_none_rounded,
          size: 14,
          color: CalendarPalette.primaryText.withValues(alpha: 0.95),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: CalendarPalette.primaryText.withValues(alpha: 0.9), width: 1.4),
      ),
    );
  }
}
