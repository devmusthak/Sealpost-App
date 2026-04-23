import 'package:flutter/material.dart';

import 'chat_forward_opener.dart';
import 'view/chat_view.dart';

class ChatForwardOpenerImpl implements ChatForwardOpener {
  @override
  Future<void> openPickRecipient(
    BuildContext context,
    List<String> forwardMessageBodies,
  ) {
    // Root navigator so system back / gesture pops only this picker, not the
    // thread (or a nested stack) and the route is fully removed.
    final nav = Navigator.of(context, rootNavigator: true);
    return nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(forwardMessageBodies: forwardMessageBodies),
      ),
    );
  }
}
