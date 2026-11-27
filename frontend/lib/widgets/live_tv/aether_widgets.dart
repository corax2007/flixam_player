import 'package:flutter/material.dart';
import '../../models/live_tv_viewmodel.dart';

/// AETHER "Warm Dark & Champagne Gold" - nur Farben und Radius,
/// keine App-Logik.
class AetherColors {
  static const background = Color(0xFF0E0D0B);
  static const card = Color(0xFF171512);
  static const active = Color(0xFF211E19);
  static const border = Color(0x29D4AF6E);
  static const accent = Color(0xFFD4AF6E);
  static const text = Color(0xFFF3EFEA);
  static const muted = Color(0xFF9A9287);

  static const cardRadius = Radius.circular(12);
  static const pillRadius = Radius.circular(20);
}

class CategoryFilterBar extends StatelessWidget {
  final List<String> categories;
  final int selected;
  final Set<int> hidden;
  final ValueChanged<int> onSelected;
  final ValueChanged<int> onLongPress;

  const CategoryFilterBar({
    super.key,
    required this.categories,
    required this.selected,
    required this.hidden,
    required this.onSelected,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < categories.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onLongPress: () => onLongPress(i),
                child: ChoiceChip(
                  label: Text(
                    categories[i],
                    style: TextStyle(
                      fontSize: 11,
                      color: hidden.contains(i) ? Colors.redAccent : null,
                      decoration: hidden.contains(i)
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  selected: selected == i,
                  selectedColor: AetherColors.accent.withValues(alpha: 0.22),
                  backgroundColor: AetherColors.card,
                  side: BorderSide(
                    color: selected == i
                        ? AetherColors.accent
                        : AetherColors.border,
                  ),
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.all(AetherColors.pillRadius),
                  ),
                  onSelected: (_) => onSelected(i),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ChannelLogo extends StatelessWidget {
  final String url;
  final String name;
  const ChannelLogo({super.key, required this.url, required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AetherColors.active,
        borderRadius: const BorderRadius.all(AetherColors.cardRadius),
        border: Border.all(color: AetherColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isNotEmpty
          ? Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => _monogram(),
            )
          : _monogram(),
    );
  }

  Widget _monogram() {
    final words = name.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), ' ').split(' ');
    final letters = words
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Center(
      child: Text(
        letters.isEmpty ? 'TV' : letters,
        style: const TextStyle(
          color: AetherColors.accent,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class ChannelListTile extends StatelessWidget {
  final LiveChannelVm channel;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final VoidCallback? onDoubleTap;

  const ChannelListTile({
    super.key,
    required this.channel,
    required this.selected,
    required this.onTap,
    required this.onFavorite,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        height: 76,
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: selected ? AetherColors.active : AetherColors.card,
          borderRadius: const BorderRadius.all(AetherColors.cardRadius),
          border: Border.all(
            color: selected ? AetherColors.accent : AetherColors.border,
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 10),
              child: Row(
                children: [
                  ChannelLogo(url: channel.icon, name: channel.name),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AetherColors.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          channel.program.isEmpty
                              ? 'Keine Programminfo'
                              : 'Jetzt: ${channel.program}'
                                  '${channel.end.isNotEmpty ? ' · bis ${channel.end}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AetherColors.muted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: channel.favorite
                        ? 'Aus Favoriten entfernen'
                        : 'Zu Favoriten',
                    icon: Icon(
                      channel.favorite ? Icons.star : Icons.star_border,
                      size: 18,
                      color: channel.favorite
                          ? AetherColors.accent
                          : AetherColors.muted,
                    ),
                    onPressed: onFavorite,
                  ),
                ],
              ),
            ),
            if (channel.progress > 0)
              Positioned(
                left: 12,
                right: 12,
                bottom: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: channel.progress.clamp(0.0, 1.0),
                    minHeight: 2.5,
                    backgroundColor: AetherColors.border,
                    color: AetherColors.accent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AiHighlightCard extends StatelessWidget {
  final String text;
  const AiHighlightCard({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AetherColors.card,
        borderRadius: const BorderRadius.all(AetherColors.cardRadius),
        border: Border.all(color: AetherColors.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome, size: 15, color: AetherColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AetherColors.text,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EpgInspectorPanel extends StatelessWidget {
  final InspectorVm vm;
  final VoidCallback onPlay;

  const EpgInspectorPanel({super.key, required this.vm, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final c = vm.channel;
    if (c == null) {
      return Container(
        decoration: BoxDecoration(
          color: AetherColors.card.withValues(alpha: 0.75),
          borderRadius: const BorderRadius.all(AetherColors.cardRadius),
          border: Border.all(color: AetherColors.border),
        ),
        child: const Center(
          child: Text(
            'Sender auswählen',
            style: TextStyle(color: AetherColors.muted, fontSize: 12),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(AetherColors.cardRadius),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  vm.backdrop.isNotEmpty
                      ? Image.network(
                          vm.backdrop,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: AetherColors.active,
                          ),
                        )
                      : Container(color: AetherColors.active),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x33000000),
                          Color(0xB3000000),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AetherColors.accent,
                        foregroundColor: AetherColors.background,
                        shape: const RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.all(AetherColors.pillRadius),
                        ),
                      ),
                      onPressed: onPlay,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Stream starten'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            c.name,
            style: const TextStyle(
              color: AetherColors.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            c.program.isEmpty ? 'Keine Programminfo' : c.program,
            style: const TextStyle(color: AetherColors.text, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (vm.year.isNotEmpty)
                _badge(vm.year)
              else if (c.start.isNotEmpty)
                _badge('${c.start} – ${c.end}'),
              for (final g in vm.genres) _badge(g),
              if (vm.rating != null) _badge('★ ${vm.rating!.toStringAsFixed(1)}'),
              if (vm.fsk.isNotEmpty) _badge('FSK ${vm.fsk}'),
              _badge('HD'),
            ],
          ),
          const SizedBox(height: 12),
          if (vm.overview.isNotEmpty)
            Text(
              vm.overview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AetherColors.muted,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          const SizedBox(height: 12),
          AiHighlightCard(text: vm.highlight),
          const SizedBox(height: 12),
          const Text(
            'Danach',
            style: TextStyle(
              color: AetherColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          for (final p in c.upcoming)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      p.start,
                      style: const TextStyle(
                        color: AetherColors.accent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AetherColors.text,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _badge(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: AetherColors.card,
          borderRadius: const BorderRadius.all(AetherColors.cardRadius),
          border: Border.all(color: AetherColors.border),
        ),
        child: Text(
          label,
          style: const TextStyle(color: AetherColors.muted, fontSize: 10),
        ),
      );
}
