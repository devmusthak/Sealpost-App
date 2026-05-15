import 'package:flutter/material.dart';

import '../../models/day_calendar_markers.dart';
import 'calendar_palette.dart';

/// Reference: tight row of small cyan circles; optional muted coral pill below.
class CalendarDayMarkers extends StatelessWidget {
  const CalendarDayMarkers({super.key, required this.markers});

  final DayCalendarMarkers markers;

  static const double _dot = 2.5;
  static const double _gap = 1.2;
  static const double _barWidth = 20;
  static const double _barHeight = 3;

  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) {
      return const SizedBox(height: 4);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 3,
          child: markers.dotCount > 0
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < markers.dotCount; i++) ...[
                      if (i > 0) const SizedBox(width: _gap),
                      Container(
                        width: _dot,
                        height: _dot,
                        decoration: const BoxDecoration(
                          color: CalendarPalette.markerDot,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ],
                )
              : null,
        ),
        if (markers.showBar) ...[
          if (markers.dotCount > 0) const SizedBox(height: 1),
          Container(
            width: _barWidth,
            height: _barHeight,
            decoration: BoxDecoration(
              color: CalendarPalette.markerBar,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ],
    );
  }
}
