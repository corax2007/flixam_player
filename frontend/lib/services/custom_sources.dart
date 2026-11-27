import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Allgemeine Erweiterung: eigene Quellen per sources.json.
/// Datei: ~/.flixam_sources.json (Pfad wird in den Einstellungen angezeigt).
class CustomSources {
  static final CustomSources instance = CustomSources._();
  static const String ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';

  static String get path =>
      '${Platform.environment['HOME'] ?? '.'}/.flixam_sources.json';

  List<dynamic>? _sources;
  CustomSources._();

  static const String template = r'''[
  {
    "name": "Beispiel-Quelle",
    "searchUrl": "https://beispiel.de/suche?q={query}",
    "itemRegex": "<a href=\"([^\"]+)\">([^<]+)</a>",
    "fields": {"url": 1, "title": 2},
    "hosterRegex": "<iframe[^>]+src=\"(https?://[^\"]+)\"",
    "useWebView": true
  }
]''';

  Future<List<dynamic>> load() async {
    if (_sources != null) return _sources!;
    final file = File(path);
    try {
      if (!file.existsSync()) {
        await file.writeAsString(template);
      }
      final data = jsonDecode(await file.readAsString());
      _sources = data is List ? data : [];
    } catch (_) {
      _sources = [];
    }
    return _sources!;
  }

  Future<void> reload() async {
    _sources = null;
    await load();
  }

  Future<http.Response?> _get(String url) async {
    try {
      return await http
          .get(Uri.parse(url), headers: {'User-Agent': ua})
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> search(String term) async {
    final sources = await load();
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < sources.length; i++) {
      final src = sources[i] as Map<String, dynamic>;
      try {
        final templateUrl = src['searchUrl']?.toString() ?? '';
        if (!templateUrl.contains('{query}')) continue;
        final url = templateUrl.replaceAll(
          '{query}',
          Uri.encodeComponent(term),
        );
        final response = await _get(url);
        if (response == null || response.statusCode != 200) continue;
        final regex = RegExp(
          src['itemRegex']?.toString() ?? '',
          dotAll: true,
        );
        final fields = (src['fields'] as Map<String, dynamic>?) ?? {};
        for (final m in regex.allMatches(response.body)) {
          String group(String key) {
            final idx = fields[key];
            if (idx == null) return '';
            final n = idx is int ? idx : int.tryParse(idx.toString()) ?? 0;
            if (n <= 0 || n > m.groupCount) return '';
            return m.group(n)?.trim() ?? '';
          }

          final detail = group('url');
          final title = group('title');
          if (detail.isEmpty || title.isEmpty) continue;
          String absolute = detail;
          if (absolute.startsWith('//')) absolute = 'https:$absolute';
          if (!absolute.startsWith('http')) {
            absolute = Uri.parse(url).resolve(absolute).toString();
          }
          out.add({
            'title': title,
            'original_language': 'de',
            'year': group('year').isEmpty ? null : group('year'),
            'poster_url': group('poster'),
            'backdrop_url': group('poster'),
            'overview': group('overview'),
            'media_type': 'movie',
            'isFolder': false,
            'source': src['name']?.toString() ?? 'Eigen',
            'url': 'custom://$i/${Uri.encodeComponent(absolute)}',
            'detail_url': absolute,
          });
        }
      } catch (_) {}
    }
    return out;
  }

  Map<String, dynamic>? sourceAt(int index) {
    final sources = _sources;
    if (sources == null || index < 0 || index >= sources.length) return null;
    return sources[index] as Map<String, dynamic>;
  }

  Future<List<String>> hosters(int index, String detailUrl) async {
    final src = sourceAt(index);
    if (src == null) return [];
    final response = await _get(detailUrl);
    if (response == null || response.statusCode != 200) return [];
    final regex = RegExp(src['hosterRegex']?.toString() ?? '', dotAll: true);
    final out = <String>[];
    for (final m in regex.allMatches(response.body)) {
      final value = m.group(1)?.trim() ?? '';
      if (value.startsWith('http') && !out.contains(value)) out.add(value);
    }
    return out;
  }
}
