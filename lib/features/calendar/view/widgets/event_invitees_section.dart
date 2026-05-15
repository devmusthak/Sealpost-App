import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../theme/app_theme.dart';
import '../../models/event_invitee.dart';

/// “Add friends” + horizontal removable chips (create/edit), or read-only chips (view).
class EventInviteesSection extends StatelessWidget {
  const EventInviteesSection({
    super.key,
    required this.invitees,
    required this.readOnly,
    this.onAddFriends,
    this.onRemove,
  });

  final List<EventInvitee> invitees;
  final bool readOnly;
  final VoidCallback? onAddFriends;
  final ValueChanged<EventInvitee>? onRemove;

  @override
  Widget build(BuildContext context) {
    final labelStyle = GoogleFonts.ptSans(
      color: Colors.white.withValues(alpha: 0.55),
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('FRIENDS', style: labelStyle),
            const Spacer(),
            if (!readOnly && onAddFriends != null)
              TextButton.icon(
                onPressed: onAddFriends,
                icon: Icon(Icons.person_add_outlined, size: 18, color: kPrimaryBlue.withValues(alpha: 0.95)),
                label: Text(
                  'Add friends',
                  style: GoogleFonts.ptSans(
                    color: kPrimaryBlue,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        if (invitees.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(
              readOnly ? 'No invited friends' : 'Tap Add friends to invite people',
              style: GoogleFonts.ptSans(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 13,
              ),
            ),
          )
        else
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(top: 8),
              itemCount: invitees.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final p = invitees[i];
                return InputChip(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  labelPadding: const EdgeInsets.only(left: 2, right: 4),
                  avatar: CircleAvatar(
                    radius: 14,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    child: Text(
                      p.initials,
                      style: GoogleFonts.ptSans(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  label: Text(
                    p.displayName,
                    style: GoogleFonts.ptSans(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  deleteIcon: readOnly
                      ? null
                      : Icon(Icons.close_rounded, size: 16, color: Colors.white.withValues(alpha: 0.75)),
                  onDeleted: readOnly || onRemove == null ? null : () => onRemove!(p),
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              },
            ),
          ),
      ],
    );
  }
}
