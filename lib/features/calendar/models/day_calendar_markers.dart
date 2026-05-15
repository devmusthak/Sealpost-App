/// Visual markers for one day on the month grid (reference: cyan dots + coral bar).
class DayCalendarMarkers {
  const DayCalendarMarkers({required this.dotCount, required this.showBar});

  /// Number of cyan dot markers (events not using the bar style), capped for layout.
  final int dotCount;

  /// Thick coral pill when any event uses the bar calendar style.
  final bool showBar;

  bool get isEmpty => dotCount <= 0 && !showBar;
}
