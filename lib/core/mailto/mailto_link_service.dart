import 'dart:async';

import 'package:get/get.dart';
import 'package:sealpost/data/mail/compose_prefill.dart';
import 'package:sealpost/data/session/session_storage.dart';

import 'mailto_normalization.dart';
import 'mailto_uri_parser.dart';

/// Payload when opening compose from a `mailto:` deep link (prefill + original URI).
class MailtoComposeOpen {
  const MailtoComposeOpen({
    required this.prefill,
    required this.sourceUri,
  });

  final ComposePrefill prefill;
  final Uri sourceUri;
}

/// Holds a [ComposePrefill] from an incoming `mailto:` link until [HomeScreen] opens compose.
///
/// After the user leaves compose opened from that link, the same URI is **consumed** and
/// **persisted** so Android/iOS redelivering the same intent after a new process start
/// (common after WhatsApp → Sealpost) does not open compose again.
class MailtoLinkService extends GetxController {
  MailtoLinkService(this._session);

  final SessionStorage _session;

  final Rxn<ComposePrefill> pending = Rxn<ComposePrefill>();

  Uri? _pendingSourceUri;
  final Set<String> _consumedMailtoKeys = {};

  @override
  void onInit() {
    super.onInit();
    _hydrateConsumedKeysFromPrefs();

    final abandoned = _session.mailtoIncompleteLaunchKey;
    if (abandoned != null && abandoned.isNotEmpty) {
      // Compose was open when the process died / hot restart — clear marker only.
      // Do NOT persist as dismissed: the user may tap the same mailto again on purpose.
      unawaited(_session.clearMailtoIncompleteLaunchKey());
    }
  }

  void _hydrateConsumedKeysFromPrefs() {
    for (final raw in _session.dismissedMailtoUriKeys) {
      _consumedMailtoKeys.add(raw);
      final u = Uri.tryParse(raw);
      if (u != null && u.scheme.toLowerCase() == 'mailto') {
        _consumedMailtoKeys.add(canonicalMailtoUriKey(u));
      }
    }
  }

  static String _mailtoKey(Uri uri) => canonicalMailtoUriKey(uri);

  /// Call when [ComposeScreen] opens from a mailto (deep link or in-app tap).
  void markComposeOpenedFromMailto(Uri uri) {
    unawaited(_session.setMailtoIncompleteLaunchKey(_mailtoKey(uri)));
  }

  /// [fromExternalTap] is true when the OS delivers a new VIEW intent (e.g. user tapped
  /// a mailto link in WhatsApp). Those must open compose even if the same address was
  /// previously dismissed — only [getInitialLink] stale redelivery stays blocked.
  void ingestUri(Uri uri, {bool fromExternalTap = false}) {
    if (uri.scheme.toLowerCase() != 'mailto') return;
    final key = _mailtoKey(uri);
    if (!fromExternalTap && _consumedMailtoKeys.contains(key)) return;

    final prefill = composePrefillFromMailtoUri(uri);
    if (prefill == null) return;

    _pendingSourceUri = uri;
    pending.value = prefill;
  }

  /// Clears pending without opening compose (e.g. explicit cancel).
  void clearPending() {
    pending.value = null;
    _pendingSourceUri = null;
  }

  /// Call when compose opened from [uri] is closed (discard, send, or back).
  void consumeMailtoSource(Uri uri) {
    final key = _mailtoKey(uri);
    _consumedMailtoKeys.add(key);
    unawaited(_session.addDismissedMailtoUriKey(key));
    unawaited(_session.clearMailtoIncompleteLaunchKey());
    pending.value = null;
    if (_pendingSourceUri != null &&
        _mailtoKey(_pendingSourceUri!) == _mailtoKey(uri)) {
      _pendingSourceUri = null;
    }
  }

  MailtoComposeOpen? takePendingMailto() {
    final p = pending.value;
    final src = _pendingSourceUri;
    pending.value = null;
    _pendingSourceUri = null;
    if (p == null || src == null) return null;
    return MailtoComposeOpen(prefill: p, sourceUri: src);
  }
}
