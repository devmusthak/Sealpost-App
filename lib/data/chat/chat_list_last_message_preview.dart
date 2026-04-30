import 'chat_contact.dart';
import 'chat_image_message.dart';
import 'chat_poll_message.dart';

/// Same prefixes as [chat_thread_view] `_ForwardedPayloadParse` (wire format).
const _kForwardPrefix = '» Forwarded\n\n';

/// After API [shortenChatPreview], newlines become spaces — match `» Forwarded {` too.
final _kForwardPrefixFlexible = RegExp(r'^»\s*Forwarded\s*');

final _kLegacyForwardHeader = RegExp(
  r'^---------- Forwarded message ----------\n(?:\[[^\]]*\]\n)?',
);

/// Peels every `» Forwarded` layer (re-forward chains) before parsing JSON/caption.
(String inner, bool hadForward) _peelAllForwardPrefixes(String trimmed) {
  var s = trimmed;
  var had = false;
  while (true) {
    if (s.startsWith(_kForwardPrefix)) {
      s = s.substring(_kForwardPrefix.length).trim();
      had = true;
      continue;
    }
    final flex = _kForwardPrefixFlexible.firstMatch(s);
    if (flex != null && flex.start == 0) {
      s = s.substring(flex.end).trim();
      had = true;
      continue;
    }
    final m = _kLegacyForwardHeader.firstMatch(s);
    if (m != null) {
      s = s.substring(m.end).trim();
      had = true;
      continue;
    }
    break;
  }
  return (s, had);
}

/// One line for chat home rows — never raw `{ "v": 1, "t": "img", ... }`.
String chatListLastMessagePreview(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';

  final peeled = _peelAllForwardPrefixes(trimmed);
  var inner = peeled.$1;
  final forwarded = peeled.$2;

  if (forwarded && inner.isEmpty) {
    return 'Forwarded';
  }

  String labelForPayload(String payload) {
    final p = payload.trim();
    if (p.isEmpty) return '';
    final img = ChatImageMessage.tryParse(p);
    if (img != null) {
      final cap = img.caption.trim();
      if (cap.isNotEmpty) {
        return _truncate(cap, 160);
      }
      final n = img.items.length;
      return n > 1 ? '$n photos' : 'Photo';
    }
    final vid = ChatVideoMessage.tryParse(p);
    if (vid != null) {
      final cap = vid.caption.trim();
      if (cap.isNotEmpty) {
        return _truncate(cap, 160);
      }
      return 'Video';
    }
    final voc = ChatVoiceMessage.tryParse(p);
    if (voc != null) {
      return 'Voice message';
    }
    final doc = ChatDocumentMessage.tryParse(p);
    if (doc != null) {
      return doc.isPdf ? 'PDF' : 'Document';
    }
    final poll = ChatPollMessage.tryParse(p);
    if (poll != null) {
      return _truncate(poll.question, 160);
    }
    if (p.startsWith('{') && p.contains('"t"')) {
      return 'Attachment';
    }
    return p;
  }

  final label = labelForPayload(inner);
  if (forwarded) {
    if (label == inner) {
      return 'Forwarded · ${_truncate(inner, 160)}';
    }
    return 'Forwarded · $label';
  }
  if (label != inner) {
    return label;
  }
  return _truncate(inner, 160);
}

String _truncate(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, max - 1)}…';
}

extension ChatContactChatListPreview on ChatContact {
  /// Last message line on chat home (readable; not raw media JSON).
  String get chatListSubtitle => chatListLastMessagePreview(lastMessage);
}
