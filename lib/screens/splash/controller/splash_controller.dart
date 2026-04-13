import 'package:get/get.dart';

import '../../../data/auth/auth_repository.dart';
import '../../home/view/home_view.dart';
import '../../login/view/login_view.dart';
import '../model/splash_constants.dart';

/// Splash → home (restored session) or login.
class SplashController extends GetxController {
  void navigateToLogin() {
    Get.off(
      () => const LoginScreen(),
      transition: Transition.fadeIn,
      duration: SplashConstants.routeTransition,
    );
  }

  Future<void> navigateAfterSplash() async {
    final repo = Get.find<AuthRepository>();
    final restored = await repo.restoreSession();
    if (restored) {
      Get.off(
        () => const HomeScreen(),
        transition: Transition.fadeIn,
        duration: SplashConstants.routeTransition,
      );
    } else {
      navigateToLogin();
    }
  }
}
