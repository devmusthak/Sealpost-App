import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../../data/mail/mail_detail.dart';
import '../../../data/mail/mail_list_item.dart';
import '../../../data/mail/mail_repository.dart';
import '../../home/controller/home_controller.dart';

class MailDetailController extends GetxController {
  MailDetailController({
    required this.mailId,
    required this.preview,
    required this.folderLabel,
  });

  final String mailId;
  final MailListItem preview;
  /// Raw folder id from home (e.g. `INBOX`).
  final String folderLabel;

  final detail = Rxn<MailDetail>();
  final isLoading = true.obs;
  final RxnString errorMessage = RxnString();

  @override
  void onInit() {
    super.onInit();
    _load();
  }

  Future<void> retry() async {
    isLoading.value = true;
    errorMessage.value = null;
    await _load();
  }

  Future<void> _load() async {
    try {
      final d = await Get.find<MailRepository>().fetchMailById(mailId);
      detail.value = d;
      final synced = d.inboxUnreadCount;
      if (synced != null && Get.isRegistered<HomeController>()) {
        Get.find<HomeController>().setInboxUnreadCount(synced);
      }
      errorMessage.value = null;
    } on DioException catch (e) {
      errorMessage.value = e.message ?? 'Could not load message';
    } catch (e) {
      errorMessage.value = '$e';
    } finally {
      isLoading.value = false;
    }
  }

  /// Returns `null` on success, or an error string for the UI.
  Future<String?> deleteMail() async {
    try {
      await Get.find<MailRepository>().deleteMail(mailId);
      return null;
    } on DioException catch (e) {
      return e.message ?? 'Could not delete message';
    } catch (e) {
      return '$e';
    }
  }
}
