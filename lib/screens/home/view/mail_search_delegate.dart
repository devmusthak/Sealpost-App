import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/mail/mail_list_item.dart';
import '../../../widgets/app_text.dart';
import '../controller/home_controller.dart';

/// Full-screen mail search (current folder): debounced queries against the API `q` param.
class MailSearchDelegate extends SearchDelegate<MailListItem?> {
  MailSearchDelegate({required this.controller})
      : super(
          searchFieldLabel: 'Search mail',
          textInputAction: TextInputAction.search,
        );

  final HomeController controller;

  static const _overlay = Color(0xFF121212);
  static const _surface = Color(0xFF202124);

  @override
  ThemeData appBarTheme(BuildContext context) {
    return ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: _overlay,
      appBarTheme: const AppBarTheme(
        backgroundColor: _surface,
        foregroundColor: Color(0xFFE8EAED),
        elevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: Color(0xFF9AA0A6)),
        border: InputBorder.none,
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    if (query.isEmpty) return const [];
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
          showSuggestions(context);
        },
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) {
      return _emptyHint();
    }
    return _MailSearchResults(delegate: this, searchQuery: query);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.trim().isEmpty) {
      return _emptyHint();
    }
    return _MailSearchResults(delegate: this, searchQuery: query);
  }

  Widget _emptyHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Search subject, sender, or message in this folder',
          style: GoogleFonts.ptSans(
            color: Colors.white54,
            fontSize: 15,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _MailSearchResults extends StatefulWidget {
  const _MailSearchResults({
    required this.delegate,
    required this.searchQuery,
  });

  final MailSearchDelegate delegate;
  /// Snapshot of [SearchDelegate.query] for this build so [State.didUpdateWidget] can detect edits.
  final String searchQuery;

  @override
  State<_MailSearchResults> createState() => _MailSearchResultsState();
}

class _MailSearchResultsState extends State<_MailSearchResults> {
  Timer? _debounce;
  Future<List<MailListItem>>? _future;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _MailSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery) {
      _schedule();
    }
  }

  void _schedule() {
    final q = widget.searchQuery.trim();
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() => _future = null);
      return;
    }
    setState(() => _future = null);
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      if (widget.searchQuery.trim() != q) return;
      setState(() {
        _future = widget.delegate.controller.searchMailsInFolder(q);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.searchQuery.trim();
    if (q.isEmpty) {
      return const SizedBox.shrink();
    }
    final fut = _future;
    if (fut == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return FutureBuilder<List<MailListItem>>(
      future: fut,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not search: ${snapshot.error}',
                style: GoogleFonts.ptSans(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        final items = snapshot.data ?? [];
        if (items.isEmpty) {
          return Center(
            child: Text(
              'No messages found',
              style: GoogleFonts.ptSans(color: Colors.white54),
            ),
          );
        }
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (context, _) =>
              const Divider(height: 1, color: Color(0xFF3C4043)),
          itemBuilder: (context, index) {
            final item = items[index];
            return _SearchMailRow(
              item: item,
              index: index,
              onTap: () => widget.delegate.close(context, item),
            );
          },
        );
      },
    );
  }
}

class _SearchMailRow extends StatelessWidget {
  const _SearchMailRow({
    required this.item,
    required this.index,
    required this.onTap,
  });

  final MailListItem item;
  final int index;
  final VoidCallback onTap;

  static const _avatars = [
    Color(0xFF7C4DFF),
    Color(0xFF448AFF),
    Color(0xFF26A69A),
    Color(0xFFFFA726),
    Color(0xFFEC407A),
  ];

  @override
  Widget build(BuildContext context) {
    final letter = _firstInitial(
      item.fromName.isNotEmpty ? item.fromName : '?',
    );
    final avatarColor = _avatars[index % _avatars.length];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: avatarColor,
                child: Text(
                  letter,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      item.fromName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      item.subject ?? '(No subject)',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      item.snippet,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 13,
                        height: 1.25,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatShortDate(item.date),
                    style: GoogleFonts.ptSans(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Icon(
                    item.flagged ? Icons.star : Icons.star_border,
                    size: 20,
                    color: Colors.white38,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _firstInitial(String s) {
  final t = s.trim();
  if (t.isEmpty) return '?';
  return t[0].toUpperCase();
}

const _monthsShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatShortDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  return '${_monthsShort[d.month - 1]} ${d.day}';
}
