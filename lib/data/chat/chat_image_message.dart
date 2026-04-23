import 'dart:convert';

/// Wire format matches server `ChatController` image envelope (`t` === `img`).
class ChatImageItem {
  const ChatImageItem({
    required this.hash,
    required this.sizeBytes,
    required this.url,
    this.localPath,
    this.status,
    this.progress = 0,
  });

  final String hash;
  final int sizeBytes;
  final String url;

  /// Sender-only: local file path before upload completes.
  final String? localPath;

  /// `pending` | `uploading` | `done` | `failed` — client-only, stripped for API.
  final String? status;
  final double progress;

  ChatImageItem copyWith({
    String? hash,
    int? sizeBytes,
    String? url,
    String? localPath,
    String? status,
    double? progress,
  }) {
    return ChatImageItem(
      hash: hash ?? this.hash,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      url: url ?? this.url,
      localPath: localPath ?? this.localPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
    );
  }

  Map<String, dynamic> toJson({bool forServer = false}) {
    final m = <String, dynamic>{'h': hash, 's': sizeBytes, 'u': url};
    if (!forServer) {
      if (localPath != null && localPath!.isNotEmpty) m['lp'] = localPath;
      if (status != null && status!.isNotEmpty) m['st'] = status;
      if (progress > 0 && progress < 1) m['p'] = progress;
    }
    return m;
  }

  static ChatImageItem? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final h = '${m['h'] ?? ''}'.trim().toLowerCase();
    final u = '${m['u'] ?? ''}'.trim();
    final s = int.tryParse('${m['s'] ?? 0}') ?? 0;
    final lp = '${m['lp'] ?? ''}'.trim();
    final st = '${m['st'] ?? ''}'.trim();
    final p = (m['p'] is num)
        ? (m['p'] as num).toDouble()
        : double.tryParse('${m['p'] ?? 0}') ?? 0.0;
    return ChatImageItem(
      hash: h,
      sizeBytes: s,
      url: u,
      localPath: lp.isEmpty ? null : lp,
      status: st.isEmpty ? null : st,
      progress: p.clamp(0.0, 1.0),
    );
  }
}

class ChatImageMessage {
  const ChatImageMessage({required this.caption, required this.items});

  final String caption;
  final List<ChatImageItem> items;

  ChatImageMessage copyWith({String? caption, List<ChatImageItem>? items}) {
    return ChatImageMessage(
      caption: caption ?? this.caption,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson({bool forServer = false}) {
    return {
      'v': 1,
      't': 'img',
      'c': caption,
      'i': items.map((e) => e.toJson(forServer: forServer)).toList(),
    };
  }

  String encode({bool forServer = false}) =>
      jsonEncode(toJson(forServer: forServer));

  static ChatImageMessage? tryParse(String body) {
    final t = body.trim();
    if (!t.startsWith('{')) return null;
    try {
      final m = jsonDecode(t);
      if (m is! Map) return null;
      final map = Map<String, dynamic>.from(m);
      if (map['t'] != 'img') return null;
      final itemsRaw = map['i'];
      if (itemsRaw is! List) return null;
      final items = <ChatImageItem>[];
      for (final e in itemsRaw) {
        final it = ChatImageItem.fromJson(e);
        if (it != null) items.add(it);
      }
      if (items.isEmpty) return null;
      return ChatImageMessage(caption: '${map['c'] ?? ''}', items: items);
    } catch (_) {
      return null;
    }
  }
}

/// Wire format: `t` === `vid`, exactly one entry in `i` (same shape as [ChatImageItem]).
class ChatVideoMessage {
  const ChatVideoMessage({required this.caption, required this.item});

  final String caption;
  final ChatImageItem item;

  ChatVideoMessage copyWith({String? caption, ChatImageItem? item}) {
    return ChatVideoMessage(
      caption: caption ?? this.caption,
      item: item ?? this.item,
    );
  }

  Map<String, dynamic> toJson({bool forServer = false}) {
    return {
      'v': 1,
      't': 'vid',
      'c': caption,
      'i': [item.toJson(forServer: forServer)],
    };
  }

  String encode({bool forServer = false}) =>
      jsonEncode(toJson(forServer: forServer));

  static ChatVideoMessage? tryParse(String body) {
    final t = body.trim();
    if (!t.startsWith('{')) return null;
    try {
      final m = jsonDecode(t);
      if (m is! Map) return null;
      final map = Map<String, dynamic>.from(m);
      if (map['t'] != 'vid') return null;
      final itemsRaw = map['i'];
      if (itemsRaw is! List || itemsRaw.length != 1) return null;
      final it = ChatImageItem.fromJson(itemsRaw.single);
      if (it == null) return null;
      return ChatVideoMessage(caption: '${map['c'] ?? ''}', item: it);
    } catch (_) {
      return null;
    }
  }
}

/// Wire format: `t` === `voc` for voice-note messages.
class ChatVoiceMessage {
  const ChatVoiceMessage({
    required this.hash,
    required this.sizeBytes,
    required this.url,
    required this.durationMs,
    required this.waveform,
    this.localPath,
    this.status,
    this.progress = 0,
    this.playedByPeer = false,
    this.playedAtIso,
  });

  final String hash;
  final int sizeBytes;
  final String url;
  final int durationMs;
  final List<int> waveform;
  final String? localPath;
  final String? status;
  final double progress;
  final bool playedByPeer;
  final String? playedAtIso;

  ChatVoiceMessage copyWith({
    String? hash,
    int? sizeBytes,
    String? url,
    int? durationMs,
    List<int>? waveform,
    String? localPath,
    String? status,
    double? progress,
    bool? playedByPeer,
    String? playedAtIso,
  }) {
    return ChatVoiceMessage(
      hash: hash ?? this.hash,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      url: url ?? this.url,
      durationMs: durationMs ?? this.durationMs,
      waveform: waveform ?? this.waveform,
      localPath: localPath ?? this.localPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      playedByPeer: playedByPeer ?? this.playedByPeer,
      playedAtIso: playedAtIso ?? this.playedAtIso,
    );
  }

  Map<String, dynamic> toJson({bool forServer = false}) {
    final m = <String, dynamic>{
      'v': 1,
      't': 'voc',
      'h': hash,
      's': sizeBytes,
      'u': url,
      'd': durationMs,
      'w': waveform,
    };
    if (playedByPeer) {
      m['pb'] = true;
      if (playedAtIso != null && playedAtIso!.isNotEmpty) {
        m['pt'] = playedAtIso;
      }
    }
    if (!forServer) {
      if (localPath != null && localPath!.isNotEmpty) m['lp'] = localPath;
      if (status != null && status!.isNotEmpty) m['st'] = status;
      if (progress > 0 && progress < 1) m['p'] = progress;
    }
    return m;
  }

  String encode({bool forServer = false}) =>
      jsonEncode(toJson(forServer: forServer));

  static ChatVoiceMessage? tryParse(String body) {
    final t = body.trim();
    if (!t.startsWith('{')) return null;
    try {
      final m = jsonDecode(t);
      if (m is! Map) return null;
      final map = Map<String, dynamic>.from(m);
      if (map['t'] != 'voc') return null;
      final h = '${map['h'] ?? ''}'.trim().toLowerCase();
      final u = '${map['u'] ?? ''}'.trim();
      final s = int.tryParse('${map['s'] ?? 0}') ?? 0;
      final d = int.tryParse('${map['d'] ?? 0}') ?? 0;
      final lp = '${map['lp'] ?? ''}'.trim();
      final st = '${map['st'] ?? ''}'.trim();
      final p = (map['p'] is num)
          ? (map['p'] as num).toDouble()
          : double.tryParse('${map['p'] ?? 0}') ?? 0.0;
      final wfRaw = map['w'];
      final wf = <int>[];
      if (wfRaw is List) {
        for (final e in wfRaw) {
          final v = int.tryParse('$e') ?? 0;
          wf.add(v.clamp(0, 100));
        }
      }
      final pb = map['pb'] == true;
      final pt = '${map['pt'] ?? ''}'.trim();
      return ChatVoiceMessage(
        hash: h,
        sizeBytes: s,
        url: u,
        durationMs: d,
        waveform: wf,
        localPath: lp.isEmpty ? null : lp,
        status: st.isEmpty ? null : st,
        progress: p.clamp(0.0, 1.0),
        playedByPeer: pb,
        playedAtIso: pt.isEmpty ? null : pt,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Wire format: `t` === `doc` for chat document attachments.
class ChatDocumentMessage {
  const ChatDocumentMessage({
    required this.hash,
    required this.sizeBytes,
    required this.url,
    required this.name,
    required this.ext,
    this.mimeType,
    this.pages,
    this.localPath,
    this.status,
    this.progress = 0,
  });

  final String hash;
  final int sizeBytes;
  final String url;
  final String name;
  final String ext;
  final String? mimeType;
  final int? pages;
  final String? localPath;
  final String? status;
  final double progress;

  bool get isPdf =>
      ext.toLowerCase() == 'pdf' || (mimeType ?? '').contains('pdf');

  ChatDocumentMessage copyWith({
    String? hash,
    int? sizeBytes,
    String? url,
    String? name,
    String? ext,
    String? mimeType,
    int? pages,
    String? localPath,
    String? status,
    double? progress,
  }) {
    return ChatDocumentMessage(
      hash: hash ?? this.hash,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      url: url ?? this.url,
      name: name ?? this.name,
      ext: ext ?? this.ext,
      mimeType: mimeType ?? this.mimeType,
      pages: pages ?? this.pages,
      localPath: localPath ?? this.localPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
    );
  }

  Map<String, dynamic> toJson({bool forServer = false}) {
    final m = <String, dynamic>{
      'v': 1,
      't': 'doc',
      'h': hash,
      's': sizeBytes,
      'u': url,
      'n': name,
      'e': ext,
      if (mimeType != null && mimeType!.isNotEmpty) 'mt': mimeType,
      if (pages != null && pages! > 0) 'pg': pages,
    };
    if (!forServer) {
      if (localPath != null && localPath!.isNotEmpty) m['lp'] = localPath;
      if (status != null && status!.isNotEmpty) m['st'] = status;
      if (progress > 0 && progress < 1) m['p'] = progress;
    }
    return m;
  }

  String encode({bool forServer = false}) =>
      jsonEncode(toJson(forServer: forServer));

  static ChatDocumentMessage? tryParse(String body) {
    final t = body.trim();
    if (!t.startsWith('{')) return null;
    try {
      final m = jsonDecode(t);
      if (m is! Map) return null;
      final map = Map<String, dynamic>.from(m);
      if (map['t'] != 'doc') return null;
      final h = '${map['h'] ?? ''}'.trim().toLowerCase();
      final u = '${map['u'] ?? ''}'.trim();
      final n = '${map['n'] ?? ''}'.trim();
      final e = '${map['e'] ?? ''}'.trim().toLowerCase();
      final s = int.tryParse('${map['s'] ?? 0}') ?? 0;
      final mt = '${map['mt'] ?? ''}'.trim();
      final pg = int.tryParse('${map['pg'] ?? ''}');
      final lp = '${map['lp'] ?? ''}'.trim();
      final st = '${map['st'] ?? ''}'.trim();
      final p = (map['p'] is num)
          ? (map['p'] as num).toDouble()
          : double.tryParse('${map['p'] ?? 0}') ?? 0.0;
      if (n.isEmpty) return null;
      return ChatDocumentMessage(
        hash: h,
        sizeBytes: s,
        url: u,
        name: n,
        ext: e,
        mimeType: mt.isEmpty ? null : mt,
        pages: pg,
        localPath: lp.isEmpty ? null : lp,
        status: st.isEmpty ? null : st,
        progress: p.clamp(0.0, 1.0),
      );
    } catch (_) {
      return null;
    }
  }
}
