import 'dart:convert';
import 'package:http/http.dart' as http;

/// [GEZ] Kino: fertige Filmliste aus öffentlich-rechtlichen Mediatheken.
class GezKinoService {
  static final GezKinoService instance = GezKinoService._();
  static const String url =
      'https://raw.githubusercontent.com/Chrisophy/GEZ-KiNO/main/movies.json';

  List<dynamic>? _movies;
  GezKinoService._();

  void reload() => _movies = null;

  Future<List<dynamic>> load() async {
    if (_movies != null) return _movies!;
    try {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 40));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        _movies = data is List ? data : [];
      } else {
        _movies = [];
      }
    } catch (_) {
      _movies = [];
    }
    return _movies!;
  }

  Future<List<Map<String, dynamic>>> search(String term) async {
    final movies = await load();
    if (movies.isEmpty || term.trim().isEmpty) return [];
    final needle = term.toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final m in movies) {
      if (m is! Map<String, dynamic>) continue;
      final title = m['title']?.toString() ?? '';
      if (!title.toLowerCase().contains(needle)) continue;
      final video = m['video_url']?.toString() ?? '';
      if (!video.startsWith('http')) continue;
      out.add({
        'title': title,
        'year': m['year']?.toString(),
        'poster_url': m['thumb']?.toString() ?? '',
        'backdrop_url': m['thumb']?.toString() ?? '',
        'overview': m['plot']?.toString() ?? '',
        'rating': m['rating'],
        'media_type': 'movie',
        'isFolder': false,
        'source': 'GEZ Kino',
        'url': video,
      });
      if (out.length >= 80) break;
    }
    return out;
  }
}
