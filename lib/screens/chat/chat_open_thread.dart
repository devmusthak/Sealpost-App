import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../data/chat/chat_contact.dart';
import 'view/chat_thread_view.dart';

/// Opens [ChatThreadScreen] without importing this module from [chat_view.dart]
/// (avoids a circular import: view ↔ thread).
void openChatThread(
  BuildContext context,
  ChatContact contact, {
  List<String>? forwardBodies,
  List<SharedMediaFile>? shareMediaOnOpen,
}) {
  final filtered = forwardBodies
      ?.map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final hasForward = filtered != null && filtered.isNotEmpty;
  final shareFiltered = shareMediaOnOpen == null || shareMediaOnOpen.isEmpty
      ? null
      : List<SharedMediaFile>.from(shareMediaOnOpen);
  final hasShare = shareFiltered != null && shareFiltered.isNotEmpty;
  final page = ChatThreadScreen(
    contact: contact,
    forwardMessagesOnOpen: hasForward ? filtered : null,
    shareMediaOnOpen: hasShare ? shareFiltered : null,
  );
  final nav = Navigator.of(context);
  if (hasForward) {
    nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => page));
  } else {
    nav.push<void>(MaterialPageRoute<void>(builder: (_) => page));
  }
}
