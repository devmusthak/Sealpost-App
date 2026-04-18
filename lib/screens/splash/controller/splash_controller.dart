import 'package:get/get.dart';

import '../../../data/auth/auth_repository.dart';
import '../../login/view/login_view.dart';
import '../../navigation/view/main_navigation_view.dart';
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
      await repo.syncPresenceForActiveSession();
      Get.off(
        () => const MainNavigationScreen(),
        transition: Transition.fadeIn,
        duration: SplashConstants.routeTransition,
      );
    } else {
      navigateToLogin();
    }
  }
}
