import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/chat/chat_repository.dart';
import '../../../data/chat/chat_user.dart';

class ChatSearchDelegate extends SearchDelegate<ChatUser?> {
  ChatSearchDelegate({
    required this.repo,
    required this.onUserTap,
  });

  final ChatRepository repo;
  final Future<void> Function(ChatUser user) onUserTap;

  @override
  String get searchFieldLabel => 'Search in chats';

  @override
  TextStyle? get searchFieldStyle => GoogleFonts.ptSans(
    color: Colors.white,
    fontSize: 16,
    fontWeight: FontWeight.w400,
  );

  @override
  ThemeData appBarTheme(BuildContext context) {
    final base = Theme.of(context);
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF000000),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000000),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: GoogleFonts.ptSans(color: const Color(0xFF9AA0A6)),
        border: InputBorder.none,
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear_rounded),
          onPressed: () => query = '',
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildSearchBody();

  @override
  Widget buildSuggestions(BuildContext context) => _buildSearchBody();

  Widget _buildSearchBody() {
    final q = query.trim();
    if (q.isEmpty) {
      return _centerText('Type a keyword to search chats');
    }
    return FutureBuilder<List<ChatUser>>(
      future: repo.searchUsersByEmail(q),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snap.hasError) {
          return _centerText('Could not search users');
        }
        final users = snap.data ?? const <ChatUser>[];
        if (users.isEmpty) {
          return _centerText('No users found');
        }
        return ListView.separated(
          itemCount: users.length,
          separatorBuilder: (_, _) => Divider(
            color: Colors.white.withValues(alpha: 0.08),
            height: 1,
          ),
          itemBuilder: (context, index) {
            final user = users[index];
            final initial = _firstInitial(user.name.isNotEmpty ? user.name : user.email);
            return ListTile(
              onTap: () async {
                close(context, user);
                await onUserTap(user);
              },
              leading: CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFF375DFB).withValues(alpha: 0.92),
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              title: Text(
                user.name.isEmpty ? user.email : user.name,
                style: GoogleFonts.ptSans(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                user.email,
                style: GoogleFonts.ptSans(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _centerText(String text) {
    return Center(
      child: Text(
        text,
        style: GoogleFonts.ptSans(
          color: Colors.white.withValues(alpha: 0.68),
          fontSize: 14,
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
