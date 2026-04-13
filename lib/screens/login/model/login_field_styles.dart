import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// Input styling for login fields (model layer — no UI widgets).
abstract final class LoginFieldStyles {
  static InputDecoration inputDecoration({
    required String hint,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint.isEmpty ? null : hint,
      hintStyle: appTextStyle(
        TextStyle(color: Colors.grey.shade500, fontSize: 15),
      ),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kPrimaryBlue, width: 1.4),
      ),
      suffixIcon: suffix,
    );
  }
}
