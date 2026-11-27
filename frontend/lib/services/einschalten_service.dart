import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'browser_resolver.dart';

/// Backend-freier Scraper für einschalten.in inkl. doodstream-Auflösung.
class EinschaltenService {
  static final EinschaltenService instance = EinschaltenService._();
  static const String base = 'https://einschalten.in';
  static const String imgBase = 'https://einschalten.in/api/image/poster';
  static const String ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';

  EinschaltenService._();

  Future<http.Response> _get(String url, {String? referer}) => http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': ua,
          if (referer != null) 'Referer': referer,
        },
      ).timeout(const Duration(seconds: 25));

  /// Sucht Titel und liefert Flixam-Items mit Watch-Link als URL.
  Future<List<Map<String, dynamic>>> search(String term) async {
    if (term.trim().isEmpty) return [];
    try {
      final r = await _get('$base/search?query=${Uri.encodeComponent(term)}');
      if (r.statusCode != 200) return [];
      final html = r.body;
      final re = RegExp(
        r'\{"id":(\d+),"title":"([^"]+)","releaseDate":"([^"]*)","posterPath":"([^"]+)"',
      );
      final out = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final m in re.allMatches(html)) {
        final id = m.group(1)!;
        final title = m.group(2)!;
        final date = m.group(3) ?? '';
        final poster = m.group(4) ?? '';
        if (!seen.add(id)) continue;
        out.add({
          'title': title,
          'original_language': 'de',
          'year': date.isEmpty ? null : date.split('-').first,
          'poster_url': poster.isNotEmpty ? '$imgBase$poster' : '',
          'backdrop_url': poster.isNotEmpty ? '$imgBase$poster' : '',
          'overview': '',
          'media_type': 'movie',
          'isFolder': false,
          'url': 'flixam://einschalten/watch/$id',
          'source': 'einschalten',
        });
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Watch-API -> Hoster-Link (z.B. vide0.net/e/...).
  Future<String?> watchUrl(String id) async {
    try {
      final r = await _get('$base/api/movies/$id/watch');
      if (r.statusCode != 200) return null;
      final m = RegExp(r'"streamUrl"\s*:\s*"([^"]+)"').firstMatch(r.body);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  String _randomSuffix(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random();
    return String.fromCharCodes(
      List<int>.generate(length, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
    );
  }

  /// Löst vide0.net / playmogo.com-Links zum direkten CDN-Stream auf.
  Future<String?> resolveHoster(String url) async {
    final m = RegExp(r'^(?:https?://)?(?:www\.)?[^/]+/(?:d|e)/([0-9a-zA-Z]+)').firstMatch(url);
    if (m == null) return null;
    final id = m.group(1)!;
    const host = 'playmogo.com';
    final dUrl = 'https://$host/d/$id';
    final eUrl = 'https://$host/e/$id';

    // Auf Android die Cloudflare-geschuetzten Requests im Browser-Kontext
    // ausfuehren (Dart-HTTP wird mit 403 blockt).
    if (Platform.isAndroid) {
      final resolved = await BrowserResolver.instance.resolve(
        eUrl: eUrl,
        referer: dUrl,
      );
      if (resolved != null && resolved.startsWith('http')) {
        return '$resolved|Referer=https://$host/';
      }
      return null;
    }

    try {
      var response = await _get(dUrl, referer: 'https://$host/');
      var html = response.body;

      final iframe = RegExp(r'<iframe\s*src="([^"]+)').firstMatch(html);
      String eUrl;
      if (iframe != null) {
        var src = iframe.group(1)!;
        if (src.startsWith('/')) src = 'https://$host$src';
        eUrl = src;
        response = await _get(eUrl, referer: dUrl);
        html = response.body;
      } else {
        eUrl = 'https://$host/e/$id';
        response = await _get(eUrl, referer: dUrl);
        html = response.body;
      }

      final tokenMatch = RegExp(
        r'''dsplayer\.hotkeys[^']+'([^']+).+?function\s*makePlay.+?return[^?]+([^"]+)''',
        dotAll: true,
      ).firstMatch(html);
      if (tokenMatch == null) return null;
      final path = tokenMatch.group(1)!;
      final token = tokenMatch.group(2)!;

      final passUrl = path.startsWith('http') ? path : 'https://$host$path';
      final pass = await _get(passUrl, referer: eUrl);
      final base = pass.body.trim();
      if (!base.startsWith('http')) return null;
      final stream = '$base${_randomSuffix(10)}$token${DateTime.now().millisecondsSinceEpoch}';
      final flat = await BrowserResolver.flattenMaster(stream, {
        'User-Agent': ua,
        'Referer': 'https://$host/',
      });
      return '$flat|Referer=https://$host/';
    } catch (_) {
      return null;
    }
  }

  /// Vollständiger Pfad: Suchbegriff -> Watch-Link -> direkter Stream.
  Future<String?> resolveTitle(String title) async {
    final items = await search(title);
    if (items.isEmpty) return null;
    final clean = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
    Map<String, dynamic>? best;
    var bestScore = 0;
    for (final it in items) {
      final t = it['title'].toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
      final score = t == clean ? 100 : (t.contains(clean) || clean.contains(t) ? 60 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = it;
      }
    }
    best ??= items.first;
    final watch = await watchUrl((best['url'] as String).split('/').last);
    if (watch == null) return null;
    return resolveHoster(watch);
  }
}
