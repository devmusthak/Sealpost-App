/// Layout and copy constants for the login feature.
abstract final class LoginConstants {
  static const double headerHeightFraction = 0.35;
  static const double headerHorizontalPadding = 24;
  static const String emailHint = 'mail@sealpost.com';
  static const String passwordHint = 'Enter your password';

  /// Sent on login until Firebase Auth supplies a real UID (`''` clears stored uid server-side).
  static const String firebaseUidPlaceholder = '';

  /// Basic shape check (local@domain.tld); not a full RFC parser.
  static bool looksLikeEmail(String email) {
    final t = email.trim();
    if (t.isEmpty) return false;
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(t);
  }
}
