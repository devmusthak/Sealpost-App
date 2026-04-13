import 'package:flutter/material.dart';

import '../../../legal/terms_of_service_content.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_text.dart';
import '../model/terms_meta.dart';

class TermsOfServiceView extends StatelessWidget {
  const TermsOfServiceView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AppText(
          TermsMeta.screenTitle,
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
          kTermsOfServiceFullText,
          style: appTextStyle(
            const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ),
    );
  }
}
