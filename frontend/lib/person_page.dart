import 'package:flutter/material.dart';
import 'services/api_service.dart';

/// Alle Filme/Serien eines Schauspielers (TMDB-Person).
class PersonPage extends StatefulWidget {
  final int? personId;
  final String name;
  final ApiService api;
  final void Function(Map<String, dynamic> item) onOpen;

  const PersonPage({
    super.key,
    this.personId,
    required this.name,
    required this.api,
    required this.onOpen,
  });

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  Map<String, dynamic>? data;
  bool loading = true;
  bool showFullBio = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.api.person(
        id: widget.personId?.toString(),
        name: widget.name,
      );
      if (!mounted) return;
      setState(() {
        data = result;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Widget _chip(String text) {
    return Container(
      margin: const EdgeInsets.only(right: 6, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data ?? {};
    final name = d['name']?.toString() ?? widget.name;
    final profile = d['profile_url']?.toString() ?? '';
    final bio = d['biography']?.toString() ?? '';
    final items = (d['items'] as List?) ?? [];

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0C),
      body: loading
          ? Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverAppBar(
                  expandedHeight: 320,
                  pinned: true,
                  backgroundColor: const Color(0xFF0A0A0C),
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  title: Text(name),
                  flexibleSpace: FlexibleSpaceBar(
                    collapseMode: CollapseMode.pin,
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (profile.isNotEmpty)
                          Image.network(
                            profile,
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
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Wrap(
                          children: [
                            if (d['known_for']?.toString().isNotEmpty ?? false)
                              _chip('Bekannt für: ${d['known_for']}'),
                            if (d['birthday']?.toString().isNotEmpty ?? false)
                              _chip('Geb.: ${d['birthday']}'),
                            if (d['place_of_birth']?.toString().isNotEmpty ?? false)
                              _chip(d['place_of_birth'].toString()),
                            if (d['deathday']?.toString().isNotEmpty ?? false)
                              _chip('† ${d['deathday']}'),
                            _chip('${d['item_count'] ?? items.length} Titel'),
                          ],
                        ),
                        if (bio.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            bio,
                            maxLines: showFullBio ? null : 4,
                            overflow: showFullBio ? null : TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => showFullBio = !showFullBio),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                showFullBio ? 'weniger anzeigen' : 'mehr anzeigen',
                                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'Filmografie',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 150,
                      childAspectRatio: 2 / 3.2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final item = items[i] as Map<String, dynamic>;
                        final poster = item['poster_url']?.toString() ?? '';
                        return GestureDetector(
                          onTap: () => widget.onOpen(item),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: SizedBox(
                                  height: 168,
                                  width: double.infinity,
                                  child: poster.isNotEmpty
                                      ? Image.network(
                                          poster,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => Container(color: Colors.grey.shade900),
                                        )
                                      : Container(color: Colors.grey.shade900),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(item['title']?.toString() ?? '',
                                  maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                              Text(
                                [
                                  if (item['year'] != null) item['year'].toString(),
                                  if (item['rating'] != null) '★ ${item['rating']}',
                                ].join(' · '),
                                style: const TextStyle(fontSize: 9, color: Colors.amber),
                              ),
                              if (item['character']?.toString().isNotEmpty ?? false)
                                Text(item['character'].toString(),
                                    maxLines: 1, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 9, color: Colors.white54)),
                            ],
                          ),
                        );
                      },
                      childCount: items.length,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
