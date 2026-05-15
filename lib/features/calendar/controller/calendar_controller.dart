import 'dart:async';

import 'package:get/get.dart';

import '../data/calendar_event_local_store.dart';
import '../models/calendar_event.dart';
import '../models/day_calendar_markers.dart';

/// Calendar + My Day state, persisted via [CalendarEventLocalStore].
class CalendarController extends GetxController {
  final RxList<CalendarEvent> events = <CalendarEvent>[].obs;
  final Rx<DateTime> selectedDate = _dateOnly(DateTime.now()).obs;
  final Rx<DateTime> visibleMonth = DateTime(DateTime.now().year, DateTime.now().month).obs;
  final RxBool ready = false.obs;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void onInit() {
    super.onInit();
    unawaited(_load());
  }

  Future<void> _load() async {
    final list = await CalendarEventLocalStore.load();
    events.assignAll(list);
    ready.value = true;
  }

  Future<void> _persist() async {
    await CalendarEventLocalStore.save(events.toList());
  }

  List<CalendarEvent> eventsOn(DateTime day) {
    final d = _dateOnly(day);
    return events.where((e) => CalendarEvent.isSameDate(e.date, d)).toList()
      ..sort((a, b) {
        final ah = a.startTime.hour * 60 + a.startTime.minute;
        final bh = b.startTime.hour * 60 + b.startTime.minute;
        return ah.compareTo(bh);
      });
  }

  List<CalendarEvent> get eventsForSelectedDate => eventsOn(selectedDate.value);

  final RxString eventSearchQuery = ''.obs;

  bool get isEventSearchActive => eventSearchQuery.value.trim().isNotEmpty;

  void setEventSearchQuery(String value) => eventSearchQuery.value = value;

  /// Selected day when not searching; all matching events (any day) when search is non-empty.
  List<CalendarEvent> eventsForListView() {
    final q = eventSearchQuery.value;
    if (q.trim().isEmpty) return eventsForSelectedDate;
    final out = events.where((e) => e.matchesSearchQuery(q)).toList();
    out.sort((a, b) {
      final da = DateTime(a.date.year, a.date.month, a.date.day);
      final db = DateTime(b.date.year, b.date.month, b.date.day);
      final c = da.compareTo(db);
      if (c != 0) return c;
      final ah = a.startTime.hour * 60 + a.startTime.minute;
      final bh = b.startTime.hour * 60 + b.startTime.minute;
      return ah.compareTo(bh);
    });
    return out;
  }

  /// Cyan dots (dot-style events) + optional coral bar (any bar-style event), per reference UI.
  DayCalendarMarkers markersForDay(DateTime day) {
    final list = eventsOn(day);
    var dots = 0;
    var bar = false;
    for (final e in list) {
      if (e.useBarOnCalendar) {
        bar = true;
      } else {
        dots++;
      }
    }
    const maxDots = 5;
    return DayCalendarMarkers(dotCount: dots > maxDots ? maxDots : dots, showBar: bar);
  }

  void selectDate(DateTime day) {
    selectedDate.value = _dateOnly(day);
    final v = visibleMonth.value;
    if (day.year != v.year || day.month != v.month) {
      visibleMonth.value = DateTime(day.year, day.month);
    }
  }

  void goPrevMonth() {
    final v = visibleMonth.value;
    visibleMonth.value = DateTime(v.year, v.month - 1);
  }

  void goNextMonth() {
    final v = visibleMonth.value;
    visibleMonth.value = DateTime(v.year, v.month + 1);
  }

  Future<void> addEvent(CalendarEvent e) async {
    events.add(e);
    events.refresh();
    await _persist();
  }

  Future<void> updateEvent(CalendarEvent e, {String? currentUserId}) async {
    final i = events.indexWhere((x) => x.id == e.id);
    if (i < 0) return;
    if (!events[i].isCreator(currentUserId)) return;
    events[i] = e;
    events.refresh();
    await _persist();
  }

  Future<void> deleteEvent(String id, {String? currentUserId}) async {
    final i = events.indexWhere((ev) => ev.id == id);
    if (i < 0) return;
    if (!events[i].isCreator(currentUserId)) return;
    events.removeAt(i);
    events.refresh();
    await _persist();
  }

  Future<void> deleteAllOnSelectedDate() async {
    final d = selectedDate.value;
    events.removeWhere((e) => CalendarEvent.isSameDate(e.date, d));
    events.refresh();
    await _persist();
  }

  Future<void> toggleCompleted(String id, {String? currentUserId}) async {
    final i = events.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final e = events[i];
    if (!e.isCreator(currentUserId)) return;
    events[i] = e.copyWith(
      isCompleted: !e.isCompleted,
      updatedAt: DateTime.now(),
    );
    events.refresh();
    await _persist();
  }
}

