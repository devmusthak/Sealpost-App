import 'package:flutter/material.dart';

/// Implemented in [ChatForwardOpenerImpl] so [chat_thread_view] can open the
/// forward picker without importing [ChatScreen] (circular import otherwise).
abstract class ChatForwardOpener {
  /// Each string is one outgoing message (already includes forwarded header lines).
  Future<void> openPickRecipient(
    BuildContext context,
    List<String> forwardMessageBodies,
  );
}
