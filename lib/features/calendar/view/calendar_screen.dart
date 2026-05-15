import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/auth/auth_repository.dart';
import '../../../screens/chat/view/chat_view.dart';
import '../controller/calendar_controller.dart';
import '../models/calendar_event.dart';
import 'widgets/calendar_grid.dart';
import 'widgets/calendar_palette.dart';
import 'create_event_screen.dart';
import 'widgets/calendar_search_header.dart';
import 'widgets/create_event_bottom_sheet.dart';
import 'widgets/month_header.dart';
import 'widgets/my_day_event_tile.dart';
import 'widgets/my_day_header.dart';

/// Calendar + My Day (Reminder) — same shell as Chat/Calls (bg + search bar).
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    if (Get.isRegistered<CalendarController>()) {
      Get.find<CalendarController>().setEventSearchQuery('');
    }
    super.dispose();
  }

  static String _dateCaption(CalendarEvent e) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${m[e.date.month - 1]} ${e.date.day}, ${e.date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final c = Get.find<CalendarController>();
    final String? uid = Get.isRegistered<AuthRepository>() ? Get.find<AuthRepository>().userId : null;

    void openCreateScreen() {
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (ctx) => CreateEventScreen(
            initialDate: c.selectedDate.value,
            onSave: c.addEvent,
            currentUserId: uid,
          ),
        ),
      );
    }

    void openEventSheet(CalendarEvent e) {
      c.selectDate(e.date);
      CreateEventBottomSheet.open(
        context,
        existing: e,
        initialDate: DateTime(e.date.year, e.date.month, e.date.day),
        onSave: (ev) => c.updateEvent(ev, currentUserId: uid),
        onDelete: e.isCreator(uid) ? (id) => c.deleteEvent(id, currentUserId: uid) : null,
        currentUserId: uid,
      );
    }

    return Scaffold(
      backgroundColor: ChatScreen.overlay,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/chat.jpeg',
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
          ColoredBox(color: ChatScreen.overlay.withValues(alpha: 0.88)),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: CalendarSearchHeader(
                    controller: _searchController,
                    onChanged: c.setEventSearchQuery,
                    onAddPressed: openCreateScreen,
                  ),
                ),
                Expanded(
                  child: Obx(() {
                    if (!c.ready.value) {
                      return const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white38,
                          ),
                        ),
                      );
                    }

                    final searching = c.isEventSearchActive;
                    final list = c.eventsForListView();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: CalendarPalette.calendarCard,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  MonthHeader(
                                    visibleMonth: c.visibleMonth.value,
                                    onPrev: c.goPrevMonth,
                                    onNext: c.goNextMonth,
                                  ),
                                  const SizedBox(height: 2),
                                  CalendarGrid(
                                    visibleMonth: c.visibleMonth.value,
                                    selectedDate: c.selectedDate.value,
                                    markersForDay: c.markersForDay,
                                    onSelectDay: c.selectDate,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (searching)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
                            child: Text(
                              'Search results',
                              style: GoogleFonts.ptSans(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        MyDayHeader(),
                        Expanded(
                          child: list.isEmpty
                              ? Center(
                                  child: Text(
                                    searching
                                        ? 'No matching events'
                                        : 'No events for this day',
                                    style: GoogleFonts.ptSans(
                                      color: Colors.white.withValues(alpha: 0.35),
                                      fontSize: 14,
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  itemCount: list.length,
                                  separatorBuilder: (context, index) => Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: Colors.white.withValues(alpha: 0.06),
                                  ),
                                  itemBuilder: (ctx, i) {
                                    final e = list[i];
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (searching)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                left: 8,
                                                right: 8,
                                                bottom: 4,
                                              ),
                                              child: Text(
                                                _dateCaption(e),
                                                style: GoogleFonts.ptSans(
                                                  color: Colors.white54,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          MyDayEventTile(
                                            event: e,
                                            onRowTap: () {
                                              if (e.isCreator(uid)) {
                                                c.toggleCompleted(e.id, currentUserId: uid);
                                              } else {
                                                openEventSheet(e);
                                              }
                                            },
                                            onLongPressEdit: e.isCreator(uid) ? () => openEventSheet(e) : null,
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
