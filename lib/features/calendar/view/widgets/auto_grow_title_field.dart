import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Multi-line title that grows with content (no fixed height).
class AutoGrowTitleField extends StatelessWidget {
  const AutoGrowTitleField({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final bool readOnly;

  static const double _fontSize = 26;

  @override
  Widget build(BuildContext context) {
    final base = GoogleFonts.ptSans(
      color: Colors.white,
      fontSize: _fontSize,
      fontWeight: FontWeight.w500,
      height: 1.35,
    );

    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      readOnly: readOnly,
      minLines: 1,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      cursorColor: Colors.white70,
      style: base,
      decoration: InputDecoration(
        hintText: 'Add title',
        hintStyle: GoogleFonts.ptSans(
          color: Colors.white.withValues(alpha: 0.35),
          fontSize: _fontSize,
          fontWeight: FontWeight.w500,
          height: 1.35,
        ),
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.zero,
        filled: false,
      ),
    );
  }
}
