import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists last conversation snapshot per peer (WhatsApp-style local cache).
abstract final class ChatThreadLocalStore {
  static const _subDir = 'chat_threads';
  static const _maxMessagesToPersist = 500;

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/$_subDir');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

  static String _fileName(String peerId) =>
      '${peerId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.json';

  static String _metaFileName(String peerId) =>
      '${peerId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.meta.json';

  /// Returns decoded rows + server ids, or null if missing / invalid.
  static Future<({List<Map<String, dynamic>> rows, List<String> serverIds})?> load(
    String peerId,
  ) async {
    if (peerId.isEmpty) return null;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_fileName(peerId)}');
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final ids = decoded['serverIds'];
      final msgs = decoded['messages'];
      if (msgs is! List) return null;
      final serverIds = <String>[];
      if (ids is List) {
        for (final e in ids) {
          final s = '$e'.trim();
          if (s.isNotEmpty) serverIds.add(s);
        }
      }
      final rows = <Map<String, dynamic>>[];
      for (final e in msgs) {
        if (e is Map) {
          rows.add(Map<String, dynamic>.from(e));
        }
      }
      if (rows.isEmpty) return null;
      return (rows: rows, serverIds: serverIds);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
    String peerId,
    List<Map<String, dynamic>> messageRows,
    List<String> serverIds,
  ) async {
    if (peerId.isEmpty) return;
    try {
      var rows = messageRows;
      if (rows.length > _maxMessagesToPersist) {
        rows = rows.sublist(rows.length - _maxMessagesToPersist);
      }
      final dir = await _dir();
      final f = File('${dir.path}/${_fileName(peerId)}');
      await f.writeAsString(
        jsonEncode({
          'serverIds': serverIds,
          'messages': rows,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      /* non-fatal */
    }
  }

  /// Last read server message id (anchor) for a conversation.
  static Future<String?> loadLastReadMessageId(String peerId) async {
    if (peerId.isEmpty) return null;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_metaFileName(peerId)}');
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final id = '${decoded['lastReadMessageId'] ?? ''}'.trim();
      return id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveLastReadMessageId(
    String peerId,
    String lastReadMessageId,
  ) async {
    if (peerId.isEmpty) return;
    final id = lastReadMessageId.trim();
    if (id.isEmpty) return;
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_metaFileName(peerId)}');
      await f.writeAsString(
        jsonEncode({
          'lastReadMessageId': id,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      /* non-fatal */
    }
  }
}
