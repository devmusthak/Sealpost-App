import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

/// Open-graph / meta preview for a single URL (cached globally).
@immutable
class LinkPreviewData {
  const LinkPreviewData({
    required this.url,
    required this.domain,
    this.title,
    this.description,
    this.imageUrl,
    this.minimal = false,
  });

  final String url;
  final String domain;
  final String? title;
  final String? description;
  final String? imageUrl;
  final bool minimal;
}

/// Fetches HTML and extracts OG / Twitter / basic meta. Results are cached and de-duped in-flight.
class LinkPreviewService {
  LinkPreviewService._();

  static final LinkPreviewService instance = LinkPreviewService._();

  static final RegExp _urlPattern = RegExp(
    r'https?://[^\s<>\[\]()]+',
    caseSensitive: false,
  );

  /// Hostname-shaped token without scheme (e.g. `google.com`, `www.google.com/path`).
  static final RegExp _bareHostPattern = RegExp(
    r'\b(?:www\.)?(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,})'
    r'(?::\d+)?(?:[/?#][^\s<>\[\]()]*)?',
    caseSensitive: false,
  );

  /// Two-label bare matches like `notes.txt` — skip; real hosts like `google.com` stay allowed.
  static const Set<String> _blockedBareTlds = <String>{
    'txt', 'pdf', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico',
    'zip', 'rar', '7z', 'tar', 'gz',
    'mp3', 'mp4', 'wav', 'm4a', 'mov', 'avi', 'mkv', 'webm',
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods',
    'csv', 'json', 'xml', 'html', 'htm', 'css', 'js', 'mjs', 'ts', 'tsx',
    'md', 'rtf', 'log',
  };

  static const int _maxCacheEntries = 120;
  static const int _maxHtmlChars = 500000;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      followRedirects: true,
      maxRedirects: 6,
      responseType: ResponseType.plain,
      // Do not throw on 404/403/etc.; [_fetchAndParse] maps those to a minimal preview.
      validateStatus: (s) => s != null && s < 600,
      headers: <String, dynamic>{
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 Sealpost',
      },
    ),
  );

  final Map<String, LinkPreviewData> _cache = HashMap<String, LinkPreviewData>();
  final ListQueue<String> _cacheOrder = ListQueue<String>();
  final Map<String, Future<LinkPreviewData>> _inflight =
      HashMap<String, Future<LinkPreviewData>>();

  /// First valid `http`/`https` URL in [text], or `null`.
  ///
  /// Recognizes explicit `http(s)://` URLs and bare hosts (`google.com`, `www.google.com/...`),
  /// normalizing the latter to `https://…` for preview.
  static String? extractFirstHttpUrl(String text) {
    if (text.trim().isEmpty) return null;
    for (final m in _urlPattern.allMatches(text)) {
      var raw = m.group(0);
      if (raw == null || raw.isEmpty) continue;
      raw = _trimTrailingUrlNoise(raw);
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      if (uri.host.isEmpty) continue;
      return uri.toString();
    }
    for (final m in _bareHostPattern.allMatches(text)) {
      if (m.start > 0 && text[m.start - 1] == '@') {
        continue;
      }
      var raw = m.group(0);
      if (raw == null || raw.isEmpty) continue;
      raw = _trimTrailingUrlNoise(raw);
      final prefixed = 'https://$raw';
      final uri = Uri.tryParse(prefixed);
      if (uri == null) continue;
      if (uri.scheme != 'https' || uri.host.isEmpty) continue;
      if (_shouldSkipBareHostPreview(uri)) continue;
      return uri.toString();
    }
    return null;
  }

  static bool _shouldSkipBareHostPreview(Uri uri) {
    final labels = uri.host.toLowerCase().split('.');
    if (labels.length < 2) return true;
    final tld = labels.last;
    if (labels.length == 2 && _blockedBareTlds.contains(tld)) return true;
    return false;
  }

  static String _trimTrailingUrlNoise(String s) {
    var t = s;
    while (t.isNotEmpty) {
      final last = t[t.length - 1];
      if (last == ')' || last == ']' || last == '}' || last == '>' || last == '"' || last == "'") {
        t = t.substring(0, t.length - 1);
        continue;
      }
      if ('.,;:!'.contains(last)) {
        t = t.substring(0, t.length - 1);
        continue;
      }
      break;
    }
    return t;
  }

  static String cacheKeyForUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !u.hasScheme) return url;
    final host = u.host.toLowerCase();
    return u.replace(host: host, fragment: '').toString();
  }

  /// Cached result only; synchronous. Used to avoid skeleton flicker on rebuild.
  LinkPreviewData? peek(String url) => _cache[cacheKeyForUrl(url)];

  Future<LinkPreviewData> get(String url) {
    final key = cacheKeyForUrl(url);
    final hit = _cache[key];
    if (hit != null) return Future<LinkPreviewData>.value(hit);

    final pending = _inflight[key];
    if (pending != null) return pending;

    final fut = _load(key).whenComplete(() {
      _inflight.remove(key);
    });
    _inflight[key] = fut;
    return fut;
  }

  Future<LinkPreviewData> _load(String key) async {
    try {
      final data = await _fetchAndParse(key);
      _remember(key, data);
      return data;
    } catch (e) {
      // Timeouts / offline; 404 is handled in [_fetchAndParse] without throwing.
      if (kDebugMode) {
        debugPrint('LinkPreviewService: $e');
      }
      final fallback = _minimal(key);
      _remember(key, fallback);
      return fallback;
    }
  }

  void _remember(String key, LinkPreviewData data) {
    if (_cache.containsKey(key)) {
      _cache[key] = data;
      return;
    }
    while (_cache.length >= _maxCacheEntries && _cacheOrder.isNotEmpty) {
      final old = _cacheOrder.removeFirst();
      _cache.remove(old);
    }
    _cache[key] = data;
    _cacheOrder.addLast(key);
  }

  LinkPreviewData _minimal(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? url;
    return LinkPreviewData(
      url: url,
      domain: host,
      title: url,
      description: null,
      imageUrl: null,
      minimal: true,
    );
  }

  Future<LinkPreviewData> _fetchAndParse(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return _minimal(url);
    }

    final res = await _dio.get<String>(url);
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 400) {
      return _minimal(url);
    }

    var html = res.data ?? '';
    if (html.length > _maxHtmlChars) {
      html = html.substring(0, _maxHtmlChars);
    }

    final doc = html_parser.parse(html);
    final baseUri = Uri.parse(url);

    String? metaProperty(String prop) {
      final el =
          doc.querySelector('meta[property="$prop"]') ??
          doc.querySelector('meta[property=\'$prop\']');
      return el?.attributes['content']?.trim();
    }

    String? metaName(String name) {
      final el =
          doc.querySelector('meta[name="$name"]') ??
          doc.querySelector('meta[name=\'$name\']');
      return el?.attributes['content']?.trim();
    }

    String? ogTitle = metaProperty('og:title');
    String? twTitle = metaName('twitter:title');
    final titleEl = doc.querySelector('title')?.text.trim();
    var title = (ogTitle ?? twTitle ?? titleEl ?? '').trim();
    if (title.isEmpty) title = uri.host;

    String? ogDesc = metaProperty('og:description');
    String? twDesc = metaName('twitter:description');
    String? metaDesc = metaName('description');
    final description = (ogDesc ?? twDesc ?? metaDesc ?? '').trim();
    final descriptionOrNull = description.isEmpty ? null : description;

    String? rawImg =
        metaProperty('og:image') ??
        metaName('twitter:image') ??
        metaName('twitter:image:src');
    String? imageUrl;
    if (rawImg != null && rawImg.isNotEmpty) {
      try {
        final resolved = baseUri.resolve(rawImg.trim());
        if (resolved.scheme == 'http' || resolved.scheme == 'https') {
          imageUrl = resolved.toString();
        }
      } catch (_) {}
    }

    final domain = uri.host;
    final hasAnyRich =
        (title != uri.host && title != url) ||
        (descriptionOrNull != null && descriptionOrNull.isNotEmpty) ||
        imageUrl != null;

    return LinkPreviewData(
      url: url,
      domain: domain,
      title: title,
      description: descriptionOrNull,
      imageUrl: imageUrl,
      minimal: !hasAnyRich,
    );
  }
}
