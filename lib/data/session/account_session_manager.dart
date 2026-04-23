import 'package:get/get.dart';

import '../../screens/chat/controller/chat_controller.dart';
import '../../screens/home/controller/home_controller.dart';
import '../../screens/navigation/view/main_navigation_view.dart';
import '../auth/auth_repository.dart';
import 'session_storage.dart';

class AccountSessionManager extends GetxService {
  final accounts = <SessionAccountIdentity>[].obs;
  final activeAccountId = RxnString();
  final isSwitching = false.obs;

  Future<AccountSessionManager> init() async {
    await refresh();
    return this;
  }

  Future<void> refresh() async {
    final auth = Get.find<AuthRepository>();
    final list = await auth.loadAccountIdentities();
    accounts.assignAll(list);
    activeAccountId.value = auth.activeAccountId;
  }

  Future<bool> switchToAccount(String accountId) async {
    if (isSwitching.value) return false;
    isSwitching.value = true;
    try {
      final auth = Get.find<AuthRepository>();
      final ok = await auth.switchAccount(accountId);
      if (!ok) return false;
      await auth.syncPresenceForActiveSession();
      await refresh();
      _resetScopedControllers();
      Get.offAll(() => const MainNavigationScreen());
      return true;
    } finally {
      isSwitching.value = false;
    }
  }

  void _resetScopedControllers() {
    if (Get.isRegistered<HomeController>()) {
      Get.delete<HomeController>(force: true);
    }
    if (Get.isRegistered<ChatController>()) {
      Get.delete<ChatController>(force: true);
    }
  }
}
