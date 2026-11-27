import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'site_scrapers.dart';
import 'netzkino_service.dart';
import 'einschalten_service.dart';

/// Baut einen Katalog aller bei unseren Quellen tatsächlich vorhandenen
/// Titel und filtert die Home-Liste damit (nur abspielbare Filme anzeigen).
class AvailabilityService {
  static final AvailabilityService instance = AvailabilityService._();
  static const String ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';

  Set<String>? _titles;
  Set<String>? get loadedTitles => _titles;
  final Map<String, Set<String>> _bySource = {};
  final Map<String, List<Map<String, String>>> _sourceCache = {};
  AvailabilityService._();

  void reload() {
    _titles = null;
    _bySource.clear();
    _sourceCache.clear();
  }

  static String normalize(String value) {
    var s = value.toLowerCase()
        .replaceAll('ä', 'ae').replaceAll('ö', 'oe').replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss');
    s = s.replaceAll(RegExp(r'\s*\(\d{4}\)\s*'), ' ');
    s = s.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return s;
  }

  Future<void> _addFromUrl(
    String url,
    Set<String> out, {
    bool post = false,
    Object? body,
    required void Function(String body) parse,
  }) async {
    try {
      final uri = Uri.parse(url);
      final r = post
          ? await http.post(uri,
              headers: {
                'User-Agent': ua,
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            ).timeout(const Duration(seconds: 25))
          : await http.get(uri, headers: {'User-Agent': ua})
              .timeout(const Duration(seconds: 25));
      if (r.statusCode == 200) parse(r.body);
    } catch (_) {}
  }

  Future<Set<String>> load() async {
    if (_titles != null) return _titles!;
    final netzkino = <String>{};
    final einschalten = <String>{};
    final movie2k = <String>{};
    final streamcloud = <String>{};

    await Future.wait([
      _addFromUrl(
        'https://data.netzkino.de/netzkino/graphql',
        netzkino,
        post: true,
        body: {'query': '{ allCmsMovies(first: 2000) { nodes { title } } }'},
        parse: (body) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          final nodes =
              (((data['data'] as Map<String, dynamic>?)?['allCmsMovies'] as Map<String, dynamic>?)
                      ?['nodes'] as List?) ??
                  [];
          for (final n in nodes) {
            final t = n['title']?.toString();
            if (t != null && t.isNotEmpty) netzkino.add(normalize(t));
          }
        },
      ),
      _addFromUrl(
        'https://data.netzkino.de/netzkino/graphql',
        netzkino,
        post: true,
        body: {'query': '{ allCmsSeries(first: 1000) { nodes { title } } }'},
        parse: (body) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          final nodes =
              (((data['data'] as Map<String, dynamic>?)?['allCmsSeries'] as Map<String, dynamic>?)
                      ?['nodes'] as List?) ??
                  [];
          for (final n in nodes) {
            final t = n['title']?.toString();
            if (t != null && t.isNotEmpty) netzkino.add(normalize(t));
          }
        },
      ),
      _addFromUrl(
        'https://einschalten.in/api/movies',
        einschalten,
        parse: (body) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          for (final m in (data['data'] as List?) ?? []) {
            final t = m['title']?.toString();
            if (t != null && t.isNotEmpty) einschalten.add(normalize(t));
          }
        },
      ),
      _addFromUrl(
        'https://movie2k.cx/movies',
        movie2k,
        parse: (body) {
          final re = RegExp(
            r'<h2[^>]*>\s*(?:<!--[^>]*-->\s*)?<a href="[^"]+"[^>]*>(.*?)</a>',
            dotAll: true,
          );
          for (final m in re.allMatches(body)) {
            final t = m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
            if (t.isNotEmpty) movie2k.add(normalize(t));
          }
        },
      ),
      _addFromUrl(
        'https://movie2k.cx/tv/all',
        movie2k,
        parse: (body) {
          final re = RegExp(
            r'<h2[^>]*>\s*(?:<!--[^>]*-->\s*)?<a href="[^"]+"[^>]*>(.*?)</a>',
            dotAll: true,
          );
          for (final m in re.allMatches(body)) {
            final t = m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim().replaceAll('[SERIE]', '');
            if (t.isNotEmpty) movie2k.add(normalize(t));
          }
        },
      ),
      _addFromUrl(
        'https://streamcloud.date/kinofilme',
        streamcloud,
        parse: (body) {
          final re = RegExp(r'<a class="cv" href="[^"]+" title="([^"]*)"');
          for (final m in re.allMatches(body)) {
            final t = m.group(1)!.trim();
            if (t.isNotEmpty) streamcloud.add(normalize(t));
          }
        },
      ),
    ]);

    _bySource
      ..['Netzkino'] = netzkino
      ..['Einschalten'] = einschalten
      ..['Movie2k'] = movie2k
      ..['Streamcloud'] = streamcloud;
    final set = <String>{
      ...netzkino,
      ...einschalten,
      ...movie2k,
      ...streamcloud,
    };
    _titles = set;
    return set;
  }

  /// Welche Anbieter haben diesen Titel? (für die Detailseite)
  bool _matches(String candidate, String normalized) {
    final c = normalize(candidate);
    if (c == normalized) return true;
    if (normalized.length >= 10 && (c.contains(normalized) || normalized.contains(c))) {
      return true;
    }
    return false;
  }

  /// Anbieter inkl. playbarer URL für einen Titel (für Hero & Details).
  Future<List<Map<String, String>>> providerOptions(String title) async {
    final cached = _sourceCache[title];
    if (cached != null) return cached;
    final n = normalize(title);
    final searches = <Future<List<Map<String, dynamic>>>>[
      NetzkinoService.instance.search(title),
      EinschaltenService.instance.search(title),
      SiteScrapers.instance.movie2k(title),
      SiteScrapers.instance.kellerkino(title),
      SiteScrapers.instance.hdfilme(title),
      SiteScrapers.instance.streamcloud(title),
      SiteScrapers.instance.filmpalast(title),
      SiteScrapers.instance.filmo(title),
      SiteScrapers.instance.megakino(title),
    ];
    const labels = [
      'Netzkino', 'Einschalten', 'Movie2k', 'Kellerkino', 'HD Filme',
      'Streamcloud', 'FilmPalast', 'Filmo', 'Megakino',
    ];
    final results = await Future.wait(searches);
    final out = <Map<String, String>>[];
    for (var i = 0; i < results.length; i++) {
      for (final item in results[i]) {
        if (_matches(item['title']?.toString() ?? '', n)) {
          final url = item['url']?.toString() ?? '';
          if (url.isNotEmpty) {
            // Linux nutzt das Python-Backend: Dart-Scheme-URLs in eine
            // Backend-Such-URL mit Quellen-Wunsch uebersetzen.
            final playUrl = Platform.isAndroid || url.startsWith('http')
                ? url
                : 'plugin://flixam/search/${Uri.encodeComponent(title)}'
                    '?source=${Uri.encodeComponent(labels[i].toLowerCase().replaceAll(RegExp(r'\s+'), ''))}';
            out.add({'label': labels[i], 'url': playUrl});
          }
          break;
        }
      }
    }
    _sourceCache[title] = out;
    return out;
  }

  Future<List<String>> sourcesFor(String title) async {
    final options = await providerOptions(title);
    return options.map((o) => o['label']!).toList();
  }

  bool isAvailable(String title) {
    final set = _titles;
    if (set == null) return true;
    final n = normalize(title);
    return set.contains(n);
  }

  /// Filtert alle Home-Reihen; der Hero wird ggf. durch einen verfügbaren
  /// Titel ersetzt, falls der TMDB-Hero nirgends vorhanden ist.
  Future<Map<String, dynamic>> filterHome(Map<String, dynamic> home) async {
    final set = await load();
    if (set.isEmpty) return home;

    final sections = <Map<String, dynamic>>[];
    Map<String, dynamic>? firstAvailable;
    for (final section in (home['sections'] as List?) ?? []) {
      final items = ((section['items'] as List?) ?? [])
          .whereType<Map<String, dynamic>>()
          .where((i) => set.contains(normalize(i['title']?.toString() ?? '')))
          .toList();
      if (items.isNotEmpty) {
        firstAvailable ??= items.first;
        sections.add({'title': section['title'], 'items': items});
      }
    }

    var hero = home['hero'] as Map<String, dynamic>?;
    if (hero == null || !set.contains(normalize(hero['title']?.toString() ?? ''))) {
      hero = firstAvailable;
    }
    return {'hero': hero, 'sections': sections};
  }
}
