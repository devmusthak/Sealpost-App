import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/app/startup_coordinator.dart';
import '../../../data/auth/auth_exception.dart';
import '../../../data/auth/auth_repository.dart';
import '../../navigation/view/main_navigation_view.dart';
import '../model/login_constants.dart';

/// Login form state + API (GetX).
class LoginController extends GetxController {
  LoginController({this.addAccountMode = false});

  final bool addAccountMode;

  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  final obscurePassword = true.obs;
  final isLoading = false.obs;
  final errorMessage = RxnString();

  void togglePasswordVisibility() {
    obscurePassword.toggle();
  }

  Future<void> submitLogin() async {
    errorMessage.value = null;
    final email = emailController.text.trim();
    final password = passwordController.text;
    if (email.isEmpty) {
      errorMessage.value = 'Please enter your email';
      return;
    }
    if (!LoginConstants.looksLikeEmail(email)) {
      errorMessage.value = 'Enter a valid email address';
      return;
    }
    if (password.isEmpty) {
      errorMessage.value = 'Please enter your password';
      return;
    }

    isLoading.value = true;
    try {
      final repo = Get.find<AuthRepository>();
      await repo.login(
        email: email,
        password: password,
        firebaseUid: LoginConstants.firebaseUidPlaceholder,
      );
      await repo.syncPresenceForActiveSession();
      if (Get.isRegistered<StartupCoordinator>()) {
        await Get.find<StartupCoordinator>().awaitHeavyReady;
      }
      if (addAccountMode) {
        Get.offAll(() => const MainNavigationScreen());
      } else {
        Get.off(() => const MainNavigationScreen());
      }
    } on AuthException catch (e) {
      errorMessage.value = e.message;
      if (e.retryAfterSeconds != null) {
        Get.snackbar(
          'Account locked',
          'Try again in ${e.retryAfterSeconds} seconds.',
        );
      }
    } catch (_) {
      errorMessage.value = 'Something went wrong';
    } finally {
      isLoading.value = false;
    }
  }

  @override
  void onClose() {
    emailController.dispose();
    passwordController.dispose();
    super.onClose();
  }
}
