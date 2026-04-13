class MailListItem {
  const MailListItem({
    required this.id,
    required this.subject,
    required this.snippet,
    required this.date,
    required this.fromName,
    this.fromAddress,
    required this.flagged,
    this.messageType,
  });

  final String id;
  final String? subject;
  final String snippet;
  final String? date;
  final String fromName;
  final String? fromAddress;
  final bool flagged;
  final String? messageType;

  /// Placeholder row for [Skeletonizer]; real text is replaced by animated bones.
  factory MailListItem.skeletonSeed(int index) {
    return MailListItem(
      id: '__sk__$index',
      subject: 'Loading subject goes here',
      snippet:
          'Loading message preview text that spans enough lines for the skeleton',
      date: DateTime.now().toIso8601String(),
      fromName: 'Sender name',
      flagged: false,
    );
  }

  factory MailListItem.fromJson(Map<String, dynamic> json) {
    final fromName = _string(json['fromName']);
    return MailListItem(
      id: _string(json['id']),
      subject: _nullableString(json['subject']),
      snippet: _string(json['snippet']),
      date: _nullableString(json['date']),
      fromName: fromName.isEmpty ? 'Unknown' : fromName,
      fromAddress: _nullableString(json['fromAddress']),
      flagged: _bool(json['flagged']),
      messageType: _nullableString(json['messageType']),
    );
  }

  static String _string(dynamic v) => v == null ? '' : '$v';

  static String? _nullableString(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty ? null : s;
  }

  static bool _bool(dynamic v) {
    if (v is bool) return v;
    if (v == 1 || v == '1') return true;
    return false;
  }
}
