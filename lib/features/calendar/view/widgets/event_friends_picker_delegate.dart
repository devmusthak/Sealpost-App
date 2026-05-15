import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../data/chat/chat_contact.dart';
import '../../../../data/chat/chat_repository.dart';
import '../../../../theme/app_theme.dart';
import '../../models/event_invitee.dart';

/// Loads direct friends (excludes current user) for invite flows.
Future<List<ChatContact>> loadCalendarFriendContacts(String? currentUserId) async {
  if (!Get.isRegistered<ChatRepository>()) return const [];
  try {
    final raw = await Get.find<ChatRepository>().fetchContacts();
    final uid = currentUserId?.trim() ?? '';
    return raw
        .where(
          (c) =>
              !c.isGroupConversation &&
              c.relationStatus.trim().toLowerCase() == 'friends' &&
              (uid.isEmpty || c.id != uid),
        )
        .toList();
  } catch (_) {
    return const [];
  }
}

List<EventInvitee> hydrateInviteesFromIds(List<String> ids, List<ChatContact> contacts) {
  final byId = {for (final c in contacts) c.id: c};
  return ids
      .map((id) {
        final c = byId[id];
        if (c == null) return EventInvitee(id: id);
        return EventInvitee(id: c.id, name: c.name, email: c.email);
      })
      .toList();
}

/// Multi-select friends; **Done** returns selected [EventInvitee]s, back returns `null`.
class EventFriendsPickerDelegate extends SearchDelegate<List<EventInvitee>?> {
  EventFriendsPickerDelegate({
    required this.friends,
    required Set<String> initialSelectedIds,
  }) : _selected = {...initialSelectedIds};

  final List<ChatContact> friends;
  final Set<String> _selected;

  @override
  String get searchFieldLabel => 'Friends';

  @override
  TextStyle? get searchFieldStyle => GoogleFonts.ptSans(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w400,
      );

  @override
  ThemeData appBarTheme(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF000000),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000000),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: GoogleFonts.ptSans(color: const Color(0xFF9AA0A6)),
        border: InputBorder.none,
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      TextButton(
        onPressed: () {
          final list = friends
              .where((f) => _selected.contains(f.id))
              .map(
                (c) => EventInvitee(
                  id: c.id,
                  name: c.name,
                  email: c.email,
                ),
              )
              .toList();
          close(context, list);
        },
        child: Text(
          'Done',
          style: GoogleFonts.ptSans(
            color: kPrimaryBlue,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _body(context);

  @override
  Widget buildSuggestions(BuildContext context) => _body(context);

  Widget _body(BuildContext context) {
    final sorted = List<ChatContact>.from(friends)
      ..sort((a, b) {
        final an = (a.name.isNotEmpty ? a.name : a.email).toLowerCase();
        final bn = (b.name.isNotEmpty ? b.name : b.email).toLowerCase();
        return an.compareTo(bn);
      });
    final q = query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? sorted
        : sorted.where((c) {
            return c.name.toLowerCase().contains(q) || c.email.toLowerCase().contains(q);
          }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          q.isEmpty ? 'No friends yet. Add friends in Chat.' : 'No matching friends',
          textAlign: TextAlign.center,
          style: GoogleFonts.ptSans(
            color: Colors.white.withValues(alpha: 0.68),
            fontSize: 14,
          ),
        ),
      );
    }

    return StatefulBuilder(
      builder: (context, setPickerState) {
        return ListView.separated(
          itemCount: filtered.length,
          separatorBuilder: (_, _) => Divider(
            color: Colors.white.withValues(alpha: 0.08),
            height: 1,
          ),
          itemBuilder: (context, index) {
            final c = filtered[index];
            final checked = _selected.contains(c.id);
            final initial = (c.name.isNotEmpty ? c.name : c.email).trim();
            final letter = initial.isEmpty ? '?' : initial[0].toUpperCase();
            return CheckboxListTile(
              value: checked,
              onChanged: (_) {
                if (checked) {
                  _selected.remove(c.id);
                } else {
                  _selected.add(c.id);
                }
                setPickerState(() {});
              },
              controlAffinity: ListTileControlAffinity.leading,
              checkboxShape: const CircleBorder(),
              side: const BorderSide(color: Colors.white38, width: 1.5),
              activeColor: kPrimaryBlue,
              secondary: CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFF375DFB).withValues(alpha: 0.92),
                child: Text(
                  letter,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              title: Text(
                c.name.isEmpty ? c.email : c.name,
                style: GoogleFonts.ptSans(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                c.email,
                style: GoogleFonts.ptSans(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
