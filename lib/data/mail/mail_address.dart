class MailAddress {
  const MailAddress({this.name, this.address});

  final String? name;
  final String? address;

  factory MailAddress.fromJson(Map<String, dynamic> json) {
    return MailAddress(
      name: _nullable(json['name']),
      address: _nullable(json['address']),
    );
  }

  static String? _nullable(dynamic v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  String get displayName {
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) return n;
    return address?.trim() ?? 'Unknown';
  }

  String get displayLine {
    final n = name?.trim() ?? '';
    final a = address?.trim() ?? '';
    if (n.isNotEmpty && a.isNotEmpty && n != a) return '$n <$a>';
    if (a.isNotEmpty) return a;
    return n.isNotEmpty ? n : 'Unknown';
  }
}
