import 'package:flutter/material.dart';

/// Calendar / My Day event (local store today; `creatorId` / `participantIds` ready for shared backend).
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.date,
    required this.startTime,
    this.endTime,
    required this.durationMinutes,
    required this.category,
    required this.categoryColor,
    required this.isCompleted,
    required this.hasReminder,
    required this.createdAt,
    this.updatedAt,
    this.creatorId = '',
    this.participantIds = const [],
    this.useBarOnCalendar = false,
  });

  final String id;
  final String title;
  /// Date-only (year, month, day); time components ignored.
  final DateTime date;
  final TimeOfDay startTime;
  final TimeOfDay? endTime;
  final int durationMinutes;
  final String category;
  final Color categoryColor;
  final bool isCompleted;
  final bool hasReminder;
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// Empty [creatorId] means legacy local event (treated as owned by the signed-in user when ids match is N/A — see [isCreator]).
  final String creatorId;
  final List<String> participantIds;

  /// When true, this event is shown as a coral pill under the date; otherwise it adds a cyan dot.
  final bool useBarOnCalendar;

  /// Creator (or legacy event with no `creatorId`) may edit, delete, and toggle completion.
  bool isCreator(String? currentUserId) {
    final c = creatorId.trim();
    if (c.isEmpty) return true;
    final uid = (currentUserId ?? '').trim();
    return uid.isNotEmpty && c == uid;
  }

  bool isSharedParticipant(String? currentUserId) {
    final uid = (currentUserId ?? '').trim();
    if (uid.isEmpty) return false;
    return participantIds.contains(uid);
  }

  CalendarEvent copyWith({
    String? id,
    String? title,
    DateTime? date,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    bool clearEndTime = false,
    int? durationMinutes,
    String? category,
    Color? categoryColor,
    bool? isCompleted,
    bool? hasReminder,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearUpdatedAt = false,
    String? creatorId,
    List<String>? participantIds,
    bool? useBarOnCalendar,
  }) {
    return CalendarEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      date: date ?? this.date,
      startTime: startTime ?? this.startTime,
      endTime: clearEndTime ? null : (endTime ?? this.endTime),
      durationMinutes: durationMinutes ?? this.durationMinutes,
      category: category ?? this.category,
      categoryColor: categoryColor ?? this.categoryColor,
      isCompleted: isCompleted ?? this.isCompleted,
      hasReminder: hasReminder ?? this.hasReminder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: clearUpdatedAt ? null : (updatedAt ?? this.updatedAt),
      creatorId: creatorId ?? this.creatorId,
      participantIds: participantIds ?? this.participantIds,
      useBarOnCalendar: useBarOnCalendar ?? this.useBarOnCalendar,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'date': _dateKey(date),
      'startHour': startTime.hour,
      'startMinute': startTime.minute,
      if (endTime != null) 'endHour': endTime!.hour,
      if (endTime != null) 'endMinute': endTime!.minute,
      'durationMinutes': durationMinutes,
      'category': category,
      'categoryColor': (categoryColor.a * 255).round() << 24 |
          (categoryColor.r * 255).round() << 16 |
          (categoryColor.g * 255).round() << 8 |
          (categoryColor.b * 255).round(),
      'isCompleted': isCompleted,
      'hasReminder': hasReminder,
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
      'creatorId': creatorId,
      'participantIds': participantIds,
      'useBarOnCalendar': useBarOnCalendar,
    };
  }

  static CalendarEvent fromJson(Map<String, dynamic> json) {
    final endH = json['endHour'];
    final endM = json['endMinute'];
    final rawParticipants = json['participantIds'];
    final participants = rawParticipants is List
        ? rawParticipants.map((e) => '$e').where((s) => s.isNotEmpty).toList()
        : const <String>[];
    return CalendarEvent(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      date: _parseDateKey('${json['date'] ?? ''}'),
      startTime: TimeOfDay(
        hour: (json['startHour'] as num?)?.toInt() ?? 0,
        minute: (json['startMinute'] as num?)?.toInt() ?? 0,
      ),
      endTime: (endH is num && endM is num)
          ? TimeOfDay(hour: endH.toInt(), minute: endM.toInt())
          : null,
      durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 0,
      category: '${json['category'] ?? 'Personal'}',
      categoryColor: Color((json['categoryColor'] as num?)?.toInt() ?? 0xFFE040FB),
      isCompleted: json['isCompleted'] == true,
      hasReminder: json['hasReminder'] == true,
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.tryParse('${json['updatedAt'] ?? ''}')?.toLocal(),
      creatorId: '${json['creatorId'] ?? ''}',
      participantIds: participants,
      useBarOnCalendar: json['useBarOnCalendar'] == true,
    );
  }

  static String _dateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static DateTime _parseDateKey(String key) {
    final parts = key.split('-');
    if (parts.length == 3) {
      final y = int.tryParse(parts[0]) ?? 1970;
      final m = int.tryParse(parts[1]) ?? 1;
      final d = int.tryParse(parts[2]) ?? 1;
      return DateTime(y, m, d);
    }
    return DateTime.now();
  }

  static bool isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static const _monthFull = [
    'january',
    'february',
    'march',
    'april',
    'may',
    'june',
    'july',
    'august',
    'september',
    'october',
    'november',
    'december',
  ];

  static const _monthShort = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  /// Case-insensitive match for calendar search (title, category, date, time, duration, flags).
  bool matchesSearchQuery(String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (title.toLowerCase().contains(q)) return true;
    if (category.toLowerCase().contains(q)) return true;
    if ('$durationMinutes'.contains(q)) return true;
    if (q == 'reminder' && hasReminder) return true;
    if (q == 'completed' && isCompleted) return true;
    if (q == 'bar' && useBarOnCalendar) return true;
    final mf = _monthFull[date.month - 1];
    final ms = _monthShort[date.month - 1];
    if (mf.contains(q) || ms.contains(q) || q.contains(ms)) return true;
    final iso = _dateKey(date);
    if (iso.contains(q)) return true;
    final asInt = int.tryParse(q);
    if (asInt != null) {
      if (asInt == date.day || asInt == date.month || asInt == date.year) return true;
    }
    final h = startTime.hour;
    final m = startTime.minute;
    final t24 = '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    if (t24.contains(q)) return true;
    final h12 = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    final ap = h >= 12 ? 'pm' : 'am';
    final t12 = '$h12:${m.toString().padLeft(2, '0')} $ap';
    if (t12.contains(q)) return true;
    return false;
  }
}
