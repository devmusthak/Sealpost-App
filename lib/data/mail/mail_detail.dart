import 'mail_address.dart';
import 'mail_attachment.dart';

class MailDetail {
  const MailDetail({
    required this.id,
    this.subject,
    required this.folder,
    this.date,
    required this.from,
    required this.to,
    required this.cc,
    required this.bcc,
    this.text,
    this.html,
    this.snippet,
    required this.flagged,
    this.messageType,
    this.attachments = const [],
    this.inboxUnreadCount,
  });

  final String id;
  final String? subject;
  final String folder;
  final String? date;
  final List<MailAddress> from;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final String? text;
  final String? html;
  final String? snippet;
  final bool flagged;
  final String? messageType;
  final List<MailAttachment> attachments;

  /// Present on GET mail by id: server recomputed INBOX unseen count after open.
  final int? inboxUnreadCount;

  factory MailDetail.fromJson(Map<String, dynamic> json) {
    return MailDetail(
      id: '${json['id'] ?? ''}',
      subject: _nullableString(json['subject']),
      folder: '${json['folder'] ?? 'INBOX'}',
      date: _nullableString(json['date']),
      from: _addrList(json['from']),
      to: _addrList(json['to']),
      cc: _addrList(json['cc']),
      bcc: _addrList(json['bcc']),
      text: _nullableString(json['text']),
      html: _nullableString(json['html']),
      snippet: _nullableString(json['snippet']),
      flagged: json['flagged'] == true,
      messageType: _nullableString(json['messageType']),
      attachments: _attachmentList(json['attachments']),
      inboxUnreadCount: _optInt(json['inboxUnreadCount']),
    );
  }

  static int? _optInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  static String? _nullableString(dynamic v) {
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty ? null : s;
  }

  static List<MailAddress> _addrList(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((e) => e is Map
            ? MailAddress.fromJson(Map<String, dynamic>.from(e))
            : null)
        .whereType<MailAddress>()
        .toList();
  }

  static List<MailAttachment> _attachmentList(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((e) => e is Map
            ? MailAttachment.fromJson(Map<String, dynamic>.from(e))
            : null)
        .whereType<MailAttachment>()
        .toList();
  }
}
