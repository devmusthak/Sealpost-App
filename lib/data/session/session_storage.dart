import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_session.dart';

/// Persists [AuthSession] for cold start.
class SessionStorage {
  SessionStorage(this._prefs);

  final SharedPreferences _prefs;
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const _token = 'session_token';
  static const _userId = 'session_user_id';
  static const _email = 'session_email';
  static const _name = 'session_name';
  static const _activeAccountId = 'session_active_account_id';
  static const _accountsSecureKey = 'session_accounts_secure_v1';

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
    final accountId = session.userId.trim();
    final accounts = await _loadAllAccounts();
    final now = DateTime.now().toUtc().toIso8601String();
    final updated = _StoredSessionAccount(
      accountId: accountId,
      token: session.token,
      userId: session.userId,
      email: session.email,
      name: session.name,
      updatedAt: now,
    );
    final next = <_StoredSessionAccount>[
      updated,
      ...accounts.where((a) => a.accountId != accountId),
    ];
    await _writeAccounts(next);
    await _prefs.setString(_activeAccountId, accountId);

    // Keep legacy keys for backward compatibility with old code paths.
    await _prefs.setString(_token, session.token);
    await _prefs.setString(_userId, session.userId);
    await _prefs.setString(_email, session.email);
    await _prefs.setString(_name, session.name);
  }

  Future<AuthSession?> load() async {
    final activeId = _prefs.getString(_activeAccountId);
    if (activeId != null && activeId.isNotEmpty) {
      final loaded = await loadByAccountId(activeId);
      if (loaded != null) return loaded;
    }

    // Legacy migration fallback (old single-session storage).
    final token = _prefs.getString(_token);
    final userId = _prefs.getString(_userId);
    final email = _prefs.getString(_email);
    final name = _prefs.getString(_name);
    if (token == null ||
        token.isEmpty ||
        userId == null ||
        userId.isEmpty ||
        email == null ||
        name == null) {
      return null;
    }
    final session = AuthSession(
      token: token,
      userId: userId,
      email: email,
      name: name,
    );
    await save(session);
    return session;
  }

  Future<AuthSession?> loadByAccountId(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return null;
    final accounts = await _loadAllAccounts();
    for (final account in accounts) {
      if (account.accountId == id) {
        return AuthSession(
          token: account.token,
          userId: account.userId,
          email: account.email,
          name: account.name,
        );
      }
    }
    return null;
  }

  Future<List<SessionAccountIdentity>> loadAccountIdentities() async {
    final accounts = await _loadAllAccounts();
    return accounts
        .map(
          (a) => SessionAccountIdentity(
            accountId: a.accountId,
            userId: a.userId,
            email: a.email,
            name: a.name,
            updatedAt: a.updatedAt,
          ),
        )
        .toList();
  }

  String? get activeAccountId {
    final id = _prefs.getString(_activeAccountId);
    if (id == null || id.trim().isEmpty) return null;
    return id.trim();
  }

  Future<bool> switchActiveAccount(String accountId) async {
    final id = accountId.trim();
    if (id.isEmpty) return false;
    final next = await loadByAccountId(id);
    if (next == null) return false;
    await _prefs.setString(_activeAccountId, id);
    await _prefs.setString(_token, next.token);
    await _prefs.setString(_userId, next.userId);
    await _prefs.setString(_email, next.email);
    await _prefs.setString(_name, next.name);
    return true;
  }

  Future<void> clear() async {
    await _secure.delete(key: _accountsSecureKey);
    await _prefs.remove(_activeAccountId);
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

  Future<List<_StoredSessionAccount>> _loadAllAccounts() async {
    try {
      final raw = await _secure.read(key: _accountsSecureKey);
      if (raw == null || raw.isEmpty) return <_StoredSessionAccount>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <_StoredSessionAccount>[];
      final out = <_StoredSessionAccount>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final account = _StoredSessionAccount.fromJson(m);
        if (account != null) out.add(account);
      }
      return out;
    } catch (_) {
      return <_StoredSessionAccount>[];
    }
  }

  Future<void> _writeAccounts(List<_StoredSessionAccount> accounts) async {
    final payload = accounts.map((a) => a.toJson()).toList();
    await _secure.write(key: _accountsSecureKey, value: jsonEncode(payload));
  }
}

class SessionAccountIdentity {
  const SessionAccountIdentity({
    required this.accountId,
    required this.userId,
    required this.email,
    required this.name,
    required this.updatedAt,
  });

  final String accountId;
  final String userId;
  final String email;
  final String name;
  final String updatedAt;
}

class _StoredSessionAccount {
  const _StoredSessionAccount({
    required this.accountId,
    required this.token,
    required this.userId,
    required this.email,
    required this.name,
    required this.updatedAt,
  });

  final String accountId;
  final String token;
  final String userId;
  final String email;
  final String name;
  final String updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'token': token,
      'userId': userId,
      'email': email,
      'name': name,
      'updatedAt': updatedAt,
    };
  }

  static _StoredSessionAccount? fromJson(Map<String, dynamic> json) {
    final accountId = '${json['accountId'] ?? ''}'.trim();
    final token = '${json['token'] ?? ''}'.trim();
    final userId = '${json['userId'] ?? ''}'.trim();
    final email = '${json['email'] ?? ''}'.trim();
    final name = '${json['name'] ?? ''}'.trim();
    final updatedAt = '${json['updatedAt'] ?? ''}'.trim();
    if (accountId.isEmpty ||
        token.isEmpty ||
        userId.isEmpty ||
        email.isEmpty ||
        name.isEmpty) {
      return null;
    }
    return _StoredSessionAccount(
      accountId: accountId,
      token: token,
      userId: userId,
      email: email,
      name: name,
      updatedAt: updatedAt,
    );
  }
}
