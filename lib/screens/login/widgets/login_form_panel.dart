import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../theme/app_theme.dart';
import '../../../widgets/app_text.dart';
import '../controller/login_controller.dart';
import '../model/login_constants.dart';
import '../model/login_field_styles.dart';
import 'login_labeled_field.dart';
import 'login_legal_footer.dart';

class LoginFormPanel extends StatelessWidget {
  const LoginFormPanel({
    super.key,
    required this.controller,
    required this.bottomInset,
    required this.termsTap,
    required this.dpaTap,
  });

  final LoginController controller;
  final double bottomInset;
  final TapGestureRecognizer termsTap;
  final TapGestureRecognizer dpaTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.white,
        elevation: 8,
        shadowColor: Colors.black26,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            28,
            24,
            24 + bottomInset,
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoginLabeledField(
                label: 'Email',
                child: TextField(
                  controller: controller.emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  style: appTextStyle(),
                  decoration: LoginFieldStyles.inputDecoration(
                    hint: LoginConstants.emailHint,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              LoginLabeledField(
                label: 'Password',
                child: Obx(
                  () => TextField(
                    controller: controller.passwordController,
                    obscureText: controller.obscurePassword.value,
                    style: appTextStyle(),
                    decoration: LoginFieldStyles.inputDecoration(
                      hint: LoginConstants.passwordHint,
                      suffix: IconButton(
                        onPressed: controller.togglePasswordVisibility,
                        icon: Icon(
                          controller.obscurePassword.value
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Colors.grey.shade600,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Obx(() {
                final err = controller.errorMessage.value;
                if (err == null || err.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: AppText(
                    err,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontSize: 13,
                    ),
                  ),
                );
              }),
              const SizedBox(height: 16),
              Obx(
                () => SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: controller.isLoading.value
                        ? null
                        : controller.submitLogin,
                    style: FilledButton.styleFrom(
                      backgroundColor: kPrimaryBlue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                      disabledBackgroundColor: kPrimaryBlue.withValues(alpha: 0.6),
                    ),
                    child: controller.isLoading.value
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : AppText(
                            'Log In',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              LoginLegalFooter(
                termsTap: termsTap,
                dpaTap: dpaTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
