import 'package:flutter/material.dart';

/// Preset categories matching the reference palette (Meetings, Work, Personal, Groceries).
class CalendarCategoryPreset {
  const CalendarCategoryPreset({
    required this.id,
    required this.label,
    required this.color,
  });

  final String id;
  final String label;
  final Color color;

  static const List<CalendarCategoryPreset> all = [
    CalendarCategoryPreset(
      id: 'meetings',
      label: 'Meetings',
      color: Color(0xFF4DD0E1),
    ),
    CalendarCategoryPreset(
      id: 'work',
      label: 'Work',
      color: Color(0xFFFFCA28),
    ),
    CalendarCategoryPreset(
      id: 'personal',
      label: 'Personal',
      color: Color(0xFFE91E8C),
    ),
    CalendarCategoryPreset(
      id: 'groceries',
      label: 'Groceries',
      color: Color(0xFF69F0AE),
    ),
  ];

  static CalendarCategoryPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  static CalendarCategoryPreset byLabelOrDefault(String label) {
    for (final p in all) {
      if (p.label.toLowerCase() == label.toLowerCase()) return p;
    }
    return all[2];
  }
}
