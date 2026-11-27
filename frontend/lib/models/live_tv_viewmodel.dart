// Reine ViewModels für die Live-TV-Oberfläche.
// Keine HTTP-/Parser-Logik - die Dateien aus services/ liefern die Rohdaten.

class ProgramVm {
  final String title;
  final String start;
  final String end;

  const ProgramVm({
    required this.title,
    required this.start,
    required this.end,
  });

  factory ProgramVm.fromMap(Map<String, dynamic> map) => ProgramVm(
        title: map['title']?.toString() ?? '',
        start: map['start']?.toString() ?? '',
        end: map['end']?.toString() ?? '',
      );
}

class LiveChannelVm {
  final String name;
  final String url;
  final String category;
  final String program;
  final String start;
  final String end;
  final String description;
  final String icon;
  final double progress;
  final bool favorite;
  final List<ProgramVm> upcoming;

  const LiveChannelVm({
    required this.name,
    required this.url,
    required this.category,
    required this.program,
    required this.start,
    required this.end,
    required this.description,
    required this.icon,
    required this.progress,
    required this.favorite,
    required this.upcoming,
  });

  factory LiveChannelVm.fromRaw({
    required Map<String, dynamic> channel,
    required Map<String, dynamic>? epg,
    required bool favorite,
    required String category,
  }) {
    final e = epg ?? const <String, dynamic>{};
    final ups = (e['upcoming'] as List?) ?? const [];
    return LiveChannelVm(
      name: channel['title']?.toString() ?? '',
      url: channel['url']?.toString() ?? '',
      category: category,
      program: e['title']?.toString() ?? '',
      start: e['start']?.toString() ?? '',
      end: e['end']?.toString() ?? '',
      description: e['description']?.toString() ?? '',
      icon: e['icon']?.toString() ?? '',
      progress: (e['progress'] as num?)?.toDouble() ?? 0,
      favorite: favorite,
      upcoming: ups
          .whereType<Map>()
          .map((m) => ProgramVm.fromMap(m.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class InspectorVm {
  final LiveChannelVm? channel;
  final String backdrop;
  final String poster;
  final double? rating;
  final List<String> genres;
  final String overview;
  final String fsk;
  final String year;

  const InspectorVm({
    this.channel,
    this.backdrop = '',
    this.poster = '',
    this.rating,
    this.genres = const [],
    this.overview = '',
    this.fsk = '',
    this.year = '',
  });

  factory InspectorVm.fromRaw({
    required LiveChannelVm? channel,
    required Map<String, dynamic>? info,
  }) {
    final i = info ?? const <String, dynamic>{};
    final rawGenres = (i['genres'] as List?) ?? const [];
    final rating = i['rating'];
    return InspectorVm(
      channel: channel,
      backdrop: i['backdrop_url']?.toString() ?? '',
      poster: i['poster_url']?.toString() ?? '',
      rating: rating == null ? null : (rating as num).toDouble(),
      genres: rawGenres.map((g) => g.toString()).toList(),
      overview: i['overview']?.toString() ?? '',
      fsk: i['fsk']?.toString() ?? '',
      year: i['year']?.toString() ?? '',
    );
  }

  /// Rule-based Kurzfazit aus TMDB-Metadaten - bewusst ohne externen KI-Call.
  String get highlight {
    final c = channel;
    if (c == null || c.program.isEmpty) {
      return 'Für diesen Sender liegt keine Programminfo vor.';
    }
    final genre = genres.isNotEmpty ? genres.first : 'Sendung';
    final score = rating != null ? '★ ${rating!.toStringAsFixed(1)} · ' : '';
    final until = c.end.isNotEmpty ? ' bis ${c.end} Uhr' : '';
    return '$score$genre – „${c.program}" läuft noch$until.';
  }
}
