import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// TMDB direkt aus der App - kein Python-Backend mehr nötig.
class TmdbService {
  static final TmdbService instance = TmdbService._();

  static const String _envKey = String.fromEnvironment(
    'FLIXAM_TMDB_KEY',
    defaultValue: '',
  );

  /// API-Key nie im Quellcode speichern. Quellen (in dieser Reihenfolge):
  /// 1. Build-Flag  --dart-define=FLIXAM_TMDB_KEY=dein_key
  /// 2. Lokale Datei ~/.flixam_tmdb_key  (eine Zeile, der Key)
  /// 3. Platzhalter - ohne Key funktionieren TMDB-Funktionen nicht.
  static String get apiKey {
    if (_envKey.isNotEmpty && _envKey != 'YOUR_TMDB_API_KEY') return _envKey;
    try {
      final f = File('${Platform.environment['HOME'] ?? '.'}/.flixam_tmdb_key');
      if (f.existsSync()) {
        final key = f.readAsStringSync().trim();
        if (key.isNotEmpty) return key;
      }
    } catch (_) {}
    return 'YOUR_TMDB_API_KEY';
  }
  static const String base = 'https://api.themoviedb.org/3';
  static const String img = 'https://image.tmdb.org/t/p';

  final Map<String, dynamic> _cache = {};
  final Map<dynamic, String> _fskCache = {};
  final Map<String, List<dynamic>> _genres = {};

  TmdbService._();

  void reload() {
    _cache.clear();
    _fskCache.clear();
    _genres.clear();
  }

  Future<Map<String, dynamic>?> _get(String path, [Map<String, dynamic>? params]) async {
    final uri = Uri.parse('$base/$path').replace(queryParameters: {
      'api_key': apiKey,
      'language': 'de-DE',
      ...?params,
    });
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<List<dynamic>> genres({String type = 'movie'}) async {
    if (_genres.containsKey(type)) return _genres[type]!;
    final data = await _get('genre/$type/list');
    final list = (data?['genres'] as List?) ?? [];
    _genres[type] = list;
    return list;
  }

  Future<List<String>> genreNames(List<dynamic> ids, String type) async {
    final map = {for (final g in await genres(type: type)) g['id']: g['name']};
    return ids.map((i) => map[i]?.toString() ?? '').where((s) => s.isNotEmpty).toList();
  }

  String _imgPath(String? path, [String size = 'w500']) =>
      (path == null || path.isEmpty) ? '' : '$img/$size$path';

  /// Ein TMDB-Ergebnis in ein Flixam-Item mit playbarer Such-URL.
  Future<Map<String, dynamic>?> toItem(dynamic res, [String? mediaType]) async {
    if (res is! Map<String, dynamic>) return null;
    final mt = mediaType ?? res['media_type']?.toString() ??
        (res['name'] != null ? 'tv' : 'movie');
    final title = (res['title'] ?? res['name'] ?? '').toString();
    if (title.isEmpty) return null;
    final date = (res['release_date'] ?? res['first_air_date'] ?? '').toString();
    final genreIds = (res['genre_ids'] as List?) ?? [];
    return {
      'id': res['id'],
      'title': title,
      'url': 'flixam://tmdb/${Uri.encodeComponent(title)}',
      'isFolder': false,
      'poster_url': _imgPath(res['poster_path']),
      'backdrop_url': _imgPath(res['backdrop_path'], 'w1280'),
      'rating': res['vote_average'] == null ? null : (res['vote_average'] as num).toDouble(),
      'year': date.isEmpty ? null : date.split('-').first,
      'release_date': date,
      'overview': res['overview']?.toString() ?? '',
      'media_type': mt,
      'genres': await genreNames(genreIds, mt),
    };
  }

  /// Trailer-Key auch ohne TMDB-ID (z. B. Backend-Suchergebnisse).
  Future<String?> trailerKeyForTitle(String title) async {
    final base = await _findBase(title, null);
    return trailerKey(base?['id']);
  }

  /// YouTube-Trailer-Key zu einer TMDB-ID.
  Future<String?> trailerKey(dynamic id) async {
    if (id == null) return null;
    final data = await _get('movie/$id/videos') ?? {};
    final results = (data['results'] as List?) ?? [];
    for (final v in results) {
      if (v['site'] == 'YouTube' &&
          (v['type'] == 'Trailer' || v['type'] == 'Teaser')) {
        return v['key']?.toString();
      }
    }
    return null;
  }

  /// Filme/Serien aus einem bestimmten Erscheinungsjahr (TMDB Discover).
  Future<List<Map<String, dynamic>>> byYear(String year, String type) async {
    final key = 'year|$year|$type';
    final cached = _cache[key] as List<Map<String, dynamic>>?;
    if (cached != null) return cached;
    final isTv = type == 'tv';
    final path = isTv ? 'discover/tv' : 'discover/movie';
    final yearParam = isTv ? 'first_air_date_year' : 'primary_release_year';
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var page = 1; page <= 5; page++) {
      final data = await _get(path, {
        yearParam: year,
        'sort_by': 'popularity.desc',
        'page': '$page',
      }) ?? {};
      final results = (data['results'] as List?) ?? [];
      if (results.isEmpty) break;
      for (final r in results) {
        final it = await toItem(r, type);
        if (it != null && seen.add(it['title'].toString())) out.add(it);
      }
      if (page >= (int.tryParse(data['total_pages']?.toString() ?? '') ?? 1)) break;
    }
    _cache[key] = out;
    return out;
  }

  /// Filme/Serien mit einer bestimmten DE-FSK (TMDB Discover).
  Future<List<Map<String, dynamic>>> byCertification(
    String fsk,
    String type,
  ) async {
    final key = 'cert|$fsk|$type';
    final cached = _cache[key] as List<Map<String, dynamic>>?;
    if (cached != null) return cached;
    final path = type == 'tv' ? 'discover/tv' : 'discover/movie';
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var page = 1; page <= 5; page++) {
      final data = await _get(path, {
        'certification_country': 'DE',
        'certification': fsk,
        'sort_by': 'popularity.desc',
        'page': '$page',
      }) ?? {};
      final results = (data['results'] as List?) ?? [];
      if (results.isEmpty) break;
      for (final r in results) {
        final it = await toItem(r, type);
        if (it != null && seen.add(it['title'].toString())) out.add(it);
      }
      if (page >= (int.tryParse(data['total_pages']?.toString() ?? '') ?? 1)) break;
    }
    _cache[key] = out;
    return out;
  }

  /// FSK-Einstufung (DE) für einen Titel, gecacht.
  Future<String> fskFor(dynamic id, {String mediaType = 'movie'}) async {
    if (id == null) return '';
    if (_fskCache.containsKey(id)) return _fskCache[id] ?? '';
    String result = '';
    try {
      if (mediaType == 'tv') {
        final d = await _get('tv/$id/content_ratings') ?? {};
        for (final r in ((d['results'] as List?) ?? [])) {
          if (r['iso_3166_1'] == 'DE' && r['rating'] != null) {
            result = r['rating'].toString();
            break;
          }
        }
      } else {
        final d = await _get('movie/$id/release_dates') ?? {};
        for (final r in ((d['results'] as List?) ?? [])) {
          if (r['iso_3166_1'] != 'DE') continue;
          for (final x in ((r['release_dates'] as List?) ?? [])) {
            final cert = x['certification']?.toString() ?? '';
            if (cert.isNotEmpty) {
              result = cert;
              break;
            }
          }
          if (result.isNotEmpty) break;
        }
      }
    } catch (_) {}
    final clean = result.replaceAll(RegExp(r'[^0-9]'), '');
    final value = clean.isEmpty ? result : 'FSK $clean';
    _fskCache[id] = value;
    return value;
  }

  /// Streaminganbieter in DE (aus den Watch-Provider-Daten eines Films).
  Future<List<Map<String, dynamic>>> providers() async {
    if (_cache.containsKey('providers')) {
      return _cache['providers'] as List<Map<String, dynamic>>;
    }
    final data = await _get('movie/550/watch/providers') ?? {};
    final de = ((data['results'] as Map<String, dynamic>?)?['DE'] as Map<String, dynamic>?) ?? {};
    final map = <int, Map<String, dynamic>>{};
    for (final key in ['flatrate', 'ads', 'free', 'rent', 'buy']) {
      for (final p in (de[key] as List?) ?? []) {
        final id = p['provider_id'];
        if (id == null || map.containsKey(id)) continue;
        final logo = p['logo_path']?.toString() ?? '';
        map[id] = {
          'id': id,
          'name': p['provider_name']?.toString() ?? '',
          'logo_url': logo.isEmpty ? '' : '$img/w92$logo',
          'priority': p['display_priority'] ?? 999,
        };
      }
    }
    final list = map.values.toList()
      ..sort((a, b) => (a['priority'] as int).compareTo(b['priority'] as int));
    _cache['providers'] = list;
    return list;
  }

  /// Alle Filme und Serien eines Streaminganbieters.
  Future<List<Map<String, dynamic>>> providerItems(int id) async {
    final key = 'provider|$id';
    final cached = _cache[key] as List<Map<String, dynamic>>?;
    if (cached != null) return cached;
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final entry in [
      {'path': 'discover/movie', 'type': 'movie'},
      {'path': 'discover/tv', 'type': 'tv'},
    ]) {
      for (var page = 1; page <= 5; page++) {
        final data = await _get(entry['path']!, {
          'with_watch_providers': id,
          'watch_region': 'DE',
          'sort_by': 'popularity.desc',
          'page': page,
        }) ?? {};
        final results = (data['results'] as List?) ?? [];
        if (results.isEmpty) break;
        for (final r in results) {
          final it = await toItem(r, entry['type']!);
          if (it != null && seen.add(it['title'].toString())) out.add(it);
        }
        if (page >= (int.tryParse(data['total_pages']?.toString() ?? '') ?? 1)) break;
      }
    }
    _cache[key] = out;
    return out;
  }

  /// Alle neuesten Titel eines Anbieters (fuer das "mehr" der Uebersicht).
  Future<List<Map<String, dynamic>>> providerRecentItems(
    int id, {
    int limit = 40,
  }) async {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final entry in [
      {'path': 'discover/movie', 'type': 'movie', 'sort': 'release_date.desc'},
      {'path': 'discover/tv', 'type': 'tv', 'sort': 'first_air_date.desc'},
    ]) {
      for (var page = 1; page <= 3; page++) {
        final data = await _get(entry['path']!, {
          'with_watch_providers': id,
          'watch_region': 'DE',
          'sort_by': entry['sort'],
          'page': page,
        }) ?? {};
        for (final r in (data['results'] as List?) ?? []) {
          final it = await toItem(r, entry['type']!);
          if (it != null && seen.add(it['title'].toString())) out.add(it);
          if (out.length >= limit) break;
        }
        if (out.length >= limit) break;
      }
      if (out.length >= limit) break;
    }
    return out.take(limit).toList();
  }

  /// Neueste Titel pro Anbieter (Dart-Direktmodus fuer Android/Fire TV).
  Future<List<Map<String, dynamic>>> recentByProvider({int limit = 8}) async {
    final providerList = await providers();
    final out = <Map<String, dynamic>>[];
    for (final p in providerList.take(12)) {
      final items = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final entry in [
        {'path': 'discover/movie', 'type': 'movie', 'sort': 'release_date.desc'},
        {'path': 'discover/tv', 'type': 'tv', 'sort': 'first_air_date.desc'},
      ]) {
        final data = await _get(entry['path']!, {
          'with_watch_providers': p['id'],
          'watch_region': 'DE',
          'sort_by': entry['sort'],
          'page': 1,
        }) ?? {};
        for (final r in (data['results'] as List?) ?? []) {
          final it = await toItem(r, entry['type']!);
          if (it != null && seen.add(it['title'].toString())) items.add(it);
          if (items.length >= limit) break;
        }
        if (items.length >= limit) break;
      }
      if (items.isNotEmpty) {
        out.add({
          'id': p['id'],
          'name': p['name'] ?? '',
          'logo_url': p['logo_url'] ?? '',
          'items': items,
        });
      }
    }
    return out;
  }

  static List<Map<String, dynamic>> sectionConfigs() {
    final now = DateTime.now();
    final gte = now.toIso8601String().substring(0, 10);
    final lte = now.add(const Duration(days: 120)).toIso8601String().substring(0, 10);
    return [
      {'title': 'Neu im Kino', 'path': 'movie/now_playing', 'type': 'movie'},
      {'title': 'Neue Serien', 'path': 'tv/popular', 'type': 'tv'},
      {'title': 'Beliebt diese Woche', 'path': 'trending/all/week', 'type': null},
      {'title': 'Top bewertet', 'path': 'movie/top_rated', 'type': 'movie'},
      {
        'title': 'Kommt bald',
        'path': 'discover/movie',
        'type': 'movie',
        'params': {
          'primary_release_date.gte': gte,
          'primary_release_date.lte': lte,
          'sort_by': 'popularity.desc',
        },
      },
      {'title': 'Action', 'path': 'discover/movie', 'type': 'movie', 'genre': '28'},
      {'title': 'Komödie', 'path': 'discover/movie', 'type': 'movie', 'genre': '35'},
      {'title': 'Drama', 'path': 'discover/movie', 'type': 'movie', 'genre': '18'},
      {'title': 'Horror', 'path': 'discover/movie', 'type': 'movie', 'genre': '27'},
    ];
  }

  /// Alle Titel einer Kategorie (alle Seiten), gecacht pro Laufzeit.
  Future<List<Map<String, dynamic>>> allForSection(String title) async {
    final key = 'all|$title';
    final cached = _cache[key] as List<Map<String, dynamic>>?;
    if (cached != null) return cached;
    final entry = sectionConfigs().firstWhere(
      (e) => e['title'] == title,
      orElse: () => {},
    );
    if (entry.isEmpty) return [];
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    var totalPages = 1;
    for (var page = 1; page <= 20; page++) {
      final extra = entry['params'] as Map<String, dynamic>?;
      final params = <String, dynamic>{'page': page, ...?extra};
      if (entry['genre'] != null) {
        params['with_genres'] = entry['genre'];
        params['sort_by'] = 'popularity.desc';
      }
      final data = await _get(entry['path'] as String, params) ?? {};
      if (page == 1) {
        totalPages = int.tryParse(data['total_pages']?.toString() ?? '') ?? 1;
        if (totalPages > 20) totalPages = 20;
      }
      final results = (data['results'] as List?) ?? [];
      if (results.isEmpty) break;
      for (final r in results) {
        final it = await toItem(r, entry['type']);
        if (it != null && seen.add(it['title'].toString())) out.add(it);
      }
      if (page >= totalPages) break;
    }
    _cache[key] = out;
    return out;
  }

  Future<Map<String, dynamic>> home() async {
    final trending = await _get('trending/all/week') ?? {};
    Map<String, dynamic>? hero;
    for (final r in (trending['results'] as List?) ?? []) {
      if (r['backdrop_path'] != null) {
        hero = await toItem(r);
        break;
      }
    }
    final sections = <Map<String, dynamic>>[];
    for (final entry in sectionConfigs()) {
      final all = <Map<String, dynamic>>[];
      for (final page in ['1', '2']) {
        final extra = entry['params'] as Map<String, dynamic>?;
        final params = <String, dynamic>{'page': page, ...?extra};
        if (entry['genre'] != null) {
          params['with_genres'] = entry['genre'];
          params['sort_by'] = 'popularity.desc';
        }
        final data = await _get(entry['path'] as String, params) ?? {};
        for (final r in (data['results'] as List?) ?? []) {
          final it = await toItem(r, entry['type']);
          if (it != null) all.add(it);
        }
      }
      final seen = <String>{};
      final unique = all.where((i) => seen.add(i['title'].toString())).toList();
      sections.add({'title': entry['title'], 'items': unique.take(40).toList()});
    }
    return {'hero': hero, 'sections': sections};
  }

  Future<List<dynamic>> search(String title) async {
    final data = await _get('search/multi', {'query': title, 'page': '1'}) ?? {};
    final out = <dynamic>[];
    for (final r in (data['results'] as List?) ?? []) {
      final it = await toItem(r);
      if (it != null) out.add(it);
    }
    return out;
  }

  Future<Map<String, dynamic>?> _findBase(String title, String? year) async {
    final key = '$title|$year';
    if (_cache.containsKey(key)) return _cache[key];
    final data = await _get('search/multi', {'query': title, 'page': '1'}) ?? {};
    final results = (data['results'] as List?) ?? [];
    Iterable<dynamic> pool = results;
    if (year != null && year.isNotEmpty) {
      final exact = results.where((r) =>
          (r['release_date'] ?? r['first_air_date'] ?? '').toString().startsWith(year));
      if (exact.isNotEmpty) pool = exact;
    }
    Map<String, dynamic>? chosen;
    for (final r in pool) {
      if (r is Map<String, dynamic> &&
          (r['media_type'] == 'movie' || r['media_type'] == 'tv' || r['title'] != null || r['name'] != null)) {
        chosen = r;
        break;
      }
    }
    _cache[key] = chosen;
    return chosen;
  }

  Future<Map<String, dynamic>> details({
    required String title,
    String? year,
    String? type,
  }) async {
    final baseItem = await _findBase(title, year);
    if (baseItem == null) return {};
    var mt = type ?? baseItem['media_type']?.toString() ?? '';
    if (mt != 'movie' && mt != 'tv') mt = baseItem['name'] != null ? 'tv' : 'movie';
    final id = baseItem['id'];
    if (id == null) return {};
    final data = await _get('$mt/$id', {
      'append_to_response': 'credits,release_dates,content_ratings,videos',
    }) ?? {};
    if (data.isEmpty) return {};

    final credits = data['credits'] as Map<String, dynamic>? ?? {};
    final cast = ((credits['cast'] as List?) ?? []).take(20).map((c) => {
          'id': c['id'],
          'name': c['name'] ?? '',
          'character': c['character'] ?? '',
          'profile_url': _imgPath(c['profile_path'], 'w185'),
        }).toList();
    final crew = (credits['crew'] as List?) ?? [];
    final directors = crew.where((c) => c['job'] == 'Director').map((c) => c['name']).join(', ');
    final writers = crew.where((c) => ['Writer', 'Screenplay', 'Novel'].contains(c['job']))
        .map((c) => c['name']).join(', ');

    var fsk = '';
    for (final r in ((data['release_dates'] as Map<String, dynamic>?)?['results'] as List?) ?? []) {
      if (r['iso_3166_1'] == 'DE') {
        for (final d in (r['release_dates'] as List?) ?? []) {
          if (d['certification'] != null && d['certification'].toString().isNotEmpty) {
            fsk = d['certification'].toString();
            break;
          }
        }
      }
      if (fsk.isNotEmpty) break;
    }
    if (fsk.isEmpty) {
      for (final r in ((data['content_ratings'] as Map<String, dynamic>?)?['results'] as List?) ?? []) {
        if (r['iso_3166_1'] == 'DE' && r['rating'] != null) {
          fsk = r['rating'].toString();
          break;
        }
      }
    }
    if (fsk.isNotEmpty && !fsk.toUpperCase().startsWith('FSK')) fsk = 'FSK $fsk';

    var trailer = '';
    for (final v in ((data['videos'] as Map<String, dynamic>?)?['results'] as List?) ?? []) {
      if (v['site'] == 'YouTube' && v['type'] == 'Trailer') {
        trailer = v['key']?.toString() ?? '';
        break;
      }
    }

    final release = (data['release_date'] ?? data['first_air_date'] ?? '').toString();
    final genres = (data['genres'] as List?)?.map((g) => g['name'].toString()).toList() ?? [];
    var runtime = (data['runtime'] as num?)?.toInt() ?? 0;
    if (runtime == 0 && data['episode_run_time'] is List && (data['episode_run_time'] as List).isNotEmpty) {
      runtime = (data['episode_run_time'][0] as num?)?.toInt() ?? 0;
    }

    final seasons = <Map<String, dynamic>>[];
    if (mt == 'tv') {
      for (final s in (data['seasons'] as List?) ?? []) {
        final nr = s['season_number'];
        if (nr == null) continue;
        final sd = await _get('tv/$id/season/$nr') ?? {};
        final episodes = <Map<String, dynamic>>[];
        for (final e in (sd['episodes'] as List?) ?? []) {
          final ep = e['episode_number'];
          if (ep == null) continue;
          episodes.add({
            'season': nr,
            'episode': ep,
            'title': e['name'] ?? 'Folge $ep',
            'overview': e['overview'] ?? '',
            'still_url': _imgPath(e['still_path'], 'w500'),
            'air_date': e['air_date'] ?? '',
            'runtime': e['runtime'] ?? 0,
            'rating': e['vote_average'],
            'url': 'flixam://tmdb/${Uri.encodeComponent(title.toString())}?season=$nr&episode=$ep',
          });
        }
        seasons.add({
          'season': nr,
          'name': s['name'] ?? 'Staffel $nr',
          'poster_url': _imgPath(s['poster_path']),
          'air_date': s['air_date'] ?? '',
          'episode_count': episodes.length,
          'episodes': episodes,
        });
      }
    }

    return {
      'title': data['title'] ?? data['name'] ?? title,
      'original_title': data['original_title'] ?? data['original_name'] ?? '',
      'tagline': data['tagline'] ?? '',
      'overview': data['overview'] ?? '',
      'release_date': release,
      'year': release.isEmpty ? (year ?? '') : release.split('-').first,
      'runtime': runtime,
      'fsk': fsk,
      'genres': genres,
      'rating': data['vote_average'],
      'votes': data['vote_count'],
      'popularity': data['popularity'],
      'status': data['status'] ?? '',
      'budget': data['budget'] ?? 0,
      'revenue': data['revenue'] ?? 0,
      'imdb_id': data['imdb_id'] ?? '',
      'homepage': data['homepage'] ?? '',
      'director': directors,
      'writer': writers,
      'production_companies': ((data['production_companies'] as List?) ?? []).map((p) => p['name']).toList(),
      'production_countries': ((data['production_countries'] as List?) ?? []).map((p) => p['name']).toList(),
      'spoken_languages': ((data['spoken_languages'] as List?) ?? []).map((l) => l['english_name'] ?? l['name']).toList(),
      'cast': cast,
      'trailer': trailer,
      'poster_url': _imgPath(data['poster_path']),
      'backdrop_url': _imgPath(data['backdrop_path'], 'w1280'),
      'media_type': mt,
      'number_of_seasons': data['number_of_seasons'],
      'number_of_episodes': data['number_of_episodes'],
      'seasons': seasons,
    };
  }

  Future<Map<String, dynamic>> person({String? id, String? name}) async {
    String? pid = id;
    if ((pid == null || pid.isEmpty) && name != null) {
      final data = await _get('search/person', {'query': name, 'page': '1'}) ?? {};
      final results = (data['results'] as List?) ?? [];
      final p = results.isNotEmpty ? results.first : null;
      pid = p?['id']?.toString();
    }
    if (pid == null || pid.isEmpty) return {};
    final data = await _get('person/$pid', {'append_to_response': 'movie_credits,tv_credits'}) ?? {};
    if (data.isEmpty) return {};
    final items = <Map<String, dynamic>>[];
    for (final entry in [
      {'list': 'movie_credits', 'type': 'movie'},
      {'list': 'tv_credits', 'type': 'tv'},
    ]) {
      final credits = data[entry['list']] as Map<String, dynamic>? ?? {};
      for (final r in (credits['cast'] as List?) ?? []) {
        final it = await toItem(r, entry['type'] as String);
        if (it != null) {
          it['character'] = r['character'] ?? '';
          items.add(it);
        }
      }
    }
    items.sort((a, b) => (b['year'] ?? '').toString().compareTo((a['year'] ?? '').toString()));
    return {
      'id': data['id'],
      'name': data['name'] ?? name ?? '',
      'profile_url': _imgPath(data['profile_path'], 'h632'),
      'known_for': data['known_for_department'] ?? 'Acting',
      'birthday': data['birthday'] ?? '',
      'deathday': data['deathday'] ?? '',
      'place_of_birth': data['place_of_birth'] ?? '',
      'biography': data['biography'] ?? '',
      'popularity': data['popularity'],
      'item_count': items.length,
      'items': items,
    };
  }
}
