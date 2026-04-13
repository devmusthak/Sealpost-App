/// Seeds [ComposeScreen] from reply / forward / `mailto:` deep links.
class ComposePrefill {
  const ComposePrefill({
    this.toAddresses = const [],
    this.ccLine,
    required this.subject,
    required this.body,
  });

  final List<String> toAddresses;
  final String? ccLine;
  final String subject;
  final String body;
}
