import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../data/chat/chat_poll_message.dart';

class ChatPollCard extends StatelessWidget {
  const ChatPollCard({
    super.key,
    required this.poll,
    required this.currentUserId,
    required this.onVote,
    required this.onSeeVotes,
    required this.trailingMeta,
  });

  final ChatPollMessage poll;
  final String currentUserId;
  final ValueChanged<String> onVote;
  final VoidCallback onSeeVotes;
  final Widget trailingMeta;
  static const _actionGreen = Color(0xFF25D366);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final ended = poll.isEndedAt(now);
    final selectedId = poll.selectedOptionForUser(currentUserId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          poll.question,
          style: GoogleFonts.ptSans(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
        if (poll.visibleAnswers) ...[
          const SizedBox(height: 2),
          Text(
            'Visible Answers',
            style: GoogleFonts.ptSans(color: const Color(0xFF6BAA7D), fontSize: 12),
          ),
        ],
        const SizedBox(height: 8),
        for (final option in poll.options)
          InkWell(
            onTap: ended ? null : () => onVote(option.optionId),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    selectedId == option.optionId ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 20,
                    color: ended ? Colors.white54 : const Color(0xFFAEDFFF),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      option.text,
                      style: GoogleFonts.ptSans(color: Colors.white, fontSize: 15),
                    ),
                  ),
                  Text(
                    '${option.voteCount}',
                    style: GoogleFonts.ptSans(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (poll.visibleAnswers || ended) ...[
          const SizedBox(height: 6),
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.14),
          ),
          InkWell(
            onTap: onSeeVotes,
            splashColor: _actionGreen.withValues(alpha: 0.12),
            highlightColor: Colors.transparent,
            child: SizedBox(
              height: 48,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.open_in_new_rounded, color: _actionGreen, size: 22),
                    const SizedBox(width: 9),
                    Text(
                      'See votes',
                      style: GoogleFonts.ptSans(
                        color: _actionGreen,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        Row(
          children: [
            Text(
              '${poll.totalVotes} votes · ${poll.remainingLabel(now)}',
              style: GoogleFonts.ptSans(color: Colors.white70, fontSize: 12),
            ),
            const Spacer(),
            trailingMeta,
          ],
        ),
      ],
    );
  }
}
