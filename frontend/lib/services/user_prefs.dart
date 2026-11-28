import 'dart:convert';
import 'dart:io';

/// Lokale „gesehen"- und Favoriten-Liste (einfach im Home-Verzeichnis).
class UserPrefs {
  final Set<String> seen = {};
  final Set<String> favorites = {};
  final Map<String, Map<String, dynamic>> favoriteItems = {};
  final Map<String, Map<String, dynamic>> playingItems = {};
  final Map<String, int> positions = {};
  final Map<String, int> durations = {};
  final Map<String, int> myRatings = {};
  final Map<String, String> myNotes = {};
  final Set<String> favoriteChannels = {};
  final Set<String> hiddenChannels = {};
  final Set<String> hiddenCategories = {};

  static String get _path =>
      '${Platform.environment['HOME'] ?? '.'}/.flixam_player_prefs.json';

  UserPrefs() {
    try {
      final file = File(_path);
      if (file.existsSync()) {
        final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        for (final v in (map['seen'] as List?) ?? []) {
          seen.add(v.toString());
        }
        for (final v in (map['favorites'] as List?) ?? []) {
          favorites.add(v.toString());
        }
        final items = map['favoriteItems'] as Map<String, dynamic>? ?? {};
        items.forEach((key, value) {
          if (value is Map) {
            favoriteItems[key] = value.cast<String, dynamic>();
          }
        });
        final playing = map['playingItems'] as Map<String, dynamic>? ?? {};
        playing.forEach((key, value) {
          if (value is Map) {
            playingItems[key] = value.cast<String, dynamic>();
          }
        });
        final pos = map['positions'] as Map<String, dynamic>? ?? {};
        pos.forEach((key, value) {
          positions[key] = int.tryParse(value.toString()) ?? 0;
        });
        final dur = map['durations'] as Map<String, dynamic>? ?? {};
        dur.forEach((key, value) {
          durations[key] = int.tryParse(value.toString()) ?? 0;
        });
        final ratings = map['myRatings'] as Map<String, dynamic>? ?? {};
        ratings.forEach((key, value) {
          myRatings[key] = int.tryParse(value.toString()) ?? 0;
        });
        final notes = map['myNotes'] as Map<String, dynamic>? ?? {};
        notes.forEach((key, value) {
          myNotes[key] = value.toString();
        });
        for (final v in (map['favoriteChannels'] as List?) ?? []) {
          favoriteChannels.add(v.toString());
        }
        for (final v in (map['hiddenChannels'] as List?) ?? []) {
          hiddenChannels.add(v.toString());
        }
        for (final v in (map['hiddenCategories'] as List?) ?? []) {
          hiddenCategories.add(v.toString());
        }
      }
    } catch (_) {}
  }

  static String keyOf(Map<String, dynamic> item) =>
      '${item['title']?.toString() ?? ''}|${item['year']?.toString() ?? ''}';

  bool isSeen(Map<String, dynamic> item) => seen.contains(keyOf(item));
  bool isFavorite(Map<String, dynamic> item) => favorites.contains(keyOf(item));

  List<Map<String, dynamic>> favoriteList() => favoriteItems.values.toList();

  int positionFor(String title) => positions[title] ?? 0;

  int durationFor(String title) => durations[title] ?? 0;

  int ratingFor(String title) => myRatings[title] ?? 0;

  Future<void> clearProgress(String title) async {
    positions.remove(title);
    durations.remove(title);
    playingItems.remove(title);
    await _save();
  }

  Future<void> rememberPlaying(Map<String, dynamic> item) async {
    final title = item['title']?.toString() ?? '';
    if (title.isEmpty) return;
    playingItems[title] = Map<String, dynamic>.from(item);
    await _save();
  }

  bool isFavoriteChannel(String title) => favoriteChannels.contains(title);

  bool isChannelHidden(String title) => hiddenChannels.contains(title);

  Future<void> toggleHiddenChannel(String title) async {
    if (!hiddenChannels.remove(title)) hiddenChannels.add(title);
    await _save();
  }

  bool isCategoryHidden(int index) =>
      hiddenCategories.contains(index.toString());

  Future<void> toggleHiddenCategory(int index) async {
    final key = index.toString();
    if (!hiddenCategories.remove(key)) hiddenCategories.add(key);
    await _save();
  }

  Future<void> toggleFavoriteChannel(String title) async {
    if (!favoriteChannels.remove(title)) favoriteChannels.add(title);
    await _save();
  }

  Future<void> addFavoriteChannels(Iterable<String> titles) async {
    favoriteChannels.addAll(titles);
    await _save();
  }
  String noteFor(String title) => myNotes[title] ?? '';

  Future<void> setRating(String title, int rating) async {
    if (myRatings[title] == rating) return;
    myRatings[title] = rating;
    await _save();
  }

  Future<void> setNote(String title, String note) async {
    if (myNotes[title] == note) return;
    myNotes[title] = note;
    await _save();
  }

  Future<void> savePosition(String title, int seconds) async {
    if (positions[title] == seconds) return;
    positions[title] = seconds;
    await _save();
  }

  Future<void> saveDuration(String title, int seconds) async {
    if (durations[title] == seconds) return;
    durations[title] = seconds;
    await _save();
  }

  Future<void> toggleSeen(Map<String, dynamic> item) async {
    final key = keyOf(item);
    if (!seen.remove(key)) seen.add(key);
    await _save();
  }

  Future<void> toggleFavorite(Map<String, dynamic> item) async {
    final key = keyOf(item);
    if (!favorites.remove(key)) {
      favorites.add(key);
      favoriteItems[key] = Map<String, dynamic>.from(item);
    } else {
      favoriteItems.remove(key);
    }
    await _save();
  }

  Future<void> _save() async {
    try {
      await File(_path).writeAsString(jsonEncode({
        'seen': seen.toList(),
        'favorites': favorites.toList(),
        'favoriteItems': favoriteItems,
        'playingItems': playingItems,
        'positions': positions,
        'durations': durations,
        'myRatings': myRatings,
        'myNotes': myNotes,
        'favoriteChannels': favoriteChannels.toList(),
        'hiddenChannels': hiddenChannels.toList(),
        'hiddenCategories': hiddenCategories.toList(),
      }));
    } catch (_) {}
  }
}
