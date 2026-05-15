import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../theme/app_theme.dart';
import '../../models/calendar_event.dart';
import '../../models/event_invitee.dart';
import 'auto_grow_title_field.dart';
import 'calendar_palette.dart';
import 'event_friends_picker_delegate.dart';
import 'event_invitees_section.dart';
import 'inline_date_time_row.dart';

/// Pure-black minimal sheet: title, date + time row, save (metadata defaults on create; preserved on edit).
class CreateEventBottomSheet extends StatefulWidget {
  const CreateEventBottomSheet({
    super.key,
    this.existing,
    required this.initialDate,
    required this.onSave,
    this.onDelete,
    this.currentUserId,
  });

  final CalendarEvent? existing;
  final DateTime initialDate;
  final Future<void> Function(CalendarEvent event) onSave;
  final Future<void> Function(String id)? onDelete;
  /// Signed-in user; used for creator checks and assigning [CalendarEvent.creatorId] on create.
  final String? currentUserId;

  static Future<void> open(
    BuildContext context, {
    CalendarEvent? existing,
    required DateTime initialDate,
    required Future<void> Function(CalendarEvent event) onSave,
    Future<void> Function(String id)? onDelete,
    String? currentUserId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (ctx) {
        return CreateEventBottomSheet(
          existing: existing,
          initialDate: initialDate,
          onSave: onSave,
          onDelete: onDelete,
          currentUserId: currentUserId,
        );
      },
    );
  }

  @override
  State<CreateEventBottomSheet> createState() => _CreateEventBottomSheetState();
}

class _CreateEventBottomSheetState extends State<CreateEventBottomSheet> {
  static const Color _sheetBlack = Color(0xFF000000);

  late final TextEditingController _title;
  late DateTime _date;
  late TimeOfDay _time;
  late List<EventInvitee> _invitees;

  bool get _readonly =>
      widget.existing != null && !widget.existing!.isCreator(widget.currentUserId);

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    final src = widget.existing?.date ?? widget.initialDate;
    _date = DateTime(src.year, src.month, src.day);
    _time = widget.existing?.startTime ?? const TimeOfDay(hour: 9, minute: 0);
    _invitees = (widget.existing?.participantIds ?? [])
        .map((id) => EventInvitee(id: id))
        .toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_hydrateInviteeNames());
    });
  }

  Future<void> _hydrateInviteeNames() async {
    if (_invitees.isEmpty) return;
    final friends = await loadCalendarFriendContacts(widget.currentUserId);
    if (!mounted) return;
    final ids = _invitees.map((e) => e.id).toList();
    setState(() => _invitees = hydrateInviteesFromIds(ids, friends));
  }

  Future<void> _openAddFriends() async {
    if (_readonly) return;
    final friends = await loadCalendarFriendContacts(widget.currentUserId);
    if (!mounted) return;
    if (friends.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1A1A1A),
          content: Text(
            'No friends yet. Add friends in Chat first.',
            style: GoogleFonts.ptSans(color: Colors.white),
          ),
        ),
      );
      return;
    }
    final initial = _invitees.map((e) => e.id).toSet();
    final picked = await showSearch<List<EventInvitee>?>(
      context: context,
      delegate: EventFriendsPickerDelegate(
        friends: friends,
        initialSelectedIds: initial,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _invitees = picked);
    }
  }

  static const String _defaultCategory = 'Event';

  Future<void> _pickDate() async {
    if (_readonly) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      builder: (c, child) {
        return Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(
              surface: _sheetBlack,
              onSurface: Colors.white,
              primary: kPrimaryBlue,
              onPrimary: Colors.white,
            ),
            datePickerTheme: const DatePickerThemeData(
              backgroundColor: _sheetBlack,
              surfaceTintColor: Colors.transparent,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickTime() async {
    if (_readonly) return;
    final t = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (c, child) {
        return Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(
              surface: _sheetBlack,
              onSurface: Colors.white,
              primary: kPrimaryBlue,
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (t != null) setState(() => _time = t);
  }

  Future<void> _submit() async {
    if (_readonly) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1A1A1A),
          content: Text('Add a title', style: GoogleFonts.ptSans(color: Colors.white)),
        ),
      );
      return;
    }

    final e0 = widget.existing;
    final id = e0?.id ?? 'ev_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
    final createdAt = e0?.createdAt ?? DateTime.now();

    final uid = widget.currentUserId?.trim();
    final creatorId = (e0?.creatorId ?? '').trim().isNotEmpty
        ? e0!.creatorId.trim()
        : (uid != null && uid.isNotEmpty ? uid : 'local');

    final event = CalendarEvent(
      id: id,
      title: title,
      date: DateTime(_date.year, _date.month, _date.day),
      startTime: _time,
      endTime: null,
      durationMinutes: e0?.durationMinutes ?? 60,
      category: e0?.category ?? _defaultCategory,
      categoryColor: e0?.categoryColor ?? CalendarPalette.markerDot,
      isCompleted: e0?.isCompleted ?? false,
      hasReminder: e0?.hasReminder ?? false,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      creatorId: creatorId,
      participantIds: _invitees.map((e) => e.id).toList(),
      useBarOnCalendar: e0?.useBarOnCalendar ?? false,
    );
    await widget.onSave(event);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    if (_readonly) return;
    final id = widget.existing?.id;
    if (id == null || widget.onDelete == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _sheetBlack,
        surfaceTintColor: Colors.transparent,
        title: Text('Delete event?', style: GoogleFonts.ptSans(color: Colors.white, fontWeight: FontWeight.w600)),
        content: Text(
          'This cannot be undone.',
          style: GoogleFonts.ptSans(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text('Cancel', style: GoogleFonts.ptSans(color: Colors.white70))),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Delete', style: GoogleFonts.ptSans(color: Colors.redAccent, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await widget.onDelete!(id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxH = MediaQuery.sizeOf(context).height * 0.92;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Material(
          color: _sheetBlack,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        widget.existing == null
                            ? 'New event'
                            : _readonly
                                ? 'Event'
                                : 'Edit event',
                        style: GoogleFonts.ptSans(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _submit,
                        child: Text(
                          _readonly ? 'Close' : 'Save',
                          style: GoogleFonts.ptSans(
                            color: kPrimaryBlue,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AutoGrowTitleField(controller: _title, readOnly: _readonly),
                        const SizedBox(height: 28),
                        InlineDateTimeRow(
                          date: _date,
                          time: _time,
                          onPickDate: _pickDate,
                          onPickTime: _pickTime,
                          enabled: !_readonly,
                        ),
                        const SizedBox(height: 22),
                        EventInviteesSection(
                          invitees: _invitees,
                          readOnly: _readonly,
                          onAddFriends: _readonly ? null : _openAddFriends,
                          onRemove: _readonly
                              ? null
                              : (p) {
                                  setState(() {
                                    _invitees = _invitees.where((e) => e.id != p.id).toList();
                                  });
                                },
                        ),
                        if (!_readonly &&
                            widget.existing != null &&
                            widget.onDelete != null) ...[
                          const SizedBox(height: 32),
                          TextButton(
                            onPressed: _confirmDelete,
                            child: Text(
                              'Delete event',
                              style: GoogleFonts.ptSans(
                                color: Colors.redAccent.withValues(alpha: 0.95),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
