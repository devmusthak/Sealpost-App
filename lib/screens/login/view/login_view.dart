import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controller/login_controller.dart';
import '../../terms_of_service/view/terms_of_service_view.dart';
import '../../data_processing_agreement/view/data_processing_agreement_view.dart';
import '../widgets/login_form_panel.dart';
import '../widgets/login_header_panel.dart';

/// Login screen (view). Uses [LoginController] for state.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.addAccountMode = false});

  final bool addAccountMode;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final LoginController _login;
  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _dpaTap;

  @override
  void initState() {
    super.initState();
    _login = Get.put(LoginController(addAccountMode: widget.addAccountMode));
    _termsTap = TapGestureRecognizer()
      ..onTap = () => Get.to(() => const TermsOfServiceView());
    _dpaTap = TapGestureRecognizer()
      ..onTap = () => Get.to(() => const DataProcessingAgreementView());
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _dpaTap.dispose();
    Get.delete<LoginController>();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final screenHeight = MediaQuery.sizeOf(context).height;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.white,
        resizeToAvoidBottomInset: true,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LoginHeaderPanel(
              topPadding: padding.top,
              screenHeight: screenHeight,
            ),
            LoginFormPanel(
              controller: _login,
              bottomInset: padding.bottom,
              termsTap: _termsTap,
              dpaTap: _dpaTap,
            ),
          ],
        ),
      ),
    );
  }
}
