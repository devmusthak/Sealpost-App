import 'package:shared_preferences/shared_preferences.dart';

import 'auth_session.dart';

/// Persists [AuthSession] for cold start.
class SessionStorage {
  SessionStorage(this._prefs);

  final SharedPreferences _prefs;

  static const _token = 'session_token';
  static const _userId = 'session_user_id';
  static const _email = 'session_email';
  static const _name = 'session_name';

  /// `mailto:` URIs the user closed (discard/back/send) so we do not reopen compose
  /// when the OS redelivers the same link (e.g. after WhatsApp → Sealpost).
  static const _mailtoDismissedKeys = 'mailto_dismissed_uri_keys';
  static const _maxDismissedMailtoKeys = 64;

  /// Set when compose opens from a mailto link; cleared when compose closes.
  /// If still set on next process start (hot restart / kill), we treat as dismissed.
  static const _mailtoIncompleteLaunchKey = 'mailto_incomplete_launch_key';

  static Future<SessionStorage> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SessionStorage(prefs);
  }

  Future<void> save(AuthSession session) async {
    await _prefs.setString(_token, session.token);
    await _prefs.setString(_userId, session.userId);
    await _prefs.setString(_email, session.email);
    await _prefs.setString(_name, session.name);
  }

  Future<AuthSession?> load() async {
    final token = _prefs.getString(_token);
    if (token == null || token.isEmpty) return null;
    final userId = _prefs.getString(_userId);
    final email = _prefs.getString(_email);
    final name = _prefs.getString(_name);
    if (userId == null ||
        userId.isEmpty ||
        email == null ||
        name == null) {
      return null;
    }
    return AuthSession(
      token: token,
      userId: userId,
      email: email,
      name: name,
    );
  }

  Future<void> clear() async {
    await _prefs.remove(_token);
    await _prefs.remove(_userId);
    await _prefs.remove(_email);
    await _prefs.remove(_name);
    await _prefs.remove(_mailtoDismissedKeys);
    await _prefs.remove(_mailtoIncompleteLaunchKey);
  }

  /// Keys for mailto links already handled (survives app restart).
  List<String> get dismissedMailtoUriKeys =>
      List<String>.from(_prefs.getStringList(_mailtoDismissedKeys) ?? []);

  Future<void> addDismissedMailtoUriKey(String key) async {
    final list = dismissedMailtoUriKeys;
    if (list.contains(key)) return;
    list.add(key);
    while (list.length > _maxDismissedMailtoKeys) {
      list.removeAt(0);
    }
    await _prefs.setStringList(_mailtoDismissedKeys, list);
  }

  String? get mailtoIncompleteLaunchKey =>
      _prefs.getString(_mailtoIncompleteLaunchKey);

  Future<void> setMailtoIncompleteLaunchKey(String key) async {
    await _prefs.setString(_mailtoIncompleteLaunchKey, key);
  }

  Future<void> clearMailtoIncompleteLaunchKey() async {
    await _prefs.remove(_mailtoIncompleteLaunchKey);
  }
}
