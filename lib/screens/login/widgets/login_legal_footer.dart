import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

class LoginLegalFooter extends StatelessWidget {
  const LoginLegalFooter({
    super.key,
    required this.termsTap,
    required this.dpaTap,
  });

  final TapGestureRecognizer termsTap;
  final TapGestureRecognizer dpaTap;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: appTextStyle(
          TextStyle(
            color: Colors.grey.shade600,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        children: [
          const TextSpan(
            text: 'By signing in, you agree to the ',
          ),
          TextSpan(
            text: 'Terms of Service',
            style: TextStyle(
              color: kPrimaryBlue,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
            ),
            recognizer: termsTap,
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Data Processing Agreement',
            style: TextStyle(
              color: kPrimaryBlue,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
            ),
            recognizer: dpaTap,
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
