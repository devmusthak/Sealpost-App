/// Display + id for an invited calendar participant (stored by [id] on [CalendarEvent.participantIds]).
class EventInvitee {
  const EventInvitee({required this.id, this.name = '', this.email = ''});

  final String id;
  final String name;
  final String email;

  String get displayName {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final e = email.trim();
    if (e.isNotEmpty) return e;
    return 'Friend';
  }

  String get initials {
    final s = displayName.trim();
    if (s.isEmpty) return '?';
    return s[0].toUpperCase();
  }
}
