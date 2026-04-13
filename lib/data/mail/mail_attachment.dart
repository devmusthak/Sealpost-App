class MailAttachment {
  const MailAttachment({
    this.filename,
    this.contentType,
    required this.size,
    this.contentId,
    this.dataBase64,
  });

  final String? filename;
  final String? contentType;
  final int size;
  final String? contentId;
  /// Raw bytes as base64 when stored in MongoDB (BinData).
  final String? dataBase64;

  bool get hasInlineData =>
      dataBase64 != null && dataBase64!.trim().isNotEmpty;

  String get displayName {
    final n = filename?.trim();
    if (n != null && n.isNotEmpty) return n;
    return 'Attachment';
  }

  factory MailAttachment.fromJson(Map<String, dynamic> json) {
    return MailAttachment(
      filename: _nullableString(json['filename']),
      contentType: _nullableString(json['contentType']),
      size: _int(json['size']),
      contentId: _nullableString(json['contentId']),
      dataBase64: _nullableString(json['dataBase64']),
    );
  }

  static String? _nullableString(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty ? null : s;
  }

  static int _int(dynamic v) {
    if (v is int) return v < 0 ? 0 : v;
    if (v is double) return v < 0 ? 0 : v.floor();
    return int.tryParse('$v') ?? 0;
  }
}
