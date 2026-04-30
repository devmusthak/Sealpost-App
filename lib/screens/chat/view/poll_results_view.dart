import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/chat/chat_poll_message.dart';

class PollResultsScreen extends StatelessWidget {
  const PollResultsScreen({
    super.key,
    required this.poll,
    this.showEdit = false,
    this.onEdit,
  });

  final ChatPollMessage poll;
  final bool showEdit;
  final Future<void> Function()? onEdit;
  static const _bg = Colors.black;
  static const _card = Color(0xFF111B21);
  static const _stroke = Color(0xFF24343D);
  static const _text = Color(0xFFE9EDEF);
  static const _muted = Color(0xFF8A9BA8);
  static const _accent = Color(0xFF25D366);

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<ChatPollVote>>{};
    final nowUtc = DateTime.now().toUtc();
    final canShowNames = poll.visibleAnswers || poll.isEndedAt(nowUtc);
    for (final vote in poll.votes) {
      grouped.putIfAbsent(vote.optionId, () => <ChatPollVote>[]).add(vote);
    }
    final children = <Widget>[
      Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _stroke),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              poll.question,
              style: GoogleFonts.ptSans(
                color: _text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${poll.totalVotes} total votes  •  ${poll.remainingLabel(nowUtc)}',
              style: GoogleFonts.ptSans(color: _muted, fontSize: 12.5),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];

    for (final option in poll.options) {
      final cardChildren = <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                option.text,
                style: GoogleFonts.ptSans(
                  color: _text,
                  fontWeight: FontWeight.w700,
                  fontSize: 15.5,
                ),
              ),
            ),
            Text(
              '${option.voteCount} vote',
              style: GoogleFonts.ptSans(
                color: _accent,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: poll.totalVotes == 0 ? 0 : (option.voteCount / poll.totalVotes),
          minHeight: 5,
          borderRadius: BorderRadius.circular(999),
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          valueColor: const AlwaysStoppedAnimation<Color>(_accent),
        ),
      ];

      if (canShowNames) {
        cardChildren.add(const SizedBox(height: 8));
        final voters = grouped[option.optionId] ?? const <ChatPollVote>[];
        for (final v in voters) {
          cardChildren.add(
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF1F2C34),
                child: Text(
                  (v.userName.isNotEmpty ? v.userName[0] : 'U').toUpperCase(),
                  style: GoogleFonts.ptSans(
                    color: _text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              title: Text(
                v.userName.isNotEmpty ? v.userName : (v.userId == poll.createdBy ? 'You' : 'Member'),
                style: GoogleFonts.ptSans(color: _text),
              ),
              subtitle: Text(
                v.votedAtUtc.toLocal().toString().substring(0, 16),
                style: GoogleFonts.ptSans(color: _muted, fontSize: 12),
              ),
            ),
          );
        }
      } else {
        cardChildren.add(
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Voter names hidden',
              style: GoogleFonts.ptSans(color: _muted, fontSize: 12),
            ),
          ),
        );
      }

      children.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _stroke),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(children: cardChildren),
        ),
      );
    }

    if (poll.options.isEmpty) {
      children.add(
        Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _stroke),
          ),
          padding: const EdgeInsets.all(16),
          child: Text('No options found', style: GoogleFonts.ptSans(color: _muted)),
        ),
      );
    }
    children.add(const SizedBox(height: 4));
    if (!canShowNames) {
      children.add(
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _stroke),
          ),
          child: Row(
            children: [
              const Icon(Icons.visibility_off_rounded, color: _muted, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Votes are hidden until poll ends.',
                  style: GoogleFonts.ptSans(color: _muted, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _text),
        title: Text(
          'Poll Results',
          style: GoogleFonts.ptSans(color: _text, fontWeight: FontWeight.w700),
        ),
        actions: [
          if (showEdit && onEdit != null)
            IconButton(
              tooltip: 'Edit poll',
              onPressed: () => onEdit!.call(),
              icon: const Icon(Icons.edit_rounded, color: _text),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
        children: children,
      ),
    );
  }
}
