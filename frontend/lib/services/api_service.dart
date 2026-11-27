import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'settings_service.dart';
import 'tmdb_service.dart';
import 'netzkino_service.dart';
import 'einschalten_service.dart';
import 'site_scrapers.dart';
import 'browser_resolver.dart';
import 'custom_sources.dart';
import 'gez_kino_service.dart';
import 'trailer_service.dart';
import 'recently_added_service.dart';

class ApiService {
  String baseUrl = AppSettings.defaultBackendUrl;
  /// Auf dem Fire TV alles direkt aus Dart (kein Linux-Backend nötig).
  bool useDirect = false;

  Future<Map<String, dynamic>> vpnStatus() async {
    try {
      final r = await http.get(Uri.parse('$baseUrl/vpn/status')).timeout(const Duration(seconds: 5));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } on SocketException {
      return {'connected': false, 'ip': '', 'error': 'Backend startet...', 'enabled': false, 'has_config': false};
    } on TimeoutException {
      return {'connected': false, 'ip': '', 'error': 'Backend startet...', 'enabled': false, 'has_config': false};
    } catch (e) {
      return {'connected': false, 'ip': '', 'error': 'Backend startet...', 'enabled': false, 'has_config': false};
    }
  }

  Future<Map<String, dynamic>> vpnToggle(bool enabled) async {
    final r = await http.post(
      Uri.parse('$baseUrl/vpn/toggle'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'enabled': enabled}),
    );
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> saveTmdbKey(String key) async {
    await http.post(
      Uri.parse('$baseUrl/settings/tmdb'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'api_key': key}),
    );
  }

  Future<List<dynamic>> browse(String addon, {String? url}) async {
    final uri = Uri.parse('$baseUrl/addon/browse').replace(
      queryParameters: {
        'addon': addon,
        if (url != null && url.isNotEmpty) 'url': url,
      },
    );
    final r = await http.get(uri);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List?) ?? [];
  }

  Future<Map<String, dynamic>> person({String? id, String? name}) async {
    if (useDirect) return TmdbService.instance.person(id: id, name: name);
    final uri = Uri.parse('$baseUrl/tmdb/person').replace(queryParameters: {
      if (id != null && id.isNotEmpty) 'id': id,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 60));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> details({
    required String title,
    String? year,
    String? type,
  }) async {
    if (useDirect) {
      return TmdbService.instance.details(title: title, year: year, type: type);
    }
    final uri = Uri.parse('$baseUrl/tmdb/details').replace(queryParameters: {
      'title': title,
      if (year != null && year.isNotEmpty) 'year': year,
      if (type != null && type.isNotEmpty) 'type': type,
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 60));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> genres({String type = 'movie'}) async {
    if (useDirect) {
      final list = await TmdbService.instance.genres(type: type);
      return list.map((g) => {'id': g['id'], 'name': g['name']}).toList();
    }
    final r = await http.get(Uri.parse('$baseUrl/tmdb/genres?type=$type'));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['genres'] as List?) ?? [];
  }

  Future<Map<String, dynamic>> home({bool force = false}) async {
    Map<String, dynamic> data;
    if (useDirect) {
      data = await TmdbService.instance.home();
    } else {
      final r = await http.get(Uri.parse('$baseUrl/home${force ? '?force=true' : ''}'))
          .timeout(const Duration(seconds: 60));
      data = jsonDecode(r.body) as Map<String, dynamic>;
    }
    final recent = await RecentlyAddedService.instance.items();
    if (recent.isNotEmpty) {
      final sections = (data['sections'] as List?) ?? [];
      // direkt nach „Neu im Kino" einfügen
      final index = sections.indexWhere(
          (s) => (s['title']?.toString() ?? '') == 'Neu im Kino');
      sections.insert(index >= 0 ? index + 1 : 0, {
        'title': 'Neu hinzugefügt',
        'items': recent,
      });
      data['sections'] = sections;
    }
    return data;
  }

  Future<Map<String, dynamic>> trailerStream(String key) async {
    if (useDirect) return {};
    try {
      final r = await http.get(
        Uri.parse('$baseUrl/trailer/stream').replace(queryParameters: {'key': key}),
      ).timeout(const Duration(seconds: 90));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<List<dynamic>> providers() async {
    if (useDirect) {
      return (await TmdbService.instance.providers()).cast<dynamic>();
    }
    final r = await http.get(Uri.parse('$baseUrl/tmdb/providers')).timeout(const Duration(seconds: 30));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['providers'] as List?) ?? [];
  }

  Future<List<dynamic>> seriesNetworkItems(int id, {int limit = 200}) async {
    if (useDirect) {
      return (await TmdbService.instance.seriesNetworkItems(id, limit: limit))
          .cast<dynamic>();
    }
    final r = await http.get(
      Uri.parse('$baseUrl/tmdb/series/network?id=$id&limit=$limit'),
    ).timeout(const Duration(seconds: 180));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List?) ?? [];
  }

  Future<List<dynamic>> newSeries({bool originals = true}) async {
    if (useDirect) {
      return (await TmdbService.instance.newSeries(originals: originals))
          .cast<dynamic>();
    }
    final r = await http.get(
      Uri.parse('$baseUrl/tmdb/series/new?originals=$originals'),
    ).timeout(const Duration(seconds: 180));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['groups'] as List?) ?? [];
  }

  Future<List<dynamic>> providerRecentItems(int id, {int limit = 40}) async {
    if (useDirect) {
      return (await TmdbService.instance.providerRecentItems(id, limit: limit))
          .cast<dynamic>();
    }
    final r = await http.get(
      Uri.parse('$baseUrl/tmdb/provider/recent?id=$id&limit=$limit'),
    ).timeout(const Duration(seconds: 180));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List?) ?? [];
  }

  Future<List<dynamic>> providerRecent() async {
    if (useDirect) {
      return (await TmdbService.instance.recentByProvider()).cast<dynamic>();
    }
    final r = await http.get(Uri.parse('$baseUrl/tmdb/providers/recent'))
        .timeout(const Duration(seconds: 180));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['groups'] as List?) ?? [];
  }

  Future<List<dynamic>> providerItems(int id) async {
    if (useDirect) {
      return (await TmdbService.instance.providerItems(id)).cast<dynamic>();
    }
    final r = await http.get(Uri.parse('$baseUrl/tmdb/provider?id=$id'))
        .timeout(const Duration(seconds: 120));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List?) ?? [];
  }

  Future<List<dynamic>> homeAll(String section) async {
    if (section == 'Neu hinzugefügt') {
      return (await RecentlyAddedService.instance.items(limit: 200)).cast<dynamic>();
    }
    if (useDirect) {
      return TmdbService.instance.allForSection(section);
    }
    final r = await http.get(
      Uri.parse('$baseUrl/home/all').replace(queryParameters: {'section': section}),
    ).timeout(const Duration(seconds: 120));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List?) ?? [];
  }

  Future<List<dynamic>> allEpisodes(String addon, String url) async {
    final uri = Uri.parse('$baseUrl/addon/episodes').replace(
      queryParameters: {'addon': addon, 'url': url},
    );
    final r = await http.get(uri);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List?) ?? [];
  }

  Future<List<dynamic>> search(
    String addon,
    String q, {
    String? year,
    String? genre,
    String? type,
    String? source,
  }) async {
    final wantedYear = year?.trim() ?? '';
    final genreName = genre?.trim() ?? '';
    final wantedType = type?.trim() ?? '';
    if (useDirect) {
      final src = source?.trim().toLowerCase() ?? '';
      var items = <Map<String, dynamic>>[];
      if (src.isEmpty || src == 'alle') {
        items.addAll(await NetzkinoService.instance.search(q));
        items.addAll(await EinschaltenService.instance.search(q));
        items.addAll(await SiteScrapers.instance.all(q));
      } else {
        switch (src) {
          case 'netzkino':
            items.addAll(await NetzkinoService.instance.search(q));
            break;
          case 'einschalten':
            items.addAll(await EinschaltenService.instance.search(q));
            break;
          case 'movie2k':
            items.addAll(await SiteScrapers.instance.movie2k(q));
            break;
          case 'kellerkino':
            items.addAll(await SiteScrapers.instance.kellerkino(q));
            break;
          case 'hd-filme':
            items.addAll(await SiteScrapers.instance.hdfilme(q));
            break;
          case 'streamcloud':
            items.addAll(await SiteScrapers.instance.streamcloud(q));
            break;
          case 'filmpalast':
            items.addAll(await SiteScrapers.instance.filmpalast(q));
            break;
          case 'filmo':
            items.addAll(await SiteScrapers.instance.filmo(q));
            break;
          case 'megakino':
            items.addAll(await SiteScrapers.instance.megakino(q));
            break;
          case 'gezkino':
            items.addAll(await GezKinoService.instance.search(q));
            break;
          case 'trailer':
            items.addAll(await TrailerService.instance.search(q));
            break;
          case 'custom':
            items.addAll(await CustomSources.instance.search(q));
            break;
        }
      }
      if (src.isEmpty || src == 'alle') {
        // Zusätzliche Quellen (auf beiden Plattformen direkt in Dart)
        items.addAll(await GezKinoService.instance.search(q));
        items.addAll(await TrailerService.instance.search(q));
        items.addAll(await CustomSources.instance.search(q));
      }
      // TMDB-Metadaten fuer Bewertung/Poster/Genres ergaenzen
      final tmdbItems = await TmdbService.instance.search(q);
      for (final item in items) {
        final t = item['title'].toString().toLowerCase();
        for (final ti in tmdbItems) {
          final n = (ti['title'] ?? '').toString().toLowerCase();
          if (n == t || (n.isNotEmpty && (n.contains(t) || t.contains(n)))) {
            item['poster_url'] = ti['poster_url'] ?? item['poster_url'];
            item['backdrop_url'] = ti['backdrop_url'] ?? item['backdrop_url'];
            item['rating'] = ti['rating'];
            item['year'] = ti['year'] ?? item['year'];
            item['genres'] = ti['genres'] ?? [];
            item['overview'] = ti['overview']?.toString().isNotEmpty ?? false
                ? ti['overview'] : item['overview'];
            break;
          }
        }
      }
      if (wantedYear.isNotEmpty || genreName.isNotEmpty || wantedType.isNotEmpty) {
        items = items.where((item) {
          if (wantedYear.isNotEmpty && item['year']?.toString() != wantedYear) return false;
          if (genreName.isNotEmpty &&
              !(item['genres'] as List? ?? []).any(
                  (g) => g.toString().toLowerCase() == genreName.toLowerCase())) {
            return false;
          }
          if (wantedType.isNotEmpty && item['media_type'] != wantedType) return false;
          return true;
        }).toList();
      }
      return items;
    }
    final uri = Uri.parse('$baseUrl/addon/search').replace(queryParameters: {
      'addon': addon,
      'q': q,
      if (year != null && year.trim().isNotEmpty) 'year': year.trim(),
      if (genre != null && genre.isNotEmpty) 'genre': genre,
      if (type != null && type.isNotEmpty) 'type': type,
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 180));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final items = <dynamic>[...((j['items'] as List?) ?? [])];
    items.addAll(await GezKinoService.instance.search(q));
    items.addAll(await TrailerService.instance.search(q));
    items.addAll(await CustomSources.instance.search(q));
    return items;
  }

  Map<String, dynamic> _splitDirect(String raw) {
    final parts = raw.split('|');
    final headers = <String, String>{};
    if (parts.length > 1) {
      for (final pair in parts[1].split('&')) {
        final kv = pair.split('=');
        if (kv.length >= 2) {
          headers[Uri.decodeComponent(kv[0])] =
              Uri.decodeComponent(kv.sublist(1).join('='));
        }
      }
    }
    return {'stream_url': parts[0], 'headers': headers};
  }

  Future<Map<String, dynamic>> resolve(String url) async {
    if (url.startsWith('custom://')) {
      final raw = url.substring('custom://'.length);
      final slash = raw.indexOf('/');
      if (slash > 0) {
        final index = int.tryParse(raw.substring(0, slash)) ?? 0;
        final detail = Uri.decodeComponent(raw.substring(slash + 1));
        final hosters = await CustomSources.instance.hosters(index, detail);
        for (final hoster in hosters) {
          String? stream;
          if (useDirect) {
            stream = await BrowserResolver.instance.resolveGeneric(hoster);
          } else {
            try {
              final r = await http.post(
                Uri.parse('$baseUrl/resolve'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'url': hoster}),
              ).timeout(const Duration(seconds: 90));
              final j = jsonDecode(r.body) as Map<String, dynamic>;
              final value = j['stream_url']?.toString() ?? '';
              if (value.isNotEmpty) stream = value;
            } catch (_) {}
          }
          if (stream != null) return _splitDirect(stream);
        }
        return {
          'stream_url': '',
          'headers': <String, String>{},
          'message': 'Kein Stream gefunden (eigene Quelle)',
        };
      }
    }
    if (useDirect) {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        return {'stream_url': url, 'headers': <String, String>{}};
      }
      if (url.startsWith('flixam://tmdb/')) {
        final raw = url.substring('flixam://tmdb/'.length);
        final parts = raw.split('?');
        final title = Uri.decodeComponent(parts.first);
        final params = parts.length > 1 ? Uri.splitQueryString(parts[1]) : <String, String>{};
        final season = int.tryParse(params['season'] ?? '');
        final episode = int.tryParse(params['episode'] ?? '');
        final source = (params['source'] ?? '').toLowerCase();
        String? stream;
        if (source != 'einschalten') {
          stream = await NetzkinoService.instance.resolveTitle(
            title, season: season, episode: episode,
          );
        }
        if (source != 'netzkino') {
          stream ??= await EinschaltenService.instance.resolveTitle(title);
        }
        if (stream != null) return _splitDirect(stream);
        return {
          'stream_url': '',
          'headers': <String, String>{},
          'message': 'Kein Stream gefunden',
        };
      }
      if (url.startsWith('flixam://einschalten/watch/')) {
        final id = url.substring('flixam://einschalten/watch/'.length);
        final watch = await EinschaltenService.instance.watchUrl(id);
        final stream = watch == null ? null : await EinschaltenService.instance.resolveHoster(watch);
        if (stream != null) return _splitDirect(stream);
        return {
          'stream_url': '',
          'headers': <String, String>{},
          'message': 'Kein Stream gefunden',
        };
      }
      if (url.startsWith('flixam://site/')) {
        final raw = url.substring('flixam://site/'.length);
        final parts = raw.split('?');
        final detailUrl = Uri.decodeComponent(parts.first);
        final params = parts.length > 1
            ? Uri.splitQueryString(parts[1])
            : <String, String>{};
        final source = params['source'] ?? '';
        final hosters = await SiteScrapers.instance.hosters(detailUrl, source);
        for (final hoster in hosters) {
          var stream = await BrowserResolver.instance.resolveGeneric(hoster);
          if (stream == null &&
              (hoster.contains('vide0') ||
               hoster.contains('dood') ||
               hoster.contains('playmogo') ||
               hoster.contains('voe'))) {
            stream = await EinschaltenService.instance.resolveHoster(hoster);
          }
          if (stream != null) return _splitDirect(stream);
        }
        return {
          'stream_url': '',
          'headers': <String, String>{},
          'message': 'Kein Stream gefunden (${hosters.length} Hoster geprüft)',
        };
      }
    }
    final r = await http.post(
      Uri.parse('$baseUrl/resolve'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url}),
    );
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}

extension ImportExt on ApiService {
  Future<void> importConfig(String text) async {
    await http.post(Uri.parse('$baseUrl/vpn/import'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'config_text': text}));
  }
}
