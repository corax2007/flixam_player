import 'dart:convert';
import 'dart:io';

/// Lokale Player-Einstellungen (HLS-Cache), gespeichert im Home-Verzeichnis.
class AppSettings {
  int hlsCacheSeconds;
  int demuxerMaxMb;
  int demuxerBurstMb;
  bool heroInBrowse;
  bool onlyAvailable;
  bool autoPlaySeason;
  int design;
  int layout;
  bool onlyGerman;
  int languageMode;
  int availabilityMode;
  int viewMode;
  int autoPlayDelay;
  int autoPlayLeadSeconds;
  String backendUrl;

  static const String defaultBackendUrl = String.fromEnvironment(
    'FLIXAM_BACKEND_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  AppSettings({
    this.hlsCacheSeconds = 30,
    this.demuxerMaxMb = 128,
    this.demuxerBurstMb = 64,
    this.heroInBrowse = true,
    this.onlyAvailable = true,
    this.autoPlaySeason = false,
    this.design = 0,
    this.layout = 0,
    this.onlyGerman = false,
    this.languageMode = 0,
    this.availabilityMode = 0,
    this.viewMode = 0,
    this.autoPlayDelay = 10,
    this.autoPlayLeadSeconds = 120,
    this.backendUrl = defaultBackendUrl,
  });

  static String get _path =>
      '${Platform.environment['HOME'] ?? '.'}/.flixam_player_settings.json';

  factory AppSettings.load() {
    try {
      final file = File(_path);
      if (file.existsSync()) {
        final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        int val(String key, int fallback) =>
            int.tryParse(map[key]?.toString() ?? '') ?? fallback;
        return AppSettings(
          hlsCacheSeconds: val('hlsCacheSeconds', 30),
          demuxerMaxMb: val('demuxerMaxMb', 128),
          demuxerBurstMb: val('demuxerBurstMb', 64),
          heroInBrowse: map['heroInBrowse'] as bool? ?? true,
          onlyAvailable: map['onlyAvailable'] as bool? ?? true,
          autoPlaySeason: map['autoPlaySeason'] as bool? ?? false,
          design: val('design', 0),
          layout: val('layout', 0),
          onlyGerman: map['onlyGerman'] as bool? ?? false,
          languageMode: (map['languageMode'] as num?)?.toInt() ??
              ((map['onlyGerman'] as bool?) ?? false ? 1 : 0),
          availabilityMode: (map['availabilityMode'] as num?)?.toInt() ?? 0,
          viewMode: (map['viewMode'] as num?)?.toInt() ?? 0,
          autoPlayDelay: (map['autoPlayDelay'] as num?)?.toInt() ?? 10,
          autoPlayLeadSeconds:
              (map['autoPlayLeadSeconds'] as num?)?.toInt() ?? 120,
          backendUrl: map['backendUrl']?.toString().isNotEmpty ?? false
              ? map['backendUrl'].toString()
              : defaultBackendUrl,
        );
      }
    } catch (_) {}
    return AppSettings();
  }

  Future<void> save() async {
    try {
      await File(_path).writeAsString(jsonEncode({
        'hlsCacheSeconds': hlsCacheSeconds,
        'demuxerMaxMb': demuxerMaxMb,
        'demuxerBurstMb': demuxerBurstMb,
        'heroInBrowse': heroInBrowse,
        'onlyAvailable': onlyAvailable,
        'autoPlaySeason': autoPlaySeason,
        'design': design,
        'layout': layout,
        'onlyGerman': onlyGerman,
        'languageMode': languageMode,
        'availabilityMode': availabilityMode,
        'viewMode': viewMode,
        'autoPlayDelay': autoPlayDelay,
        'autoPlayLeadSeconds': autoPlayLeadSeconds,
        'backendUrl': backendUrl,
      }));
    } catch (_) {}
  }
}
