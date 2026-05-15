import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/app_theme.dart';
import '../models/calendar_event.dart';
import '../models/event_invitee.dart';
import 'widgets/auto_grow_title_field.dart';
import 'widgets/calendar_palette.dart';
import 'widgets/event_friends_picker_delegate.dart';
import 'widgets/event_invitees_section.dart';
import 'widgets/inline_date_time_row.dart';

/// Full-screen create flow (add button); same fields as the previous create bottom sheet.
class CreateEventScreen extends StatefulWidget {
  const CreateEventScreen({
    super.key,
    required this.initialDate,
    required this.onSave,
    this.currentUserId,
  });

  final DateTime initialDate;
  final Future<void> Function(CalendarEvent event) onSave;
  final String? currentUserId;

  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends State<CreateEventScreen> {
  static const Color _bg = Color(0xFF000000);
  static const String _defaultCategory = 'Event';

  late final TextEditingController _title;
  late DateTime _date;
  late TimeOfDay _time;
  final List<EventInvitee> _invitees = [];

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    final d = widget.initialDate;
    _date = DateTime(d.year, d.month, d.day);
    _time = const TimeOfDay(hour: 9, minute: 0);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
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
              surface: _bg,
              onSurface: Colors.white,
              primary: kPrimaryBlue,
              onPrimary: Colors.white,
            ),
            datePickerTheme: const DatePickerThemeData(
              backgroundColor: _bg,
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
    final t = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (c, child) {
        return Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(
              surface: _bg,
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

  Future<void> _openAddFriends() async {
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
      setState(() {
        _invitees
          ..clear()
          ..addAll(picked);
      });
    }
  }

  Future<void> _save() async {
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

    final uid = widget.currentUserId?.trim();
    final creatorId = uid != null && uid.isNotEmpty ? uid : 'local';

    final event = CalendarEvent(
      id: 'ev_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}',
      title: title,
      date: DateTime(_date.year, _date.month, _date.day),
      startTime: _time,
      endTime: null,
      durationMinutes: 60,
      category: _defaultCategory,
      categoryColor: CalendarPalette.markerDot,
      isCompleted: false,
      hasReminder: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      creatorId: creatorId,
      participantIds: _invitees.map((e) => e.id).toList(),
      useBarOnCalendar: false,
    );
    await widget.onSave(event);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'New event',
          style: GoogleFonts.ptSans(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              'Save',
              style: GoogleFonts.ptSans(
                color: kPrimaryBlue,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AutoGrowTitleField(controller: _title),
              const SizedBox(height: 28),
              InlineDateTimeRow(
                date: _date,
                time: _time,
                onPickDate: _pickDate,
                onPickTime: _pickTime,
              ),
              const SizedBox(height: 22),
              EventInviteesSection(
                invitees: _invitees,
                readOnly: false,
                onAddFriends: _openAddFriends,
                onRemove: (p) {
                  setState(() => _invitees.removeWhere((e) => e.id == p.id));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
