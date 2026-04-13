import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../theme/app_theme.dart';
import '../../../widgets/app_text.dart';
import '../model/login_constants.dart';

class LoginHeaderPanel extends StatelessWidget {
  const LoginHeaderPanel({
    super.key,
    required this.topPadding,
    required this.screenHeight,
  });

  final double topPadding;
  final double screenHeight;

  @override
  Widget build(BuildContext context) {
    final headerHeight = screenHeight * LoginConstants.headerHeightFraction;

    return SizedBox(
      height: headerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SvgPicture.asset(
            'assets/head-login.svg',
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              LoginConstants.headerHorizontalPadding,
              topPadding + 8,
              LoginConstants.headerHorizontalPadding,
              12,
            ),
            child: Center(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SvgPicture.asset(
                          'assets/logo.svg',
                          width: 28,
                          height: 28,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'SEALPOST',
                          style: sealpostWordmarkStyle(
                            color: Colors.white,
                            fontSize: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    AppText(
                      'Seal Your Email, Secure Your Business',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    AppText(
                      "Sealpost is an enterprise-grade email hosting platform that empowers businesses to host and manage multiple company domains on a secure, self-hosted infrastructure.",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
