import 'package:http/http.dart' as http;

/// Scraper für zusätzliche Film-Sites (Dart-Port der Kodi-Addons).
class SiteScrapers {
  static final SiteScrapers instance = SiteScrapers._();
  static const String ua =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';

  SiteScrapers._();

  Future<String> _fetch(String url, {String? referer, Map<String, String>? post}) async {
    final headers = {'User-Agent': ua, if (referer != null) 'Referer': referer};
    final uri = Uri.parse(url);
    final r = post == null
        ? await http.get(uri, headers: headers).timeout(const Duration(seconds: 25))
        : await http.post(uri, headers: headers, body: post).timeout(const Duration(seconds: 25));
    if (r.statusCode >= 300 && r.statusCode < 400) {
      final loc = r.headers['location'];
      if (loc != null) return _fetch(loc.startsWith('http') ? loc : uri.resolve(loc).toString(), referer: referer);
    }
    return r.body;
  }

  String _abs(String base, String url) {
    if (url.startsWith('http')) return url;
    if (url.startsWith('//')) return 'https:$url';
    return Uri.parse(base).resolve(url).toString();
  }

  Map<String, dynamic> _item({
    required String title,
    required String detailUrl,
    String poster = '',
    String? year,
    required String source,
  }) =>
      {
        'title': title,
        'url': 'flixam://site/${Uri.encodeComponent(detailUrl)}?source=$source',
        'detail_url': detailUrl,
        'poster_url': poster,
        'backdrop_url': poster,
        'year': year,
        'overview': '',
        'media_type': 'movie',
        'isFolder': false,
        'source': source,
      };

  // ---------------- movie2k ----------------
  Future<List<Map<String, dynamic>>> movie2k(String term) async {
    try {
      const base = 'https://movie2k.cx';
      final html = await _fetch('$base/search?q=${Uri.encodeComponent(term)}');
      final re = RegExp(
        r'<td width="115" valign="top">\s*<img src="([^"]+)"[^>]*>\s*</td>\s*<td valign="top">\s*<h2[^>]*>\s*(?:<!--[^>]*-->\s*)?<a href="([^"]+)"[^>]*>(.*?)</a>(.*?)</h2>\s*<div class="beschreibung"[^>]*>(.*?)</span>',
        dotAll: true,
      );
      final out = <Map<String, dynamic>>[];
      for (final m in re.allMatches(html)) {
        final title = m.group(3)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        if (title.isEmpty) continue;
        final yr = RegExp(r'\|\s*(\d{4})\s*').firstMatch(m.group(5) ?? '')?.group(1);
        out.add(_item(
          title: title,
          detailUrl: _abs(base, m.group(2)!),
          poster: _abs(base, m.group(1)!),
          year: yr,
          source: 'movie2k',
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------------- kellerkino ----------------
  Future<List<Map<String, dynamic>>> kellerkino(String term) async {
    try {
      const base = 'https://www.kellerkino.com';
      final clean = term.replaceAll(RegExp(r"[&''’]"), '').trim();
      final html = await _fetch('$base/search/${Uri.encodeComponent(clean)}/');
      final cards = RegExp(r'<article class="movie-card[^"]*">(.*?)</article>', dotAll: true);
      final out = <Map<String, dynamic>>[];
      for (final c in cards.allMatches(html)) {
        final body = c.group(1)!;
        final link = RegExp(r'<h2><a href="([^"]+)">(.*?)</a></h2>', dotAll: true).firstMatch(body);
        if (link == null) continue;
        final poster = RegExp(r'<img[^>]+(?:src|data-dmt-theme-src)="([^"]+)"').firstMatch(body)?.group(1) ?? '';
        final year = RegExp(r'<span>\s*(\d{4})\s*</span>').firstMatch(body)?.group(1);
        out.add(_item(
          title: link.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim(),
          detailUrl: _abs(base, link.group(1)!),
          poster: _abs(base, poster),
          year: year,
          source: 'kellerkino',
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------------- hd-filme ----------------
  Future<List<Map<String, dynamic>>> hdfilme(String term) async {
    try {
      const base = 'https://hd-filme.skin';
      final html = await _fetch(
        base,
        post: {
          'do': 'search',
          'subaction': 'search',
          'story': term,
          'titleonly': '3',
        },
      );
      final re = RegExp(
        r'<div class="box-product(.*?)<h3.*?href="([^"]+).*?">([^<]+).*?(.*?)</li>',
        dotAll: true,
      );
      final out = <Map<String, dynamic>>[];
      for (final m in re.allMatches(html)) {
        final info = m.group(1) ?? '';
        final title = m.group(3)!.trim();
        if (title.isEmpty) continue;
        final poster = RegExp(r'data-src="([^"]+)"').firstMatch(info)?.group(1) ?? '';
        final year = RegExp(r'fa-calendar-o[^>]*></i>\s*(\d{4})\s*<').firstMatch(m.group(4) ?? '')?.group(1);
        out.add(_item(
          title: title,
          detailUrl: _abs(base, m.group(2)!),
          poster: _abs(base, poster),
          year: year,
          source: 'hdfilme',
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------------- streamcloud ----------------
  Future<List<Map<String, dynamic>>> streamcloud(String term) async {
    try {
      const base = 'https://streamcloud.date';
      final html = await _fetch('$base/discover?q=${Uri.encodeComponent(term)}');
      final re = RegExp(r'<a class="cv" href="([^"]+)" title="([^"]*)"[^>]*>(.*?)</a>', dotAll: true);
      final out = <Map<String, dynamic>>[];
      for (final m in re.allMatches(html)) {
        final inner = m.group(3) ?? '';
        final poster = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(inner)?.group(1) ?? '';
        final meta = RegExp(r'class="cv-m">(.*?)</div>', dotAll: true).firstMatch(inner)?.group(1) ?? '';
        final year = RegExp(r'\b(\d{4})\b').firstMatch(meta)?.group(1);
        out.add(_item(
          title: m.group(2)!.trim(),
          detailUrl: _abs(base, m.group(1)!),
          poster: _abs(base, poster),
          year: year,
          source: 'streamcloud',
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------------- Hoster aus Detailseite ----------------
  Future<List<String>> hosters(String detailUrl, String source) async {
    try {
      final html = await _fetch(detailUrl, referer: detailUrl);
      final found = <String>[];
      void add(String u) {
        var url = u.trim();
        if (url.startsWith('//')) url = 'https:$url';
        if (url.isEmpty || url.contains('youtube') || url.contains('youtu.be')) return;
        if (url.startsWith('http') && !found.contains(url)) found.add(url);
      }

      if (source == 'movie2k') {
        for (final m in RegExp(r'<option value="(http[^"]+)"[^>]*data-quality=', dotAll: true).allMatches(html)) {
          add(m.group(1)!.replaceFirst(RegExp(r'^(https?:)/+'), r'$1//'));
        }
      } else if (source == 'kellerkino') {
        for (final panel in html.split('data-nfo-player-panel="').skip(1)) {
          final m = RegExp(r'<iframe[^>]+src="(https?://[^"]+)"').firstMatch(panel);
          if (m != null) add(m.group(1)!);
        }
      } else if (source == 'hdfilme') {
        for (final m in RegExp(r'link="([^"]+)"').allMatches(html)) {
          add(m.group(1)!);
        }
      } else if (source == 'streamcloud') {
        for (final m in RegExp(r'(?:src|data-src)="(https?://[^"]+)"').allMatches(html)) {
          add(m.group(1)!);
        }
      } else if (source == 'filmpalast') {
        for (final m in RegExp(r'hostName">([^<]+).*?(http[^"]+)', dotAll: true).allMatches(html)) {
          add(m.group(2)!);
        }
      } else if (source == 'megakino') {
        for (final m in RegExp(r'<iframe[^>]*(?:data-src|src)="(https?://[^"]+)"').allMatches(html)) {
          add(m.group(1)!);
        }
      } else if (source == 'filmo') {
        // filmo nutzt zusaetzlich /n-Token - hier nur als Fallback.
        for (final m in RegExp(r'href="(https?://[^"]+)"').allMatches(html)) {
          final u = m.group(1)!;
          if (u.contains('voe') || u.contains('filemoon') || u.contains('dood') || u.contains('playmogo')) add(u);
        }
      }
      return found.take(12).toList();
    } catch (_) {
      return [];
    }
  }

  // ---------------- blind portierte Sites (hier nicht erreichbar) ----------------
  Future<List<Map<String, dynamic>>> filmpalast(String term) async {
    try {
      const base = 'https://filmpalast.to';
      final html = await _fetch('$base/search/title/${Uri.encodeComponent(term)}');
      final re = RegExp(
        r'''<article[^>]*>\s*<a href="([^"]+)" title="([^"]+)">\s*<img src=["']([^"']+)["'][^>]*>(.*?)</article>''',
        dotAll: true,
      );
      final out = <Map<String, dynamic>>[];
      for (final m in re.allMatches(html)) {
        final year = RegExp(r'Jahr:[^>]([\d]+)').firstMatch(m.group(4) ?? '')?.group(1);
        out.add(_item(title: m.group(2)!, detailUrl: _abs(base, m.group(1)!), poster: _abs(base, m.group(3)!), year: year, source: 'filmpalast'));
      }
      return out;
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> filmo(String term) async {
    try {
      const base = 'https://filmo.to';
      final html = await _fetch('$base/search?q=${Uri.encodeComponent(term)}');
      final parts = html.split(RegExp(r'<a[^>]+href="https://filmo.to/movies/([a-z0-9-]+)"'));
      final out = <Map<String, dynamic>>[];
      for (var i = 1; i + 1 < parts.length; i += 2) {
        final slug = parts[i];
        final rest = parts[i + 1];
        final title = RegExp(r'(?:spotlight-card__title|grid-card__title)[^>]*>\s*([^<]+?)\s*<')
                .firstMatch(rest)?.group(1) ??
            RegExp(r'<img[^>]+alt="([^"]+)"').firstMatch(rest)?.group(1) ?? slug;
        final poster = RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(rest)?.group(1)?.replaceAll('?format=webp', '') ?? '';
        out.add(_item(title: title.trim(), detailUrl: '$base/movies/$slug', poster: _abs(base, poster), source: 'filmo'));
      }
      return out;
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> megakino(String term) async {
    try {
      const base = 'https://megakino27.com';
      final html = await _fetch('$base?do=search&subaction=search&story=${Uri.encodeComponent(term)}&titleonly=3');
      final re = RegExp(
        r'<a class="poster grid-item[^>]*href="([^"]+)"[^>]*>.*?<img[^>]*data-src="([^"]+)"[^>]*alt="([^"]+)"[^>]*>.*?<h3 class="poster__title[^>]*>([^<]*)</h3>',
        dotAll: true,
      );
      final out = <Map<String, dynamic>>[];
      for (final m in re.allMatches(html)) {
        final year = RegExp(r'<li>[^<]*?(\d{4})\s*</li>').firstMatch(m.group(0)!)?.group(1);
        out.add(_item(title: m.group(4)!.trim(), detailUrl: _abs(base, m.group(1)!), poster: _abs(base, m.group(2)!), year: year, source: 'megakino'));
      }
      return out;
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> all(String term) async {
    final results = await Future.wait([
      movie2k(term),
      kellerkino(term),
      hdfilme(term),
      streamcloud(term),
      filmpalast(term),
      filmo(term),
      megakino(term),
    ]);
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final list in results) {
      for (final item in list) {
        final key = '${item['title']}|${item['source']}';
        if (seen.add(key)) out.add(item);
      }
    }
    return out;
  }
}
