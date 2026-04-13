import 'package:sealpost/data/mail/compose_prefill.dart';

/// Parses [RFC 6068](https://datatracker.ietf.org/doc/html/rfc6068) `mailto:` URIs
/// into [ComposePrefill] (To, Cc, Bcc→Cc line, Subject, Body).
ComposePrefill? composePrefillFromMailtoUri(Uri uri) {
  if (uri.scheme.toLowerCase() != 'mailto') return null;

  final to = <String>[];

  void addAddresses(String raw) {
    for (final part in raw.split(RegExp(r'[,;]'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      try {
        final decoded = Uri.decodeComponent(t);
        if (decoded.isNotEmpty && !to.contains(decoded)) {
          to.add(decoded);
        }
      } catch (_) {
        if (!to.contains(t)) to.add(t);
      }
    }
  }

  final path = uri.path;
  if (path.isNotEmpty) {
    addAddresses(path);
  }

  final qp = uri.queryParameters;
  final toParam = qp['to']?.trim();
  if (toParam != null && toParam.isNotEmpty) {
    addAddresses(toParam);
  }

  String q(String k) => (qp[k] ?? '').trim();

  final subject = q('subject');
  final body = q('body');
  final cc = q('cc');
  final bcc = q('bcc');
  final ccLine = [cc, bcc]
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join(', ');

  return ComposePrefill(
    toAddresses: to,
    ccLine: ccLine.isEmpty ? null : ccLine,
    subject: subject,
    body: body,
  );
}
