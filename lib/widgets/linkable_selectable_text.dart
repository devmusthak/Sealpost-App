import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:linkify/linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/mailto/mailto_uri_parser.dart';
import '../data/auth/auth_repository.dart';
import '../screens/compose/view/compose_view.dart';
import '../theme/app_theme.dart';

/// Plain [text] with tappable URLs, emails, and phone numbers (opens dialer / browser).
class LinkableSelectableText extends StatefulWidget {
  const LinkableSelectableText({
    super.key,
    required this.text,
    required this.style,
    this.linkStyle,
    this.onEmailTap,
  });

  final String text;
  final TextStyle style;
  final TextStyle? linkStyle;
  final Future<void> Function(String email)? onEmailTap;

  @override
  State<LinkableSelectableText> createState() =>
      _LinkableSelectableTextState();
}

class _LinkableSelectableTextState extends State<LinkableSelectableText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Uri? _uriForLaunch(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('tel:')) {
      var n = trimmed.substring(4).trim();
      n = n.replaceAll(RegExp(r'[\s()/]'), '');
      n = n.replaceAll('-', '');
      if (n.isEmpty) return null;
      return Uri.parse('tel:$n');
    }
    return Uri.tryParse(trimmed);
  }

  Future<void> _open(BuildContext context, String url) async {
    final uri = _uriForLaunch(url);
    if (uri == null) return;
    if (uri.scheme.toLowerCase() == 'mailto') {
      final mail = uri.path.trim();
      if (mail.isNotEmpty && widget.onEmailTap != null) {
        await widget.onEmailTap!(mail);
        return;
      }
      final authed = Get.isRegistered<AuthRepository>() &&
          (Get.find<AuthRepository>().accessToken?.isNotEmpty ?? false);
      if (authed) {
        final prefill = composePrefillFromMailtoUri(uri);
        if (prefill != null && context.mounted) {
          await Get.to<void>(
            () => ComposeScreen(
              prefill: prefill,
              mailtoSourceUri: uri,
            ),
          );
          return;
        }
      }
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();

    final linkStyle = widget.linkStyle ??
        widget.style.copyWith(
          color: kPrimaryBlue,
          decoration: TextDecoration.underline,
          decorationColor: kPrimaryBlue,
        );

    final elements = linkify(
      widget.text,
      options: const LinkifyOptions(
        humanize: false,
        excludeLastPeriod: true,
      ),
      linkifiers: const [
        UrlLinkifier(),
        EmailLinkifier(),
        PhoneNumberLinkifier(),
      ],
    );

    final children = <TextSpan>[];
    for (final e in elements) {
      if (e is TextElement) {
        children.add(TextSpan(text: e.text, style: widget.style));
      } else if (e is LinkableElement) {
        final url = e.url;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => unawaited(_open(context, url));
        _recognizers.add(recognizer);
        children.add(
          TextSpan(
            text: e.text,
            style: linkStyle,
            recognizer: recognizer,
          ),
        );
      }
    }

    return SelectableText.rich(
      TextSpan(children: children),
      style: widget.style,
    );
  }
}
