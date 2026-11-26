import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/api_service.dart';
import 'services/user_prefs.dart';
import 'services/availability_service.dart';
import 'person_page.dart';

/// Vollbild-Details zu einem Film/einer Serie (TMDB).
class DetailPage extends StatefulWidget {
  final Map<String, dynamic> item;
  final ApiService api;
  final void Function(String url, String title, {bool resume}) onPlay;
  final void Function(List<Map<String, dynamic>> episodes)? onPlayFromHere;
  final VoidCallback? onChanged;
  final bool autoPlaySeason;

  const DetailPage({
    super.key,
    required this.item,
    required this.api,
    required this.onPlay,
    this.onPlayFromHere,
    this.onChanged,
    this.autoPlaySeason = false,
  });

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic>? details;
  final UserPrefs prefs = UserPrefs();
  bool loading = true;
  List<Map<String, String>>? availableSources;
  int myRating = 0;
  late final TextEditingController noteCtrl;
  final Set<int> _openSeasons = {1};

  @override
  void initState() {
    super.initState();
    final itemTitle = widget.item['title']?.toString() ?? '';
    myRating = prefs.ratingFor(itemTitle);
    noteCtrl = TextEditingController(text: prefs.noteFor(itemTitle));
    _load();
    _loadSources();
  }

  @override
  void dispose() {
    noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await AvailabilityService.instance.providerOptions(
        widget.item['title']?.toString() ?? '',
      );
      if (!mounted) return;
      setState(() => availableSources = sources);
    } catch (_) {
      if (mounted) setState(() => availableSources = []);
    }
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.details(
        title: widget.item['title']?.toString() ?? '',
        year: widget.item['year']?.toString(),
        type: widget.item['media_type']?.toString(),
      );
      if (!mounted) return;
      setState(() {
        details = data;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  String _fmtDuration(int minutes) {
    if (minutes <= 0) return '–';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return h > 0 ? '$h h $m min' : '$m min';
  }

  String _fmtMoney(dynamic value) {
    final v = (value is num) ? value.toInt() : 0;
    if (v <= 0) return '–';
    if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)} Mio.';
    return '\$$v';
  }

  Widget _info(String label, String value) {
    if (value.trim().isEmpty || value == '–') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 132, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white54))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, color: Colors.white))),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    );
  }

  Widget _resumeInfo(String title) {
    final pos = prefs.positionFor(title);
    final dur = prefs.durationFor(title);
    if (pos <= 30 || dur <= pos + 10) return const SizedBox.shrink();
    final rest = dur - pos;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: (pos / dur).clamp(0.0, 1.0), minHeight: 3),
          Text(
            'Fortsetzen · noch ${rest ~/ 60} Min.',
            style: const TextStyle(fontSize: 9, color: Colors.lightGreenAccent),
          ),
        ],
      ),
    );
  }

  /// Alle Folgen ab der gegebenen Episode (optional nur innerhalb derselben
  /// Staffel) - fuer "Ab hier wiedergeben" und den Dauerbetrieb.
  List<Map<String, dynamic>> _followingEpisodes(
    Map<String, dynamic> ep, {
    bool sameSeasonOnly = false,
  }) {
    final following = <Map<String, dynamic>>[];
    bool started = false;
    for (final s in ((details?['seasons'] as List?) ?? [])) {
      final season = s as Map;
      if (sameSeasonOnly && started && season['season'] != ep['season']) break;
      for (final e in ((season['episodes'] as List?) ?? [])) {
        final m = (e as Map).cast<String, dynamic>();
        if (!started &&
            m['season'] == ep['season'] &&
            m['episode'] == ep['episode']) {
          started = true;
        }
        if (started) following.add(m);
      }
    }
    return following;
  }

  Widget _episodeTile(Map<String, dynamic> ep) {
    final still = ep['still_url']?.toString() ?? '';
    final no = (ep['episode'] as num?)?.toInt() ?? 0;
    final parts = <String>[
      if (ep['air_date']?.toString().isNotEmpty ?? false) ep['air_date'].toString(),
      if (((ep['runtime'] as num?)?.toInt() ?? 0) > 0) '${ep['runtime']} min',
      if (ep['rating'] != null) '★ ${ep['rating']}',
    ];
    Future<void> openMenu(Offset pos) async {
      final choice = await showMenu<String>(
          context: context,
          color: const Color(0xFF16161A),
          position: RelativeRect.fromLTRB(
            pos.dx,
            pos.dy,
            pos.dx,
            pos.dy,
          ),
          items: const [
            PopupMenuItem(value: 'fromHere', child: Text('Ab hier wiedergeben')),
          ],
        );
        if (choice != 'fromHere') return;
      widget.onPlayFromHere?.call(_followingEpisodes(ep));
    }
    return GestureDetector(
      onLongPress: () => openMenu(const Offset(320, 320)),
      onSecondaryTapDown: (d) => openMenu(d.globalPosition),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 64,
            height: 40,
            child: still.isNotEmpty
                ? Image.network(still, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(color: Colors.grey.shade800))
                : Container(color: Colors.grey.shade800),
          ),
        ),
        title: Text(
          'E${no.toString().padLeft(2, '0')} · ${ep['title']?.toString() ?? ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(parts.join(' · '),
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
            _resumeInfo(ep['title']?.toString() ?? ''),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.play_circle_fill, color: Colors.redAccent, size: 28),
          tooltip: widget.autoPlaySeason
              ? 'Folge und Staffel abspielen'
              : 'Folge abspielen',
          onPressed: () {
            final epTitle = ep['title']?.toString() ?? 'Folge';
            if (widget.autoPlaySeason && widget.onPlayFromHere != null) {
              final queue = _followingEpisodes(ep, sameSeasonOnly: true);
              if (queue.isNotEmpty) {
                widget.onPlayFromHere?.call(queue);
                return;
              }
            }
            widget.onPlay(
              ep['url']?.toString() ?? '',
              epTitle,
              resume: prefs.positionFor(epTitle) > 30,
            );
          },
        ),
      ),
    );
  }

  Widget _seasonTile(Map<String, dynamic> season) {
    final number = (season['season'] as num?)?.toInt() ?? 0;
    final episodes = (season['episodes'] as List?) ?? [];
    final poster = season['poster_url']?.toString() ?? '';
    return Card(
      color: const Color(0xFF16161A),
      child: ExpansionTile(
        initiallyExpanded: _openSeasons.contains(number),
        onExpansionChanged: (open) => setState(() {
          if (open) {
            _openSeasons.add(number);
          } else {
            _openSeasons.remove(number);
          }
        }),
        leading: poster.isNotEmpty
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 38,
                  height: 52,
                  child: Image.network(poster, fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(color: Colors.grey.shade800)),
                ),
              )
            : const Icon(Icons.tv, color: Colors.white70),
        title: Text('Staffel $number – ${season['name']?.toString() ?? ''}',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Text('${episodes.length} Folgen',
            style: const TextStyle(fontSize: 11, color: Colors.white54)),
        children: [
          for (final ep in episodes)
            _episodeTile((ep as Map).cast<String, dynamic>()),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = details ?? {};
    final title = d['title']?.toString() ??
        widget.item['title']?.toString() ?? 'Details';
    final backdrop = d['backdrop_url']?.toString() ??
        widget.item['backdrop_url']?.toString() ?? '';
    final poster = d['poster_url']?.toString() ??
        widget.item['poster_url']?.toString() ?? '';
    final overview = d['overview']?.toString() ??
        widget.item['overview']?.toString() ?? '';
    final genres = (d['genres'] as List?) ?? [];
    final cast = (d['cast'] as List?) ?? [];
    final seasons = (d['seasons'] as List?) ?? [];
    final runtime = (d['runtime'] as num?)?.toInt() ?? 0;

    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0C),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverAppBar(
                    expandedHeight: 340,
                    pinned: true,
                    backgroundColor: const Color(0xFF0A0A0C),
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    flexibleSpace: FlexibleSpaceBar(
                      collapseMode: CollapseMode.pin,
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (backdrop.isNotEmpty)
                            Image.network(
                              backdrop,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              errorBuilder: (_, _, _) => Container(color: const Color(0xFF16161A)),
                            ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Color(0xAA0A0A0C),
                                  Color(0xFF0A0A0C),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (poster.isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: SizedBox(
                                    width: 110,
                                    height: 165,
                                    child: Image.network(
                                      poster,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(color: Colors.grey.shade900),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title,
                                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.1)),
                                    if (d['tagline']?.toString().isNotEmpty ?? false) ...[
                                      const SizedBox(height: 6),
                                      Text(d['tagline'].toString(),
                                          style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.white60)),
                                    ],
                                    const SizedBox(height: 10),
                                    Wrap(
                                      children: [
                                        if (d['year']?.toString().isNotEmpty ?? false) _chip(d['year'].toString()),
                                        if (d['fsk']?.toString().isNotEmpty ?? false) _chip(d['fsk'].toString()),
                                        if (runtime > 0) _chip(_fmtDuration(runtime)),
                                        if (d['rating'] != null) _chip('★ ${d['rating']} (${d['votes'] ?? 0})'),
                                        if (d['media_type'] == 'tv') _chip('Serie'),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        FilledButton.icon(
                                          onPressed: () => widget.onPlay(
                                            widget.item['url']?.toString() ?? '',
                                            title,
                                          ),
                                          icon: const Icon(Icons.play_arrow),
                                          label: const Text('Jetzt abspielen'),
                                        ),
                                        if (d['trailer']?.toString().isNotEmpty ?? false) ...[
                                          const SizedBox(width: 8),
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              await Clipboard.setData(ClipboardData(
                                                text: 'https://www.youtube.com/watch?v=${d['trailer']}',
                                              ));
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(content: Text('Trailer-Link kopiert')),
                                              );
                                            },
                                            icon: const Icon(Icons.movie_outlined),
                                            label: const Text('Trailer-Link'),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (genres.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Wrap(children: [for (final g in genres) _chip(g.toString())]),
                          ],
                          const SizedBox(height: 14),
                          if (availableSources == null)
                            const SizedBox(
                              width: 140,
                              child: LinearProgressIndicator(),
                            )
                          else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(
                                  width: 100,
                                  child: Text('Verfügbar bei:',
                                      style: TextStyle(fontSize: 12, color: Colors.white54)),
                                ),
                                Expanded(
                                  child: availableSources!.isEmpty
                                      ? const Text('Kein Anbieter',
                                          style: TextStyle(color: Colors.orange, fontSize: 12))
                                      : Wrap(
                                          children: [
                                            for (final source in availableSources!)
                                              Padding(
                                                padding: const EdgeInsets.only(right: 6, bottom: 4),
                                                child: ActionChip(
                                                  label: Text(source['label'] ?? '',
                                                      style: const TextStyle(fontSize: 10)),
                                                  onPressed: (source['url']?.isNotEmpty ?? false)
                                                      ? () => widget.onPlay(
                                                          source['url']!,
                                                          source['label']!,
                                                        )
                                                      : null,
                                                ),
                                              ),
                                          ],
                                        ),
                                ),
                              ],
                            ),
                          if (overview.isNotEmpty) ...[
                            const SizedBox(height: 22),
                            const Text('Handlung', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            Text(overview, style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5)),
                          ],
                          if (cast.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            const Text('Besetzung', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 116,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: cast.length,
                                separatorBuilder: (_, _) => const SizedBox(width: 12),
                                itemBuilder: (ctx, i) {
                                  final c = cast[i] as Map<String, dynamic>;
                                  final img = c['profile_url']?.toString() ?? '';
                                  return GestureDetector(
                                    onTap: () {
                                      final rawId = c['id'];
                                      Navigator.of(context).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => PersonPage(
                                            personId: rawId is int
                                                ? rawId
                                                : int.tryParse(rawId?.toString() ?? ''),
                                            name: c['name']?.toString() ?? '',
                                            api: widget.api,
                                            onOpen: (item) {
                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) => DetailPage(
                                                    item: item,
                                                    api: widget.api,
                                                    onPlay: widget.onPlay,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                    child: SizedBox(
                                      width: 78,
                                      child: Column(
                                        children: [
                                          ClipOval(
                                            child: SizedBox(
                                              width: 64,
                                              height: 64,
                                              child: img.isNotEmpty
                                                  ? Image.network(img, fit: BoxFit.cover,
                                                      errorBuilder: (_, _, _) => Container(color: Colors.grey.shade800))
                                                  : Container(color: Colors.grey.shade800),
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(c['name']?.toString() ?? '', maxLines: 2,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                                          Text(c['character']?.toString() ?? '', maxLines: 1,
                                              textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontSize: 9, color: Colors.white54)),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                          if (seasons.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            const Text('Staffeln & Folgen',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            for (final season in seasons)
                              _seasonTile((season as Map).cast<String, dynamic>()),
                          ],
                          const SizedBox(height: 24),
                          const SizedBox(height: 24),
                          const Text('Meine Bewertung',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              for (var i = 1; i <= 5; i++)
                                IconButton(
                                  tooltip: '$i von 5 Sternen',
                                  icon: Icon(
                                    i <= myRating ? Icons.star : Icons.star_border,
                                    color: Colors.amber,
                                    size: 30,
                                  ),
                                  onPressed: () async {
                                    setState(() => myRating = i);
                                    await prefs.setRating(title, i);
                                    widget.onChanged?.call();
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: noteCtrl,
                            maxLines: 2,
                            decoration: const InputDecoration(
                              hintText: 'Eigene Notiz, z. B. sehr brutal',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => prefs.setNote(title, v),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            children: [
                              'Sehr brutal', 'Brutal', 'Gruselig', 'Lustig', 'Empfehlenswert'
                            ].map((tag) => Padding(
                              padding: const EdgeInsets.only(right: 6, bottom: 4),
                              child: ActionChip(
                                label: Text(tag, style: const TextStyle(fontSize: 10)),
                                onPressed: () {
                                  final current = noteCtrl.text.trim();
                                  final next = current.isEmpty ? tag : '$current, $tag';
                                  noteCtrl.text = next;
                                  prefs.setNote(title, next);
                                  widget.onChanged?.call();
                                  setState(() {});
                                },
                              ),
                            )).toList(),
                          ),
                          const Text('Details', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          _info('Originaltitel', d['original_title']?.toString() ?? ''),
                          _info('Erscheinungsjahr', d['year']?.toString() ?? ''),
                          _info('Erscheinungsdatum', d['release_date']?.toString() ?? ''),
                          _info('Laufzeit', _fmtDuration(runtime)),
                          _info('FSK', d['fsk']?.toString() ?? ''),
                          _info('Genres', (genres.map((g) => g.toString()).join(', '))),
                          _info('Regie', d['director']?.toString() ?? ''),
                          _info('Drehbuch', d['writer']?.toString() ?? ''),
                          _info('Produktion', (d['production_companies'] as List?)?.join(', ') ?? ''),
                          _info('Länder', (d['production_countries'] as List?)?.join(', ') ?? ''),
                          _info('Sprachen', (d['spoken_languages'] as List?)?.join(', ') ?? ''),
                          _info('Status', d['status']?.toString() ?? ''),
                          _info('Budget', _fmtMoney(d['budget'])),
                          _info('Einnahmen', _fmtMoney(d['revenue'])),
                          _info('Beliebtheit', d['popularity']?.toString() ?? ''),
                          _info('IMDb', d['imdb_id']?.toString() ?? ''),
                          if (d['number_of_seasons'] != null)
                            _info('Staffeln', d['number_of_seasons'].toString()),
                          if (d['number_of_episodes'] != null)
                            _info('Folgen', d['number_of_episodes'].toString()),
                          const SizedBox(height: 30),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
