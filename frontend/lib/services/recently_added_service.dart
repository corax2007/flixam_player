import 'dart:convert';
import 'package:http/http.dart' as http;
import 'gez_kino_service.dart';

/// „Neu hinzugefügt": recenteste Einträge aus unseren Quellen.
class RecentlyAddedService {
  static final RecentlyAddedService instance = RecentlyAddedService._();
  static const String ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/148.0 Safari/537.36';

  List<Map<String, dynamic>>? _cache;
  RecentlyAddedService._();

  void reload() => _cache = null;

  Future<List<Map<String, dynamic>>> items({int limit = 60}) async {
    if (_cache != null) return _cache!.take(limit).toList();
    final out = <Map<String, dynamic>>[];

    // GEZ Kino: timestamp der Mediathek-Liste
    try {
      final all = await GezKinoService.instance.load();
      final sorted = all.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) =>
            (int.tryParse(b['timestamp']?.toString() ?? '') ?? 0)
                .compareTo(int.tryParse(a['timestamp']?.toString() ?? '') ?? 0));
      for (final m in sorted.take(80)) {
        final video = m['video_url']?.toString() ?? '';
        if (!video.startsWith('http')) continue;
        out.add({
          'title': m['title']?.toString() ?? '',
          'original_language': 'de',
          'year': m['year']?.toString(),
          'poster_url': m['thumb']?.toString() ?? '',
          'backdrop_url': m['thumb']?.toString() ?? '',
          'overview': m['plot']?.toString() ?? '',
          'rating': m['rating'],
          'media_type': 'movie',
          'isFolder': false,
          'source': 'GEZ Kino',
          'date': m['timestamp']?.toString(),
          'url': video,
        });
      }
    } catch (_) {}

    // Einschalten: releaseDate der aktuellen Filmliste
    try {
      final r = await http.get(
        Uri.parse('https://einschalten.in/api/movies'),
        headers: {'User-Agent': ua},
      ).timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body) as Map<String, dynamic>;
        final list = (data['data'] as List?) ?? [];
        final sorted = list.whereType<Map<String, dynamic>>().toList()
          ..sort((a, b) => (b['releaseDate']?.toString() ?? '')
              .compareTo(a['releaseDate']?.toString() ?? ''));
        for (final m in sorted.take(60)) {
          final id = m['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final poster = m['posterPath']?.toString() ?? '';
          out.add({
            'title': m['title']?.toString() ?? '',
            'original_language': 'de',
            'year': (m['releaseDate']?.toString() ?? '').isEmpty
                ? null
                : m['releaseDate'].toString().substring(0, 4),
            'poster_url': poster.isEmpty
                ? ''
                : 'https://einschalten.in/api/image/poster$poster',
            'backdrop_url': poster.isEmpty
                ? ''
                : 'https://einschalten.in/api/image/poster$poster',
            'overview': '',
            'rating': m['voteAverage'],
            'media_type': 'movie',
            'isFolder': false,
            'source': 'Einschalten',
            'date': m['releaseDate']?.toString(),
            'url': 'flixam://einschalten/watch/$id',
          });
        }
      }
    } catch (_) {}

    final seen = <String>{};
    final unique = out.where((i) {
      final key = i['title'].toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      return key.isNotEmpty && seen.add(key);
    }).toList();
    unique.sort((a, b) => (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    _cache = unique;
    return unique.take(limit).toList();
  }
}
