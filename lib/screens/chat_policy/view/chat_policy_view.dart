import 'package:flutter/material.dart';

import '../../../legal/chat_policy_content.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_text.dart';

class ChatPolicyView extends StatelessWidget {
  const ChatPolicyView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppText(
          'Chat Policy',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: SelectableText(
          kChatPolicyFullText,
          style: appTextStyle(
            const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ),
    );
  }
}
