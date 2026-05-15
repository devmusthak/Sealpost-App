import 'package:flutter/material.dart';

/// Dark calendar module colors (reference: rounded card on #121212).
abstract final class CalendarPalette {
  static const background = Color(0xFF121212);

  /// Slightly lifted surface for the rounded calendar card.
  static const calendarCard = Color(0xFF1A1A1A);

  static const primaryText = Colors.white;
  static const mutedText = Color(0xFF5C5C5C);
  static const weekdayLabel = Color(0xFF9E9E9E);

  static const divider = Colors.white24;

  /// Dot markers under dates (vibrant light blue).
  static const markerDot = Color(0xFF64B5F6);

  /// Pill bar markers (muted coral).
  static const markerBar = Color(0xFFE57373);

  /// Dark fill behind check icon on white circle (My Day list).
  static const selectedFg = Color(0xFF121212);
}
