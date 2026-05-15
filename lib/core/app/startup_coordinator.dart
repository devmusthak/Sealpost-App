import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Ensures [MainNavigationScreen] opens only after heavy services are registered.
class StartupCoordinator extends GetxService {
  Completer<void>? _heavy;
  bool _started = false;

  /// Runs [run] once; safe to call multiple times (waits for the first run).
  Future<void> beginHeavyIfNeeded(Future<void> Function() run) async {
    if (_started) {
      final h = _heavy;
      if (h != null) await h.future;
      return;
    }
    _started = true;
    _heavy = Completer<void>();
    try {
      await run();
    } catch (e, st) {
      assert(() {
        FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st));
        return true;
      }());
    } finally {
      final h = _heavy;
      if (h != null && !h.isCompleted) {
        h.complete();
      }
    }
  }

  /// Await before navigating to the main shell (logged-in users only).
  Future<void> get awaitHeavyReady async {
    final h = _heavy;
    if (h == null) return;
    await h.future;
  }
}
