/// Stable key for the same logical `mailto:` link (encoding / query order tolerant).
String canonicalMailtoUriKey(Uri uri) {
  if (uri.scheme.toLowerCase() != 'mailto') {
    return uri.toString();
  }
  var path = uri.path;
  try {
    path = Uri.decodeComponent(path);
  } catch (_) {
    /* keep raw path */
  }
  final params = Map<String, String>.from(uri.queryParameters);
  final sortedKeys = params.keys.toList()..sort();
  final q = sortedKeys
      .map((k) => '$k=${Uri.encodeQueryComponent(params[k] ?? '')}')
      .join('&');
  return 'mailto:$path${q.isEmpty ? '' : '?$q'}';
}
