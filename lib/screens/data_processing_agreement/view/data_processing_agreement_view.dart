import 'package:flutter/material.dart';

import '../../../legal/data_processing_content.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_text.dart';
import '../model/dpa_meta.dart';

class DataProcessingAgreementView extends StatelessWidget {
  const DataProcessingAgreementView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: AppText(
          DpaMeta.screenTitle,
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
          kDataProcessingAgreementFullText,
          style: appTextStyle(
            const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ),
    );
  }
}
