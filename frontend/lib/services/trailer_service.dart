import 'tmdb_service.dart';

/// TMDB Trailers: sucht Filme und liefert YouTube-Trailer-Keys.
class TrailerService {
  static final TrailerService instance = TrailerService._();
  TrailerService._();

  /// Beliebte Filme mit Trailer (für Browse).
  Future<List<Map<String, dynamic>>> popular() async {
    final home = await TmdbService.instance.home();
    final first = (home['sections'] as List?)?.first as Map<String, dynamic>?;
    final items = ((first?['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final candidates = items.take(20).toList();
    final keys = await Future.wait(
      candidates.map((m) => TmdbService.instance.trailerKey(m['id'])),
    );
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < candidates.length; i++) {
      final key = keys[i];
      if (key == null || key.isEmpty) continue;
      final item = Map<String, dynamic>.from(candidates[i]);
      item['url'] = 'youtube://$key';
      item['source'] = 'TMDB Trailers';
      out.add(item);
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> search(String term) async {
    final movies = await TmdbService.instance.search(term);
    final candidates = movies.take(12).toList();
    final keys = await Future.wait(
      candidates.map((m) => TmdbService.instance.trailerKey(m['id'])),
    );
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < candidates.length; i++) {
      final key = keys[i];
      if (key == null || key.isEmpty) continue;
      final item = Map<String, dynamic>.from(candidates[i]);
      item['url'] = 'youtube://$key';
      item['source'] = 'TMDB Trailers';
      out.add(item);
    }
    return out;
  }
}
