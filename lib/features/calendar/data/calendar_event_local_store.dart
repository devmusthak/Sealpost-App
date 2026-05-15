import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/calendar_event.dart';

/// Persists [CalendarEvent] list locally (no backend).
abstract final class CalendarEventLocalStore {
  static const _key = 'sealpost_calendar_events_v1';

  static Future<List<CalendarEvent>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <CalendarEvent>[];
      for (final e in decoded) {
        if (e is Map) {
          out.add(CalendarEvent.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<CalendarEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(events.map((e) => e.toJson()).toList());
    await prefs.setString(_key, encoded);
  }
}
