import 'dart:convert';
import 'package:http/http.dart' as http;

/// Backend-freier Scraper für netzkino: GraphQL liefert direkte MP4-URLs.
class NetzkinoService {
  static final NetzkinoService instance = NetzkinoService._();
  static const String _graphql = 'https://data.netzkino.de/netzkino/graphql';
  static const String _streamBase = 'https://pmd.netzkino-seite.netzkino.de/';

  NetzkinoService._();

  String _streamUrl(String pmd) {
    final path = pmd.split('/').map(Uri.encodeComponent).join('/');
    return '$_streamBase$path';
  }

  String _escape(String value) => value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  Future<List<Map<String, dynamic>>> search(String term) async {
    if (term.trim().isEmpty) return [];
    final query =
        '{ allCmsMovies(filter: {title: {includesInsensitive: "${_escape(term)}"}}, first: 60) '
        '{ nodes { title slug productionYear videoSource { pmdUrl } coverImage { masterUrl } } } }';
    try {
      final r = await http
          .post(
            Uri.parse(_graphql),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query}),
          )
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return [];
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      final nodes =
          (((data['data'] as Map<String, dynamic>?)?['allCmsMovies'] as Map<String, dynamic>?)
                  ?['nodes'] as List?) ??
              [];
      final out = <Map<String, dynamic>>[];
      for (final n in nodes) {
        if (n is! Map<String, dynamic>) continue;
        final pmd = (n['videoSource'] as Map<String, dynamic>?)?['pmdUrl']?.toString() ?? '';
        if (pmd.isEmpty) continue;
        final cover = (n['coverImage'] as Map<String, dynamic>?)?['masterUrl']?.toString() ?? '';
        out.add({
          'title': n['title']?.toString() ?? '',
          'original_language': 'de',
          'year': n['productionYear']?.toString(),
          'poster_url': cover,
          'backdrop_url': cover,
          'overview': '',
          'media_type': 'movie',
          'isFolder': false,
          'url': _streamUrl(pmd),
          'source': 'netzkino',
        });
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Sucht einen Titel und liefert die direkte Stream-URL (für flixam://tmdb/...).
  Future<String?> resolveTitle(String title, {int? season, int? episode}) async {
    final term = (season != null && episode != null)
        ? '$title S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
        : title;
    var items = await search(term);
    if (items.isEmpty && term != title) items = await search(title);
    if (items.isEmpty) return null;

    final clean = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
    Map<String, dynamic>? best;
    var bestScore = 0;
    for (final it in items) {
      final t = it['title'].toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
      int score;
      if (t == clean) {
        score = 100;
      } else if (t.contains(clean) || clean.contains(t)) {
        score = 60;
      } else {
        score = 0;
      }
      if (score > bestScore) {
        bestScore = score;
        best = it;
      }
    }
    return best?['url']?.toString();
  }
}
