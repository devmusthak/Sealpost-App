import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/app_branding.dart';
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
                        Image.asset(
                          'assets/logo.png',
                          width: 40,
                          height: 40,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          AppBranding.wordmark,
                          style: sealpostWordmarkStyle(
                            color: Colors.white,
                            fontSize: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    AppText(
                      'Connect Your Team, Secure Your Business',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    AppText(
                      "${AppBranding.displayName} is an enterprise-grade email and messaging platform that empowers businesses to host and manage multiple company domains on secure, self-hosted infrastructure.",
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
