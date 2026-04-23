import 'dart:async';

import 'package:get/get.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Holds media shared into the app from the OS share sheet until the user
/// picks a chat and [clearPending] runs after handoff to [ChatThreadScreen].
class ShareReceiveService extends GetxService {
  final Rxn<List<SharedMediaFile>> pending = Rxn<List<SharedMediaFile>>();
  StreamSubscription<List<SharedMediaFile>>? _sub;

  @override
  void onInit() {
    super.onInit();
    _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (list) {
        if (list.isNotEmpty) {
          pending.value = list;
        }
      },
      onError: (_) {},
    );
    unawaited(_loadInitial());
  }

  Future<void> _loadInitial() async {
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isNotEmpty) {
        pending.value = initial;
      }
    } catch (_) {}
  }

  Future<void> clearPending() async {
    pending.value = null;
    try {
      await ReceiveSharingIntent.instance.reset();
    } catch (_) {}
  }

  @override
  void onClose() {
    _sub?.cancel();
    super.onClose();
  }
}
