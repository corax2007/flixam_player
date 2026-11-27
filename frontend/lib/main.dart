import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'services/process_manager.dart';
import 'services/api_service.dart';
import 'services/settings_service.dart';
import 'services/theme_service.dart';
import 'services/user_prefs.dart';
import 'services/browser_resolver.dart';
import 'services/availability_service.dart';
import 'services/custom_sources.dart';
import 'services/tmdb_service.dart';
import 'services/gez_kino_service.dart';
import 'services/trailer_service.dart';
import 'services/recently_added_service.dart';
import 'widgets/tv_focusable.dart';
import 'trailer_page.dart';
import 'detail_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  Future<void> shutdown(ProcessSignal signal) async {
    await ProcessManager.instance.stopAll();
    exit(0);
  }

  if (!Platform.isAndroid) {
    ProcessSignal.sigterm.watch().listen(shutdown);
    ProcessSignal.sigint.watch().listen(shutdown);
  }
  runApp(const FlixamApp());
}

class FlixamApp extends StatefulWidget {
  const FlixamApp({super.key});
  @override
  State<FlixamApp> createState() => _FlixamAppState();
}

class _FlixamAppState extends State<FlixamApp> {
  final AppSettings settings = AppSettings.load();

  void _onDesignChanged(int index) {
    setState(() => settings.design = index);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flixam_player',
      theme: flixamTheme(settings.design),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(Platform.isAndroid ? 1.25 : 1.0),
          ),
          child: HomePage(
            settings: settings,
            onDesignChanged: _onDesignChanged,
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final AppSettings? settings;
  final ValueChanged<int>? onDesignChanged;

  const HomePage({super.key, this.settings, this.onDesignChanged});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ApiService api = ApiService();
  late final AppSettings appSettings = widget.settings ?? AppSettings.load();
  final UserPrefs prefs = UserPrefs();
  final Player player = Player();
  late final VideoController videoController = VideoController(player);
  bool connected = false;
  bool vpnEnabled = false;
  bool vpnActive = false;
  bool hasVpnConfig = false;
  String ip = '';
  String addon = 'xstream';
  String selectedSource = 'Alle';
  List<dynamic> streamingProviders = [];
  int? selectedProviderId;
  String? selectedProviderName;
  List<dynamic> providerMovies = [];
  String providerFilter = 'Alle';
  bool providerLoading = false;
  bool showHome = true;
  bool showFavorites = false;
  bool showSourceEpisodes = false;
  String? sourceEpisodesLabel;
  String sourceEpisodesTitle = '';
  List<dynamic> sourceEpisodeSeasons = [];
  Map<String, dynamic>? homeData;
  String? expandedSection;
  final Map<String, List<dynamic>> _fullSections = {};
  final Set<String> _loadingSections = {};
  List<dynamic> results = [];
  List<dynamic> rawResults = [];
  Map<String, dynamic>? rawHomeData;
  List<dynamic> rawProviderMovies = [];
  String fskFilter = 'Alle';
  String monthFilter = 'Alle';
  String sortOrder = 'Standard';
  String currentTitle = '';
  final List<Map<String, dynamic>> _navStack = [];
  String? currentFolderUrl;
  String? currentFolderTitle;
  bool allEpisodesView = false;
  final TextEditingController searchCtrl = TextEditingController();
  final TextEditingController yearCtrl = TextEditingController();
  final TextEditingController cacheCtrl = TextEditingController();
  final TextEditingController demuxMaxCtrl = TextEditingController();
  final TextEditingController demuxBurstCtrl = TextEditingController();
  final TextEditingController backendCtrl = TextEditingController();
  List<dynamic> genres = [];
  String? selectedGenre;
  String filterType = '';
  final TextEditingController tmdbCtrl = TextEditingController();
  bool loading = false;
  bool showPlayer = false;
  String nowPlaying = '';
  dynamic selectedItem;
  dynamic heroItem;
  double playerVolume = 100;
  Duration playerPosition = Duration.zero;
  Duration playerDuration = Duration.zero;
  bool playerControlsVisible = true;
  Timer? _controlsTimer;
  String? currentPlayingTitle;
  bool _resumePending = false;
  int _resumeSeconds = 0;
  int _lastSavedSecond = 0;
  /// Titel der Medien in der aktuellen Wiedergabeliste (Staffel am Stueck).
  final List<String> _queueTitles = [];
  List<Map<String, String>> heroSources = [];
  String? heroTrailerKey;
  bool heroSourcesLoading = false;
  StreamSubscription<double>? _volumeSub;
  Timer? _autoRefreshTimer;

  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    cacheCtrl.text = appSettings.hlsCacheSeconds.toString();
    demuxMaxCtrl.text = appSettings.demuxerMaxMb.toString();
    demuxBurstCtrl.text = appSettings.demuxerBurstMb.toString();
    backendCtrl.text = appSettings.backendUrl;
    api.baseUrl = appSettings.backendUrl;
    _volumeSub = player.stream.volume.listen((v) {
      if (mounted) setState(() => playerVolume = v);
    });
    player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => playerPosition = p);
      if (currentPlayingTitle != null && p.inSeconds - _lastSavedSecond >= 10) {
        _lastSavedSecond = p.inSeconds;
        prefs.savePosition(currentPlayingTitle!, p.inSeconds);
      }
    });
    player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => playerDuration = d);
      if (d.inSeconds > 0 && currentPlayingTitle != null) {
        prefs.saveDuration(currentPlayingTitle!, d.inSeconds);
      }
      if (_resumePending && d.inSeconds > 0) {
        _resumePending = false;
        player.seek(Duration(seconds: _resumeSeconds));
      }
    });
    player.stream.completed.listen((completed) {
      if (completed && currentPlayingTitle != null) {
        prefs.savePosition(currentPlayingTitle!, 0);
      }
    });
    // Bei mehreren Folgen in der Wiedergabeliste Titel/Position pro Folge
    // umschalten, damit "Fortsetzen" auch bei Dauerbetrieb stimmt.
    player.stream.playlist.listen((playlist) {
      if (!mounted || _queueTitles.isEmpty) return;
      final i = playlist.index;
      if (i >= 0 && i < _queueTitles.length) {
        final t = _queueTitles[i];
        if (currentPlayingTitle != t) {
          setState(() {
            currentPlayingTitle = t;
            nowPlaying = t;
            playerPosition = Duration.zero;
            playerDuration = Duration.zero;
          });
          _lastSavedSecond = 0;
        }
      }
    });
    _listener = AppLifecycleListener(onExitRequested: () async {
      await ProcessManager.instance.stopAll();
      return AppExitResponse.exit;
    });
    _start();
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted && showHome) _refreshAll();
    });
  }

  Future<void> _refreshAll() async {
    TmdbService.instance.reload();
    AvailabilityService.instance.reload();
    GezKinoService.instance.reload();
    RecentlyAddedService.instance.reload();
    setState(() => loading = true);
    await _loadGenres();
    await _loadStreamingProviders();
    await _loadHome(force: true);
    if (mounted) setState(() => loading = false);
  }

  Future<void> _start() async {
    if (Platform.isAndroid) {
      // Phase 3: komplett ohne Linux-Backend - TMDB & Streams direkt aus Dart.
      api.useDirect = true;
    } else {
      await ProcessManager.instance.startAll(baseUrl: appSettings.backendUrl);
      await _refreshVpn();
    }
    await _loadGenres();
    await _loadStreamingProviders();
    await _loadHome();
  }

  Future<void> _loadHome({bool force = false}) async {
    setState(() => loading = true);
    try {
      var data = await api.home(force: force);
      if (Platform.isAndroid && appSettings.onlyAvailable) {
        data = await AvailabilityService.instance.filterHome(data);
      }
      if (!mounted) return;
      setState(() {
        rawHomeData = data;
        homeData = data;
        showHome = true;
        loading = false;
      });
      final heroTitle = heroItem is Map
          ? heroItem['title']?.toString() ?? ''
          : ((data['hero'] as Map?)?['title']?.toString() ?? '');
      _loadHeroSources(heroTitle);
      _loadHeroTrailer(heroItem ?? (data['hero'] as Map?) ?? {});
      await _refreshFilteredViews();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        showHome = false;
        loading = false;
      });
    }
  }

  Future<void> _goHome() async {
    setState(() {
      showHome = true;
      showFavorites = false;
      showSourceEpisodes = false;
      heroItem = null;
      heroSources = [];
      heroTrailerKey = null;
      _navStack.clear();
      currentFolderUrl = null;
      currentFolderTitle = null;
      allEpisodesView = false;
    });
    await _loadHome(force: true);
  }

  Future<void> _loadGenres() async {
    try {
      final items = await api.genres(type: filterType == 'tv' ? 'tv' : 'movie');
      if (!mounted) return;
      setState(() {
        genres = items;
        if (selectedGenre != null &&
            !items.any((g) => g['name'] == selectedGenre)) {
          selectedGenre = null;
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _controlsTimer?.cancel();
    _volumeSub?.cancel();
    _listener.dispose();
    player.dispose();
    super.dispose();
  }

  Future<void> _refreshVpn() async {
    final s = await api.vpnStatus();
    setState(() {
      connected = s['connected'] == true;
      vpnEnabled = s['enabled'] == true;
      vpnActive = s['connected'] == true;
      hasVpnConfig = s['has_config'] == true;
      ip = s['ip']?.toString() ?? '';
    });
  }

  Future<void> _search() async {
    setState(() => loading = true);
    final items = await api.search(
      addon,
      searchCtrl.text,
      year: yearCtrl.text,
      genre: selectedGenre,
      type: filterType,
      source: Platform.isAndroid ? selectedSource : null,
    );
    setState(() {
      showHome = false;
      showFavorites = false;
      showSourceEpisodes = false;
      heroItem = null;
      heroSources = [];
      heroTrailerKey = null;
      _navStack.clear();
      currentFolderUrl = null;
      currentFolderTitle = null;
      allEpisodesView = false;
      currentTitle = 'Suche: ${searchCtrl.text}';
      rawResults = items;
      results = items;
      loading = false;
    });
    await _refreshFilteredViews();
  }

  Future<void> _browseRoot() async {
    setState(() => loading = true);
    final items = <dynamic>[
      {
        'title': 'GEZ Kino',
        'url': 'flixam://browse/gezkino',
        'isFolder': true,
        'overview': 'Spielfilme aus den öffentlich-rechtlichen Mediatheken',
      },
      {
        'title': 'TMDB Trailers',
        'url': 'flixam://browse/trailer',
        'isFolder': true,
        'overview': 'Trailer beliebter Filme',
      },
      {
        'title': 'Eigene Quellen',
        'url': 'flixam://browse/custom',
        'isFolder': true,
        'overview': 'Quellen aus ~/.flixam_sources.json',
      },
      ...await api.browse(addon),
    ];
    setState(() {
      showHome = false;
      showFavorites = false;
      showSourceEpisodes = false;
      heroItem = null;
      heroSources = [];
      heroTrailerKey = null;
      _navStack.clear();
      currentFolderUrl = null;
      currentFolderTitle = null;
      allEpisodesView = false;
      currentTitle = 'Browse';
      rawResults = items;
      results = items;
      loading = false;
    });
    await _refreshFilteredViews();
  }

  /// In einen Ordner (Staffel, Folge, Hosterliste) navigieren.
  /// Serien-Ordner zeigen direkt alle Episoden aller Staffeln.
  Future<String?> _askCustomSearch(String name) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Suche in $name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Suchbegriff'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Suche')),
        ],
      ),
    );
    return ok == true ? controller.text.trim() : null;
  }

  Future<List<dynamic>> _specialBrowseItems(String url) async {
    final rest = url.substring('flixam://browse/'.length);
    if (rest == 'gezkino') {
      final all = await GezKinoService.instance.load();
      return all.whereType<Map<String, dynamic>>().take(400).map((m) {
        return {
          'title': m['title']?.toString() ?? '',
          'year': m['year']?.toString(),
          'poster_url': m['thumb']?.toString() ?? '',
          'backdrop_url': m['thumb']?.toString() ?? '',
          'overview': m['plot']?.toString() ?? '',
          'rating': m['rating'],
          'media_type': 'movie',
          'isFolder': false,
          'source': 'GEZ Kino',
          'url': m['video_url']?.toString() ?? '',
        };
      }).toList();
    }
    if (rest == 'trailer') {
      return (await TrailerService.instance.popular()).cast<dynamic>();
    }
    if (rest == 'custom') {
      final sources = await CustomSources.instance.load();
      return sources.asMap().entries.map((e) {
        final s = e.value as Map<String, dynamic>;
        return {
          'title': s['name']?.toString() ?? 'Quelle ${e.key + 1}',
          'url': 'flixam://browse/custom/${e.key}',
          'isFolder': true,
          'overview': s['searchUrl']?.toString() ?? '',
        };
      }).toList();
    }
    if (rest.startsWith('custom/')) {
      final index = int.tryParse(rest.substring(7));
      final source = CustomSources.instance.sourceAt(index ?? 0);
      final name = source?['name']?.toString() ?? 'Eigene Quelle';
      final term = await _askCustomSearch(name);
      if (term == null || term.isEmpty) return [];
      final found = await CustomSources.instance.search(term);
      return found.where((i) => i['source'] == name).cast<dynamic>().toList();
    }
    return [];
  }

  Future<void> _browseInto(String url, String title) async {
    final isSeries = url.contains('function=showSeasons');
    _navStack.add({
      'results': results,
      'title': currentTitle,
      'url': currentFolderUrl,
      'folderTitle': currentFolderTitle,
      'all': allEpisodesView,
    });
    setState(() {
      loading = true;
      showHome = false;
      showFavorites = false;
      showSourceEpisodes = false;
      heroItem = null;
      heroSources = [];
      heroTrailerKey = null;
      currentFolderUrl = url;
      currentFolderTitle = title;
      allEpisodesView = isSeries;
      currentTitle = isSeries ? '$title – Alle Episoden' : title;
    });
    try {
      final items = url.startsWith('flixam://browse/')
          ? await _specialBrowseItems(url)
          : isSeries
              ? await api.allEpisodes(addon, url)
              : await api.browse(addon, url: url);
      if (!mounted) return;
      rawResults = items;
      setState(() {
        results = items;
        loading = false;
      });
      await _refreshFilteredViews();
    } catch (e) {
      // Fallback: wenn die Sammelansicht scheitert, die Staffeln zeigen.
      if (!mounted) return;
      if (isSeries) {
        try {
          final items = await api.browse(addon, url: url);
          if (!mounted) return;
          rawResults = items;
          setState(() {
            allEpisodesView = false;
            currentTitle = title;
            results = items;
            loading = false;
          });
          await _refreshFilteredViews();
          return;
        } catch (_) {}
      }
      setState(() => loading = false);
      await _showPlaybackError('Ordner konnte nicht geladen werden.\n\n$e', title);
    }
  }

  Future<void> _toggleEpisodeView() async {
    final url = currentFolderUrl;
    if (url == null || !url.contains('function=showSeasons')) return;
    final showAll = !allEpisodesView;
    setState(() => loading = true);
    try {
      final items = showAll
          ? await api.allEpisodes(addon, url)
          : await api.browse(addon, url: url);
      if (!mounted) return;
      setState(() {
        allEpisodesView = showAll;
        currentTitle = showAll
            ? '${currentFolderTitle ?? ''} – Alle Episoden'
            : currentFolderTitle ?? currentTitle;
        results = items;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      await _showPlaybackError('Ansicht konnte nicht geladen werden.\n\n$e', 'Episoden');
    }
  }

  void _goBack() {
    if (_navStack.isEmpty) return;
    final prev = _navStack.removeLast();
    setState(() {
      heroItem = null;
      heroSources = [];
      heroTrailerKey = null;
      results = prev['results'] as List<dynamic>;
      currentTitle = prev['title'] as String;
      currentFolderUrl = prev['url'] as String?;
      currentFolderTitle = prev['folderTitle'] as String?;
      allEpisodesView = prev['all'] as bool;
    });
  }

  Future<void> _play(String url, String title, {bool resume = false}) async {
    // Alte Favoriten/Items können Dart-URLs enthalten - das Linux-Backend
    // versteht nur plugin://-URLs.
    if (!api.useDirect && url.startsWith('flixam://')) {
      if (url.startsWith('flixam://tmdb/')) {
        url = 'plugin://flixam/${url.substring("flixam://".length)}';
      } else {
        url = 'plugin://flixam/search/${Uri.encodeComponent(title)}';
      }
    }
    if (url.startsWith('youtube://')) {
      _openTrailer(url.substring('youtube://'.length), title);
      return;
    }
    Map<String, dynamic> resolved;
    try {
      resolved = await api.resolve(url);
    } catch (e) {
      await _showPlaybackError('Der Stream konnte nicht aufgelöst werden.\n\n$e', title);
      return;
    }
    final streamUrl = (resolved['stream_url'] ?? '').toString();
    final headers = Map<String, String>.from(resolved['headers'] ?? {});
    if (streamUrl.isEmpty) {
      final msg = (resolved['message'] ?? 'Kein abspielbarer Stream gefunden').toString();
      await _showPlaybackError(msg, title);
      return;
    }
    if (vpnEnabled) {
      try {
        (player.platform as dynamic)?.setProperty?.call('http-proxy', 'http://127.0.0.1:8080');
      } catch (_) {}
    }
    // HLS braucht einen groesseren Puffer, sonst ruckeln Hoster-Streams.
    for (final entry in {
      'cache-secs': appSettings.hlsCacheSeconds.toString(),
      'demuxer-max-bytes': '${appSettings.demuxerMaxMb}MiB',
      'demuxer-max-burst-bytes': '${appSettings.demuxerBurstMb}MiB',
    }.entries) {
      try {
        await (player.platform as dynamic)?.setProperty?.call(entry.key, entry.value);
      } catch (_) {}
    }
    try {
      await player.open(Media(streamUrl, httpHeaders: headers));
      await player.play();
      _queueTitles
        ..clear()
        ..add(title);
      currentPlayingTitle = title;
      _lastSavedSecond = 0;
      final saved = resume ? prefs.positionFor(title) : 0;
      if (saved > 30) {
        _resumePending = true;
        _resumeSeconds = saved;
      }
    } catch (e) {
      await _showPlaybackError('Der Player konnte den Stream nicht öffnen.\n\n$e', title);
      return;
    }
    setState(() {
      showPlayer = true;
      nowPlaying = title;
      playerPosition = Duration.zero;
      playerDuration = Duration.zero;
    });
    _showPlayerControls();
  }

  /// Mehrere Folgen nacheinander in die Wiedergabeliste laden - ohne
  /// Pause zwischen den Episoden.
  Future<void> _playEpisodes(List<Map<String, dynamic>> episodes) async {
    if (episodes.isEmpty) return;
    final first = episodes.first;
    await _play(first['url']?.toString() ?? '',
        first['title']?.toString() ?? 'Folge');
    for (final ep in episodes.skip(1)) {
      try {
        final r = await api.resolve(ep['url']?.toString() ?? '');
        final stream = r['stream_url']?.toString() ?? '';
        if (stream.isEmpty) continue;
        await player.add(Media(
          stream,
          httpHeaders: Map<String, String>.from(r['headers'] ?? {}),
        ));
        _queueTitles.add(ep['title']?.toString() ?? 'Folge');
      } catch (_) {}
    }
  }

  /// Folgen derselben Staffel ab der angeklickten Episode (Quellenansicht).
  List<Map<String, dynamic>> _sourceFollowingEpisodes(
      Map<String, dynamic> ep) {
    final queue = <Map<String, dynamic>>[];
    bool started = false;
    for (final s in sourceEpisodeSeasons) {
      final season = s as Map<String, dynamic>;
      if (started && season['season'] != ep['season']) break;
      for (final e in ((season['episodes'] as List?) ?? [])) {
        final m = (e as Map).cast<String, dynamic>();
        if (!started &&
            m['season'] == ep['season'] &&
            m['episode'] == ep['episode']) {
          started = true;
        }
        if (started) queue.add(m);
      }
    }
    return queue;
  }

  String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0
        ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _resumeInfo(String title, {double width = 180}) {
    final pos = prefs.positionFor(title);
    final dur = prefs.durationFor(title);
    if (pos <= 30 || dur <= pos + 10) return const SizedBox.shrink();
    final rest = dur - pos;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: (pos / dur).clamp(0.0, 1.0),
            minHeight: 4,
          ),
          const SizedBox(height: 3),
          Text(
            'Fortsetzen ${_fmtClock(Duration(seconds: pos))} · noch ${_fmtClock(Duration(seconds: rest))}',
            style: const TextStyle(fontSize: 10, color: Colors.lightGreenAccent),
          ),
        ],
      ),
    );
  }

  String _endClock() {
    if (playerDuration.inSeconds == 0) return '';
    final end = DateTime.now().add(playerDuration - playerPosition);
    return '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
  }

  void _showPlayerControls() {
    if (!mounted) return;
    setState(() => playerControlsVisible = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && showPlayer) {
        setState(() => playerControlsVisible = false);
      }
    });
  }

  Future<void> _showPlaybackError(String message, String title) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wiedergabe nicht möglich'),
        content: Text('$message\n\n$title'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _reconnect() async {
    await ProcessManager.instance.restartWireproxy();
    await Future.delayed(const Duration(seconds: 3));
    await _refreshVpn();
  }

  Future<void> _importConf() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eigene .conf importieren'),
        content: TextField(controller: ctrl, maxLines: 10),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Importieren')),
        ],
      ),
    );
    if (ok == true) {
      await api.importConfig(ctrl.text);
      await _reconnect();
    }
  }

  Future<void> _toggleVpn(bool enabled) async {
    await api.vpnToggle(enabled);
    if (enabled) {
      await ProcessManager.instance.startWireproxy();
    } else {
      await ProcessManager.instance.stopWireproxy();
    }
    await _refreshVpn();
  }

  Future<void> _saveTmdb(String key) async {
    await api.saveTmdbKey(key);
  }

  Future<void> _saveCacheSettings() async {
    appSettings.hlsCacheSeconds = int.tryParse(cacheCtrl.text.trim()) ?? 30;
    appSettings.demuxerMaxMb = int.tryParse(demuxMaxCtrl.text.trim()) ?? 128;
    appSettings.demuxerBurstMb = int.tryParse(demuxBurstCtrl.text.trim()) ?? 64;
    await appSettings.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Player-Einstellungen gespeichert')),
    );
  }

  Widget _layoutPreview(int index, {required bool selected}) {
    final d = designAt(appSettings.design);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: d.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? d.accent : Colors.white24,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: index == 0
              ? Column(
                  children: [
                    Container(height: 12, width: double.infinity, color: d.surface),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            Expanded(flex: 3, child: Container(color: d.accent.withValues(alpha: 0.5))),
                            const SizedBox(width: 3),
                            Expanded(child: Container(color: d.surface)),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Container(width: 12, color: d.surface,
                        child: Column(
                          children: [
                            Container(height: 4, width: 4, color: d.accent),
                            const SizedBox(height: 3),
                            Container(height: 2, width: 6, color: Colors.white38),
                            const SizedBox(height: 2),
                            Container(height: 2, width: 6, color: Colors.white38),
                          ],
                        ),
                      ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Container(color: d.accent.withValues(alpha: 0.5)),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 3),
        Text(
          flixamLayouts[index].name,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 9, color: selected ? d.accent : Colors.white70),
        ),
      ],
    );
  }

  Widget _designPreview(FlixamDesign d, {required bool selected}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 56,
          decoration: BoxDecoration(
            color: d.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? d.accent : Colors.white24,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 30,
                width: double.infinity,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    d.surface,
                    d.accent.withValues(alpha: 0.5),
                  ]),
                ),
                child: Container(
                  width: 26,
                  height: 4,
                  color: Colors.white70,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                child: Row(
                  children: [
                    Container(width: 12, height: 12, color: d.surface),
                    const SizedBox(width: 3),
                    Container(width: 12, height: 12, color: d.surface),
                    const SizedBox(width: 3),
                    Container(width: 12, height: 12, color: d.accent),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Text(
          d.name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 9,
            color: selected ? d.accent : Colors.white70,
          ),
        ),
      ],
    );
  }

  Future<void> _showSettings() async {
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) {
        return CupertinoApp(
          theme: const CupertinoThemeData(brightness: Brightness.dark),
          home: CupertinoPageScaffold(
            backgroundColor: bg(context),
            navigationBar: CupertinoNavigationBar(
              backgroundColor: bg(context),
              middle: const Text('Einstellungen'),
              leading: CupertinoNavigationBarBackButton(),
              trailing: SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  icon: const Icon(CupertinoIcons.xmark_circle_fill, size: 24),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
            child: CallbackShortcuts(
              bindings: {
                SingleActivator(LogicalKeyboardKey.escape): () {
                  Navigator.of(ctx).maybePop();
                },
              },
              child: SafeArea(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      const Text('Layout',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          for (var i = 0; i < flixamLayouts.length; i++) ...[
                            Expanded(
                              child: GestureDetector(
                                onTap: () async {
                                  setState(() => appSettings.layout = i);
                                  await appSettings.save();
                                  setState(() {});
                                },
                                child: _layoutPreview(i, selected: appSettings.layout == i),
                              ),
                            ),
                            if (i < flixamLayouts.length - 1) const SizedBox(width: 8),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text('Design',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (var i = 0; i < flixamDesigns.length; i++) ...[
                            Expanded(
                              child: GestureDetector(
                                onTap: () async {
                                  setState(() => appSettings.design = i);
                                  await appSettings.save();
                                  widget.onDesignChanged?.call(i);
                                },
                                child: _designPreview(
                                  flixamDesigns[i],
                                  selected: appSettings.design == i,
                                ),
                              ),
                            ),
                            if (i < flixamDesigns.length - 1)
                              const SizedBox(width: 8),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (!Platform.isAndroid) ...[
                        const Text('VPN-Tunnel aktivieren (wireproxy)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        CupertinoSwitch(
                          value: vpnEnabled,
                          onChanged: (v) async => _toggleVpn(v),
                        ),
                        const SizedBox(height: 8),
                        Text('wireproxy läuft: ${File('/home/joerg/flixam_player/vpn/wireproxy').existsSync() ? 'ja' : 'nein'}'),
                        if (!hasVpnConfig)
                          const Text('wg0.conf fehlt oder ist unvollständig.',
                              style: TextStyle(color: Colors.orange)),
                        const SizedBox(height: 12),
                        CupertinoButton(
                          onPressed: () => _importConf(),
                          child: const Text('WireGuard-Config (.conf) importieren'),
                        ),
                      ],
                      const SizedBox(height: 8),
                      if (!Platform.isAndroid) ...[
                        CupertinoTextField(
                          controller: tmdbCtrl,
                          decoration: const BoxDecoration(),
                          placeholder: 'TMDB API Key',
                        ),
                        const SizedBox(height: 8),
                        CupertinoButton(
                          onPressed: () async {
                            await _saveTmdb(tmdbCtrl.text);
                          },
                          child: const Text('TMDB API Key speichern'),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text('Backend-Adresse (Fire TV / LAN)',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        controller: backendCtrl,
                        decoration: const BoxDecoration(),
                        placeholder: 'http://192.168.1.10:8000',
                      ),
                      const SizedBox(height: 8),
                      CupertinoButton(
                        onPressed: () async {
                          final url = backendCtrl.text.trim().isEmpty
                              ? AppSettings.defaultBackendUrl
                              : backendCtrl.text.trim();
                          setState(() {
                            appSettings.backendUrl = url;
                            api.baseUrl = url;
                          });
                          await appSettings.save();
                          await _loadHome();
                        },
                        child: const Text('Backend-Adresse speichern'),
                      ),
                      const SizedBox(height: 16),
                      const Text('HLS-Cache', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const SizedBox(width: 130, child: Text('Puffer (Sek.)')),
                          SizedBox(width: 90, child: CupertinoTextField(controller: cacheCtrl, keyboardType: TextInputType.number)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const SizedBox(width: 130, child: Text('Max. Cache (MB)')),
                          SizedBox(width: 90, child: CupertinoTextField(controller: demuxMaxCtrl, keyboardType: TextInputType.number)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const SizedBox(width: 130, child: Text('Burst (MB)')),
                          SizedBox(width: 90, child: CupertinoTextField(controller: demuxBurstCtrl, keyboardType: TextInputType.number)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      CupertinoButton(
                        onPressed: _saveCacheSettings,
                        child: const Text('Cache-Einstellungen speichern'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Staffel ohne Pause abspielen'),
                                Text(
                                  'Folgen automatisch nacheinander',
                                  style: TextStyle(fontSize: 10, color: Colors.white54),
                                ),
                              ],
                            ),
                          ),
                          CupertinoSwitch(
                            value: appSettings.autoPlaySeason,
                            onChanged: (v) async {
                              setState(() => appSettings.autoPlaySeason = v);
                              await appSettings.save();
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Expanded(child: Text('Hero-Details beim Browse')),
                          CupertinoSwitch(
                            value: appSettings.heroInBrowse,
                            onChanged: (v) async {
                              setState(() => appSettings.heroInBrowse = v);
                              await appSettings.save();
                            },
                          ),
                        ],
                      ),
                      if (Platform.isAndroid)
                        Row(
                          children: [
                            const Expanded(child: Text('Nur verfügbare Titel zeigen')),
                            CupertinoSwitch(
                              value: appSettings.onlyAvailable,
                              onChanged: (v) async {
                                setState(() => appSettings.onlyAvailable = v);
                                await appSettings.save();
                                await _loadHome();
                              },
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      Text(
                        'Eigene Quellen: ${CustomSources.path}',
                        style: const TextStyle(fontSize: 10, color: Colors.white54),
                      ),
                      CupertinoButton(
                        onPressed: () async {
                          await CustomSources.instance.reload();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Eigene Quellen neu geladen')),
                            );
                          }
                        },
                        child: const Text('Eigene Quellen neu laden'),
                      ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (confirmed == true) {
      // no-op
    }
  }

  Future<void> _showItemMenuLongPress(Map<String, dynamic> item) =>
      _showItemMenu(
        TapDownDetails(globalPosition: const Offset(320, 320)),
        item,
      );

  /// Rechtsklick-Menü auf Covers (Kodi-artig).
  Future<void> _showItemMenu(TapDownDetails details, Map<String, dynamic> item) async {
    final title = item['title']?.toString() ?? '';
    final value = await showMenu<String>(
      context: context,
      color: surf(context),
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(value: 'trailer', child: Text('Trailer')),
        const PopupMenuItem(value: 'tmdb', child: Text('TMDB Info')),
        const PopupMenuItem(value: 'sources', child: Text('Weitere Quellen')),
        const PopupMenuItem(value: 'info', child: Text('Informationen')),
        PopupMenuItem(
          value: 'seen',
          child: Text(prefs.isSeen(item) ? 'Als „ungesehen" markieren' : 'Als „gesehen" markieren'),
        ),
        PopupMenuItem(
          value: 'fav',
          child: Text(prefs.isFavorite(item) ? 'Aus Favoriten entfernen' : 'Zu Favoriten hinzufügen'),
        ),
        const PopupMenuItem(value: 'resume', child: Text('Ab hier wiedergeben')),
      ],
    );
    if (value == null || !mounted) return;
    switch (value) {
      case 'trailer':
        try {
          final d = await api.details(
            title: title,
            year: item['year']?.toString(),
            type: item['media_type']?.toString(),
          );
          final key = d['trailer']?.toString() ?? '';
          if (!mounted) return;
          if (key.isEmpty) {
            await _showPlaybackError('Kein Trailer verfügbar', title);
          } else {
            await Clipboard.setData(
              ClipboardData(text: 'https://www.youtube.com/watch?v=$key'),
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Trailer-Link kopiert')),
              );
            }
          }
        } catch (e) {
          if (mounted) await _showPlaybackError('Trailer nicht verfügbar.\n\n$e', title);
        }
        break;
      case 'tmdb':
        setState(() => selectedItem = item);
        _showDetail();
        break;
      case 'sources':
        await _showSources(item);
        break;
      case 'info':
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item['year'] != null) Text('Jahr: ${item['year']}'),
                  if (item['rating'] != null) Text('Bewertung: ★ ${item['rating']}'),
                  if (item['media_type'] != null) Text('Typ: ${item['media_type']}'),
                  const SizedBox(height: 10),
                  Text(item['overview']?.toString() ?? 'Keine Beschreibung vorhanden.'),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
            ],
          ),
        );
        break;
      case 'seen':
        await prefs.toggleSeen(item);
        if (mounted) setState(() {});
        break;
      case 'fav':
        await prefs.toggleFavorite(item);
        if (mounted) setState(() {});
        break;
      case 'resume':
        await _play(item['url']?.toString() ?? '', title);
        break;
    }
  }

  /// Dialog mit Treffern aus verschiedenen Sites/Quellen.
  Future<void> _showSources(Map<String, dynamic> item) async {
    final clean = (item['title']?.toString() ?? '').replaceAll(
      RegExp(r'\[I\].*?\[/I\]'), '',
    ).trim();
    if (clean.isEmpty) return;
    setState(() => loading = true);
    List<dynamic> items = [];
    try {
      items = await api.search('xstream', clean);
    } catch (_) {}
    if (!mounted) return;
    setState(() => loading = false);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Weitere Quellen: $clean'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: items.isEmpty
              ? const Center(child: Text('Keine weiteren Quellen gefunden'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (ctx, i) {
                    final it = (items[i] as Map).cast<String, dynamic>();
                    return ListTile(
                      title: Text(it['title']?.toString() ?? ''),
                      subtitle: Text(it['url']?.toString() ?? '', maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onTap: () {
                        Navigator.pop(ctx);
                        _play(it['url']?.toString() ?? '',
                            it['title']?.toString() ?? clean);
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
        ],
      ),
    );
  }

  void _showDetail() {
    final item = selectedItem;
    if (item == null) return;
    final map = item.cast<String, dynamic>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          item: map,
          api: api,
          autoPlaySeason: appSettings.autoPlaySeason,
          onPlay: (url, title, {resume = false}) {
            Navigator.of(context).pop();
            _play(url, title, resume: resume);
          },
          onChanged: () => setState(() {}),
          onPlayFromHere: (episodes) async {
            if (episodes.isEmpty) return;
            Navigator.of(context).pop();
            await _playEpisodes(episodes);
          },
        ),
      ),
    );
  }

  bool _wgConfigured() {
    final home = Platform.environment['HOME'] ?? '';
    final f = File('$home/flixam_player/vpn/wg0.conf');
    if (!f.existsSync()) return false;
    final c = f.readAsStringSync();
    return !c.contains('REPLACE_WITH');
  }

  Future<void> _loadStreamingProviders() async {
    try {
      final list = await api.providers();
      if (!mounted) return;
      setState(() => streamingProviders = list);
    } catch (_) {}
  }

  Future<void> _selectProvider(int? id) async {
    if (id == null) {
      setState(() {
        selectedProviderId = null;
        selectedProviderName = null;
        providerMovies = [];
        providerFilter = 'Alle';
        heroItem = null;
      });
      return;
    }
    final name = streamingProviders
            .firstWhere((p) => p['id'] == id, orElse: () => {'name': 'Anbieter'})['name']
            ?.toString() ?? 'Anbieter';
    setState(() {
      selectedProviderId = id;
      selectedProviderName = name;
      providerFilter = 'Alle';
      heroItem = null;
      heroSources = [];
      heroTrailerKey = null;
      providerLoading = true;
      showHome = true;
    });
    try {
      final items = await api.providerItems(id);
      if (!mounted) return;
      setState(() {
        rawProviderMovies = items;
        providerMovies = items;
        providerLoading = false;
      });
      await _refreshFilteredViews();
      if (items.isNotEmpty) {
        _loadHeroSources((items.first as Map)['title']?.toString() ?? '');
        _loadHeroTrailer(items.first);
      }
    } catch (_) {
      if (mounted) setState(() => providerLoading = false);
    }
  }

  Future<void> _loadHeroTrailer(dynamic item) async {
    final title = item is Map ? (item['title']?.toString() ?? '') : '';
    final id = item is Map ? item['id'] : null;
    if (title.isEmpty) return;
    try {
      final key = id != null
          ? await TmdbService.instance.trailerKey(id)
          : await TmdbService.instance.trailerKeyForTitle(title);
      if (!mounted) return;
      setState(() => heroTrailerKey = key);
    } catch (_) {}
  }

  Future<void> _openTrailer(String key, String title) async {
    if (Platform.isAndroid) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TrailerPage(videoKey: key, title: title),
        ),
      );
    } else {
      // Zuerst versuchen, den Trailer im normalen Player abzuspielen.
      final resolved = await api.trailerStream(key);
      final stream = resolved['stream_url']?.toString() ?? '';
      if (stream.isNotEmpty) {
        await _play(stream, 'Trailer: $title');
        return;
      }
      // Fallback: Browser (webview_flutter gibt es nicht fuer Linux).
      try {
        await Process.start('xdg-open', [
          'https://www.youtube.com/watch?v=$key',
        ]);
      } catch (_) {}
    }
  }

  Future<void> _loadHeroSources(String title) async {
    if (title.isEmpty) return;
    setState(() => heroSourcesLoading = true);
    try {
      final options = await AvailabilityService.instance.providerOptions(title);
      if (!mounted) return;
      setState(() {
        heroSources = options;
        heroSourcesLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => heroSourcesLoading = false);
    }
  }

  void _toggleSection(String title) {
    final expand = expandedSection != title;
    setState(() => expandedSection = expand ? title : null);
    if (expand) _loadFullSection(title);
  }

  Future<void> _loadFullSection(String title) async {
    if (_fullSections.containsKey(title) || _loadingSections.contains(title)) return;
    setState(() => _loadingSections.add(title));
    try {
      var all = await api.homeAll(title);
      if (Platform.isAndroid && appSettings.onlyAvailable) {
        await AvailabilityService.instance.load();
        all = all.where((i) => AvailabilityService.instance.isAvailable(
              (i as Map)['title']?.toString() ?? '',
            )).toList();
      }
      if (!mounted) return;
      setState(() {
        _fullSections[title] = all;
        _loadingSections.remove(title);
      });
    } catch (_) {
      if (mounted) setState(() => _loadingSections.remove(title));
    }
  }

  /// Wiederverwendbares Hero-Banner (Startseite und Browse-Auswahl).
  Widget _heroBanner(
    Map<String, dynamic> item, {
    String eyebrow = 'NEU & BELIEBT',
    VoidCallback? onClose,
    List<Map<String, String>> sources = const [],
    bool sourcesLoading = false,
    void Function(String url, String label)? onSource,
    String? trailerKey,
    VoidCallback? onTrailer,
    VoidCallback? onResume,
    Widget? resumeInfo,
    int myRating = 0,
    String myNote = '',
  }) {
    final backdrop = item['backdrop_url']?.toString() ?? '';
    final title = item['title']?.toString() ?? '';
    final aether = appSettings.layout == 1;
    final secondaryStyle = aether
        ? OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
          )
        : null;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 340,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (backdrop.isNotEmpty && !aether)
                Image.network(
                  backdrop,
                  fit: BoxFit.cover,
                  // Backdrops sind 16:9, das Banner viel breiter - oben
                  // ausrichten, damit Gesichter nicht abgeschnitten werden.
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, _, _) => Container(color: surf(context)),
                ),
            if (!aether)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, bg(context)],
                  ),
                ),
              ),
            if (onClose != null)
              Positioned(
                right: 12,
                top: 12,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: onClose,
                ),
              ),
            Positioned(
              left: aether ? 234 : 24,
              bottom: 20,
              child: SizedBox(
                width: 520,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      eyebrow,
                      style: TextStyle(
                        color: aether
                            ? Colors.white54
                            : accent(context),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: aether ? 2 : 0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: aether
                          ? const TextStyle(
                              fontSize: 38,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 3,
                              height: 1.05,
                              shadows: [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            )
                          : const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                            ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (item['year'] != null)
                          Text(item['year'].toString(),
                              style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        if (item['rating'] != null) ...[
                          const SizedBox(width: 12),
                          Text('★ ${item['rating']}',
                              style: const TextStyle(color: Colors.amber, fontSize: 13)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (sourcesLoading)
                      const SizedBox(
                        width: 140,
                        child: LinearProgressIndicator(),
                      )
                    else if (sources.isNotEmpty)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(
                            width: 92,
                            child: Text(
                              'Quelle:',
                              style: TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ),
                          Expanded(
                            child: Wrap(
                              children: [
                                for (final source in sources)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6, bottom: 4),
                                    child: ActionChip(
                                      label: Text(source['label'] ?? '',
                                          style: const TextStyle(fontSize: 10)),
                                      onPressed: source['url']?.isNotEmpty ?? false
                                          ? () => onSource?.call(source['url']!, source['label'] ?? '')
                                          : null,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (resumeInfo != null) ...[
                      const SizedBox(height: 6),
                      resumeInfo,
                    ],
                    if (myRating > 0 || myNote.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (myRating > 0)
                            Text(
                              '★' * myRating,
                              style: const TextStyle(color: Colors.amber, fontSize: 14),
                            ),
                          if (myNote.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                myNote,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      item['overview']?.toString() ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (aether)
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withValues(alpha: 0.26),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                                side: const BorderSide(color: Colors.white38),
                              ),
                            ),
                            onPressed: () => _play(item['url']?.toString() ?? '', title),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Abspielen'),
                          )
                        else
                          FilledButton.icon(
                            onPressed: () => _play(item['url']?.toString() ?? '', title),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Jetzt abspielen'),
                          ),
                        if (aether) ...[
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () async {
                              await prefs.toggleFavorite(item);
                              if (mounted) setState(() {});
                            },
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.3),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white54),
                              ),
                              child: Icon(
                                prefs.isFavorite(item) ? Icons.check : Icons.add,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: secondaryStyle,
                          onPressed: () {
                            setState(() => selectedItem = item);
                            _showDetail();
                          },
                          icon: const Icon(Icons.info_outline),
                          label: const Text('Details'),
                        ),
                        if (onResume != null) ...[
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            style: secondaryStyle,
                            onPressed: onResume,
                            icon: const Icon(Icons.restore),
                            label: const Text('Fortsetzen'),
                          ),
                        ],
                        if (trailerKey != null && onTrailer != null) ...[
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            style: secondaryStyle,
                            onPressed: onTrailer,
                            icon: const Icon(Icons.movie_outlined),
                            label: const Text('Trailer'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _fskNumber(dynamic item) {
    final s = (item is Map ? (item['fsk']?.toString() ?? '') : '');
    return int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? -1;
  }

  Future<List<dynamic>> _applyFilters(List<dynamic> input, {bool skipFsk = false}) async {
    final year = yearCtrl.text.trim();
    var out = input.where((i) {
      if (i is! Map) return false;
      if (year.isNotEmpty && (i['year']?.toString() ?? '') != year) return false;
      if (monthFilter != 'Alle') {
        final raw = (i['release_date'] ?? i['date'] ?? '').toString();
        final month = raw.length >= 7 ? raw.substring(5, 7) : '';
        if (month != monthFilter) return false;
      }
      final mt = i['media_type']?.toString();
      if (filterType.isNotEmpty &&
          mt != (filterType == 'movie' ? 'movie' : 'tv')) {
        return false;
      }
      if (selectedGenre != null &&
          !(i['genres'] as List? ?? []).contains(selectedGenre)) {
        return false;
      }
      return true;
    }).toList();

    if (!skipFsk && (fskFilter != 'Alle' || sortOrder.startsWith('FSK'))) {
      await Future.wait(out.take(60).map((i) async {
        final m = i as Map;
        if (m['fsk'] != null && m['fsk'].toString().isNotEmpty) return;
        final value = await TmdbService.instance.fskFor(
          m['id'],
          mediaType: m['media_type']?.toString() ?? 'movie',
        );
        m['fsk'] = value;
      }));
      if (fskFilter != 'Alle') {
        final wanted = fskFilter.replaceAll(RegExp(r'[^0-9]'), '');
        out = out.where((i) => _fskNumber(i).toString() == wanted).toList();
      }
    }

    switch (sortOrder) {
      case 'Jahr ↓':
        out.sort((a, b) => (b as Map)['year']?.toString().compareTo((a as Map)['year']?.toString() ?? '') ?? 0);
        break;
      case 'Jahr ↑':
        out.sort((a, b) => (a as Map)['year']?.toString().compareTo((b as Map)['year']?.toString() ?? '') ?? 0);
        break;
      case 'FSK ↑':
        out.sort((a, b) => _fskNumber(a).compareTo(_fskNumber(b)));
        break;
      case 'FSK ↓':
        out.sort((a, b) => _fskNumber(b).compareTo(_fskNumber(a)));
        break;
      case 'Bewertung':
        out.sort((a, b) => ((b as Map)['rating'] as num?)?.compareTo((a as Map)['rating'] as num? ?? 0) ?? 0);
        break;
      case 'Datum ↓':
        out.sort((a, b) => (b as Map)['release_date']?.toString().compareTo((a as Map)['release_date']?.toString() ?? '') ?? 0);
        break;
      case 'Datum ↑':
        out.sort((a, b) => (a as Map)['release_date']?.toString().compareTo((b as Map)['release_date']?.toString() ?? '') ?? 0);
        break;
    }
    return out;
  }

  Future<void> _refreshFilteredViews() async {
    if (rawHomeData != null) {
      final year = yearCtrl.text.trim();
      if (year.isNotEmpty) {
        // Echte Jahres-Suche ueber TMDB Discover.
        final movies = await TmdbService.instance.byYear(year, 'movie');
        final series = await TmdbService.instance.byYear(year, 'tv');
        final yearMovies =
            await _applyFilters(movies, skipFsk: fskFilter == 'Alle');
        final yearSeries =
            await _applyFilters(series, skipFsk: fskFilter == 'Alle');
        final sections = <Map<String, dynamic>>[];
        if (yearMovies.isNotEmpty) {
          sections.add({'title': 'Filme aus $year', 'items': yearMovies});
        }
        if (yearSeries.isNotEmpty) {
          sections.add({'title': 'Serien aus $year', 'items': yearSeries});
        }
        homeData = {
          'hero': yearMovies.isNotEmpty
              ? yearMovies.first
              : (yearSeries.isNotEmpty ? yearSeries.first : null),
          'sections': sections,
        };
      } else if (fskFilter != 'Alle') {
        // Echte FSK-Suche ueber TMDB Discover (nicht nur die ersten 40 Titel).
        final fskNum = fskFilter.replaceAll(RegExp(r'[^0-9]'), '');
        final movies = await TmdbService.instance.byCertification(fskNum, 'movie');
        final series = await TmdbService.instance.byCertification(fskNum, 'tv');
        final fskMovies = await _applyFilters(movies, skipFsk: true);
        final fskSeries = await _applyFilters(series, skipFsk: true);
        final sections = <Map<String, dynamic>>[];
        if (fskMovies.isNotEmpty) {
          sections.add({'title': 'Filme ab $fskNum', 'items': fskMovies});
        }
        if (fskSeries.isNotEmpty) {
          sections.add({'title': 'Serien ab $fskNum', 'items': fskSeries});
        }
        homeData = {
          'hero': fskMovies.isNotEmpty ? fskMovies.first : (fskSeries.isNotEmpty ? fskSeries.first : null),
          'sections': sections,
        };
      } else if (sortOrder != 'Standard') {
        // Sortierung soll sichtbar über ALLE Titel wirken, nicht nur
        // innerhalb der einzelnen Home-Reihen.
        final all = ((rawHomeData!['sections'] as List?) ?? [])
            .expand((s) => ((s['items'] as List?) ?? []))
            .toList();
        final sorted = await _applyFilters(all);
        homeData = {
          'hero': sorted.isNotEmpty ? sorted.first : rawHomeData!['hero'],
          'sections': [
            {
              'title': 'Sortiert: $sortOrder (${sorted.length})',
              'items': sorted,
            }
          ],
        };
      } else {
        final sections = <Map<String, dynamic>>[];
        for (final s in ((rawHomeData!['sections'] as List?) ?? [])) {
          final items = await _applyFilters((s['items'] as List?) ?? []);
          if (items.isNotEmpty) {
            sections.add({'title': s['title'], 'items': items});
          }
        }
        homeData = {'hero': rawHomeData!['hero'], 'sections': sections};
      }
    }
    providerMovies = await _applyFilters(rawProviderMovies);
    results = await _applyFilters(rawResults);
    if (mounted) setState(() {});
  }

  void _onFilterChanged() {
    _refreshFilteredViews();
  }

  String _sourceLabel(dynamic item) {
    final s = item is Map ? (item['source']?.toString() ?? '') : '';
    switch (s) {
      case 'netzkino': return 'Netzkino';
      case 'einschalten': return 'Einschalten';
      case 'movie2k': return 'Movie2k';
      case 'kellerkino': return 'Kellerkino';
      case 'hdfilme': return 'HD Filme';
      case 'streamcloud': return 'Streamcloud';
      case 'filmpalast': return 'FilmPalast';
      case 'filmo': return 'Filmo';
      case 'megakino': return 'Megakino';
      default: return s;
    }
  }

  /// Eine Kachel fuer die Home-Reihen (horizontal oder im auf geklappten Raster).
  Widget _homeItemCard(Map<String, dynamic> it, {bool autofocus = false}) {
    final poster = it['poster_url']?.toString() ?? '';
    final label = it['title']?.toString() ?? '';
    return TvFocusable(
      autofocus: autofocus,
      onTap: () {
        // Auf Home bleiben - Auswahl oben im Hero-Feld anzeigen.
        // Erst der Button "Details" öffnet die Vollbildseite.
        setState(() {
          selectedItem = it;
          heroItem = it;
        });
        _loadHeroSources(it['title']?.toString() ?? '');
        _loadHeroTrailer(it);
      },
      onLongPress: () => _showItemMenuLongPress(it),
      onSecondaryTapDown: (d) => _showItemMenu(d, it),
      builder: (focused) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: focused
              ? Border.all(color: accent(context), width: 3)
              : null,
        ),
        child: SizedBox(
          width: 120,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    SizedBox(
                      height: 160,
                      width: 120,
                      child: poster.isNotEmpty
                          ? Image.network(
                              poster,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(color: Colors.grey.shade900),
                            )
                          : Container(color: Colors.grey.shade900),
                    ),
                    if (prefs.isSeen(it))
                      const Positioned(
                        left: 4,
                        top: 4,
                        child: Icon(Icons.check_circle, color: Colors.green, size: 18),
                      ),
                    if (prefs.isFavorite(it))
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Icon(Icons.favorite, color: accent(context), size: 18),
                      ),
                    if (_sourceLabel(it).isNotEmpty)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _sourceLabel(it),
                            style: const TextStyle(fontSize: 8, color: Colors.white),
                          ),
                        ),
                      ),
                    if (prefs.ratingFor(it['title']?.toString() ?? '') > 0)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '★${prefs.ratingFor(it['title']?.toString() ?? '')}',
                            style: const TextStyle(fontSize: 9, color: Colors.amber),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11)),
              if (it['rating'] != null)
                Text('★ ${it['rating']}',
                    style: const TextStyle(fontSize: 10, color: Colors.amber)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSourceEpisodes(
    String label,
    String title,
    Map<String, dynamic> item, {
    Map<String, dynamic>? details,
  }) async {
    setState(() => loading = true);
    final data = details ??
        await api.details(
          title: title,
          year: item['year']?.toString(),
          type: 'tv',
        );
    final src = Uri.encodeComponent(
      label.toLowerCase().replaceAll(RegExp(r'\s+'), ''),
    );
    final seasons = ((data['seasons'] as List?) ?? []).map((s) {
      final sm = (s as Map).cast<String, dynamic>();
      final episodes = ((sm['episodes'] as List?) ?? []).map((e) {
        final em = (e as Map).cast<String, dynamic>();
        final url = em['url']?.toString() ?? '';
        em['url'] = url.contains('?') ? '$url&source=$src' : '$url?source=$src';
        return em;
      }).toList();
      sm['episodes'] = episodes;
      return sm;
    }).toList();
    if (!mounted) return;
    setState(() {
      showSourceEpisodes = true;
      showHome = false;
      showFavorites = false;
      sourceEpisodesLabel = label;
      sourceEpisodesTitle = title;
      sourceEpisodeSeasons = seasons;
      loading = false;
    });
  }

  List<Widget> _buildSourceEpisodeSlivers() {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${sourceEpisodesLabel ?? 'Quelle'}: $sourceEpisodesTitle',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => showSourceEpisodes = false),
              ),
            ],
          ),
        ),
      ),
      if (sourceEpisodeSeasons.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Für diese Quelle wurden keine Folgen gefunden.'),
          ),
        )
      else
        ...sourceEpisodeSeasons.map((s) {
          final season = s as Map<String, dynamic>;
          final episodes = (season['episodes'] as List?) ?? [];
          return SliverToBoxAdapter(
            child: ExpansionTile(
              initiallyExpanded: season['season'] == 1,
              title: Text('Staffel ${season['season']} – ${season['name'] ?? ''}'),
              subtitle: Text('${episodes.length} Folgen'),
              children: episodes.map((e) {
                final ep = e as Map<String, dynamic>;
                final no = (ep['episode'] as num?)?.toInt() ?? 0;
                final epTitle = ep['title']?.toString() ?? '';
                return ListTile(
                  leading: ep['still_url']?.toString().isNotEmpty ?? false
                      ? Image.network(ep['still_url'].toString(), width: 60, fit: BoxFit.cover)
                      : const Icon(Icons.movie_outlined),
                  title: Text('E${no.toString().padLeft(2, '0')} · $epTitle'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ep['air_date']?.toString() ?? ''),
                      _resumeInfo(epTitle, width: 150),
                    ],
                  ),
                  onTap: () {
                    if (appSettings.autoPlaySeason) {
                      final queue = _sourceFollowingEpisodes(ep);
                      if (queue.isNotEmpty) {
                        _playEpisodes(queue);
                        return;
                      }
                    }
                    _play(ep['url']?.toString() ?? '', epTitle,
                        resume: prefs.positionFor(epTitle) > 30);
                  },
                );
              }).toList(),
            ),
          );
        }),
    ];
  }

  Future<void> _onHeroSource(String url, String label, dynamic item) async {
    final title = item is Map ? (item['title']?.toString() ?? '') : '';
    final map = item is Map ? item.cast<String, dynamic>() : <String, dynamic>{};
    // Nicht dem gespeicherten media_type vertrauen („Neu im Kino" markiert
    // Serien oft als movie) - die echten TMDB-Daten entscheiden.
    final data = await api.details(
      title: title,
      year: map['year']?.toString(),
      type: map['media_type']?.toString(),
    );
    if (((data['seasons'] as List?) ?? []).isNotEmpty) {
      await _openSourceEpisodes(label, title, map, details: data);
    } else {
      await _play(url, title);
    }
  }

  List<Widget> _buildFavoriteSlivers() {
    final items = prefs.favoriteList();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Favoriten (${items.length})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => showFavorites = false),
              ),
            ],
          ),
        ),
      ),
      if (items.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Noch keine Favoriten. Langdruck auf ein Cover → „Zu Favoriten hinzufügen".'),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 140,
              childAspectRatio: 2 / 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _homeItemCard(items[i], autofocus: i == 0),
              childCount: items.length,
            ),
          ),
        ),
    ];
  }

  /// Startseite: Hero-Banner + „Neuheiten"-Reihen im Stil der Referenz.
  List<Widget> _buildHomeSlivers() {
    if (selectedProviderId != null) {
      final visible = providerMovies.where((i) {
        if (providerFilter == 'Alle') return true;
        final type = (i as Map)['media_type']?.toString();
        return type == (providerFilter == 'Filme' ? 'movie' : 'tv');
      }).toList();
      final providerHero = heroItem is Map
          ? (heroItem as Map).cast<String, dynamic>()
          : (visible.isNotEmpty
              ? (visible.first as Map).cast<String, dynamic>()
              : null);
      return [
        if (providerHero != null)
          _heroBanner(
            providerHero,
            eyebrow: (selectedProviderName ?? 'Anbieter').toUpperCase(),
            sources: heroSources,
            sourcesLoading: heroSourcesLoading,
            onSource: (url, label) =>
                _onHeroSource(url, label, providerHero),
            trailerKey: heroTrailerKey,
            onTrailer: heroTrailerKey == null
                ? null
                : () => _openTrailer(
                    heroTrailerKey!, providerHero['title']?.toString() ?? ''),
            onResume: prefs.positionFor(providerHero['title']?.toString() ?? '') > 30
                ? () => _play(providerHero['url']?.toString() ?? '',
                    providerHero['title']?.toString() ?? '', resume: true)
                : null,
            resumeInfo: _resumeInfo(providerHero['title']?.toString() ?? ''),
            myRating: prefs.ratingFor(providerHero['title']?.toString() ?? ''),
            myNote: prefs.noteFor(providerHero['title']?.toString() ?? ''),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Verfügbar auf ${selectedProviderName ?? 'Anbieter'} (${visible.length})',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Alle', label: Text('Alle')),
                    ButtonSegment(value: 'Filme', label: Text('Filme')),
                    ButtonSegment(value: 'Serien', label: Text('Serien')),
                  ],
                  selected: {providerFilter},
                  onSelectionChanged: (s) {
                    setState(() {
                      providerFilter = s.first;
                      heroItem = null;
                      heroSources = [];
        heroTrailerKey = null;
      heroTrailerKey = null;
                    });
                  },
                ),
                if (providerLoading)
                  const SizedBox(width: 120, child: LinearProgressIndicator()),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => _selectProvider(null),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 140,
              childAspectRatio: 2 / 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _homeItemCard(
                (visible[i] as Map).cast<String, dynamic>(),
                autofocus: i == 0,
              ),
              childCount: visible.length,
            ),
          ),
        ),
      ];
    }
    final data = homeData;
    if (data == null) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Startseite wird geladen…'),
          ),
        ),
      ];
    }
    final list = <Widget>[];
    // Wurde ein Cover aus den Reihen angeklickt, bleibt die Home-Seite
    // erhalten und das ausgewählte Item erscheint oben als Auswahl-Feld.
    final selected = heroItem is Map
        ? (heroItem as Map).cast<String, dynamic>()
        : null;
    final hero = selected ?? data['hero'] as Map<String, dynamic>?;
    if (hero != null) {
      list.add(_heroBanner(
        hero,
        eyebrow: selected != null ? 'AUSGEWÄHLT' : 'NEU & BELIEBT',
        onClose: selected != null ? () => setState(() => heroItem = null) : null,
        sources: heroSources,
        sourcesLoading: heroSourcesLoading,
        onSource: (url, label) => _onHeroSource(url, label, hero),
        trailerKey: heroTrailerKey,
        onTrailer: heroTrailerKey == null
            ? null
            : () => _openTrailer(heroTrailerKey!, hero['title']?.toString() ?? ''),
        onResume: prefs.positionFor(hero['title']?.toString() ?? '') > 30
            ? () => _play(hero['url']?.toString() ?? '',
                hero['title']?.toString() ?? '', resume: true)
            : null,
        resumeInfo: _resumeInfo(hero['title']?.toString() ?? ''),
        myRating: prefs.ratingFor(hero['title']?.toString() ?? ''),
        myNote: prefs.noteFor(hero['title']?.toString() ?? ''),
      ));
    }

    for (final section in (data['sections'] as List?) ?? []) {
      final title = section['title']?.toString() ?? '';
      final items = (section['items'] as List?) ?? [];
      final expanded = expandedSection == title ||
          fskFilter != 'Alle' ||
          yearCtrl.text.trim().isNotEmpty ||
          monthFilter != 'Alle' ||
          sortOrder != 'Standard';
      list.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              if (fskFilter == 'Alle' &&
                  yearCtrl.text.trim().isEmpty &&
                  monthFilter == 'Alle' &&
                  sortOrder == 'Standard')
                TextButton(
                  onPressed: () => _toggleSection(title),
                  child: Text(expanded ? 'weniger' : 'mehr (${items.length})'),
                )
              else
                Text(
                  '${items.length} Titel',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
            ],
          ),
        ),
      ));
      if (expanded) {
        // Komplette Kategorie inline auf der Startseite anzeigen.
        final allItems = _fullSections[title] ?? items;
        if (_loadingSections.contains(title)) {
          list.add(const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            ),
          ));
        }
        list.add(SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 140,
              childAspectRatio: 2 / 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _homeItemCard((allItems[i] as Map).cast<String, dynamic>(),
                    autofocus: i == 0),
              childCount: allItems.length,
            ),
          ),
        ));
      } else {
        list.add(SliverToBoxAdapter(
          child: SizedBox(
            height: 206,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (ctx, i) =>
                  _homeItemCard((items[i] as Map).cast<String, dynamic>(),
                    autofocus: i == 0),
            ),
          ),
        ));
      }
    }
    return list;
  }

  Widget _aetherNavItem(
    IconData icon,
    String label, {
    required bool active,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? surf(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: active ? Colors.white : Colors.white60),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? Colors.white : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Aether: Hero-Bild als vollflächige Seite im Hintergrund; Cover liegen
  /// darüber. Ein dunkler Verlauf haelt Text und Karten lesbar.
  Widget _aetherFullBackground() {
    final selected = heroItem is Map
        ? (heroItem as Map).cast<String, dynamic>()
        : null;
    final homeHero = (homeData?['hero'] as Map?)?.cast<String, dynamic>();
    final item = selected ?? homeHero;
    final backdrop = item?['backdrop_url']?.toString() ?? '';
    if (backdrop.isEmpty) return const SizedBox.shrink();
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            backdrop,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  bg(context).withValues(alpha: 0.66),
                  bg(context).withValues(alpha: 0.76),
                  bg(context).withValues(alpha: 0.93),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aetherSidebar() {
    final d = designAt(appSettings.design);
    return SizedBox(
      width: 210,
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            color: d.background.withValues(alpha: 0.24),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.movie_filter_outlined, color: d.accent, size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'AETHER',
                    style: TextStyle(
                      fontSize: 15,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Kategorien aktualisieren',
                  icon: const Icon(Icons.refresh, size: 18),
                  color: Colors.white70,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _refreshAll,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: TextField(
              controller: searchCtrl,
              decoration: InputDecoration(
                hintText: 'Suche...',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                fillColor: surf(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(height: 10),
          _aetherNavItem(Icons.home_outlined, 'Home',
              active: showHome, onTap: _goHome),
          _aetherNavItem(Icons.search, 'Suche',
              active: false, onTap: () => _search()),
          _aetherNavItem(Icons.movie_outlined, 'Filme',
              active: !showHome && !showFavorites, onTap: _browseRoot),
          _aetherNavItem(Icons.favorite_border, 'Favoriten', active: showFavorites,
              onTap: () => setState(() {
                    showFavorites = !showFavorites;
                    showHome = false;
                    heroItem = null;
                  })),
          if (!Platform.isAndroid)
            _aetherNavItem(Icons.file_download_outlined, 'Import',
                active: false, onTap: _importConf),
          _aetherNavItem(Icons.settings_outlined, 'Einstellungen',
              active: false, onTap: _showSettings),
          const Spacer(),
          if (!Platform.isAndroid)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 8,
                      color: vpnActive ? Colors.green : Colors.white24),
                  const SizedBox(width: 6),
                  Text('VPN',
                      style: TextStyle(fontSize: 10, color: Colors.white54)),
                  const Spacer(),
                  for (final a in ['xstream', 'xship'])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: InkWell(
                        onTap: () => setState(() => addon = a),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: addon == a ? d.accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Text(
                            a == 'xstream' ? 'xS' : 'xSh',
                            style: TextStyle(
                              fontSize: 9,
                              color: addon == a ? Colors.black : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 12,
                    child: Icon(Icons.person, size: 14),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Profil',
                        style: TextStyle(fontSize: 12, color: Colors.white)),
                  ),
                  Icon(Icons.expand_more, size: 14, color: Colors.white54),
                ],
              ),
            ),
          ),
          ],
        ),
      ),
    ),
    ),
  );
  }

  /// Bei Aether bekommt alles links Platz für die Sidebar - nur der Hero
  /// bleibt full-bleed und läuft hinter der Seitenleiste durch.
  List<Widget> _aetherAwareSlivers(List<Widget> slivers) {
    if (appSettings.layout != 1 || Platform.isAndroid) return slivers;
    return [
      for (final sliver in slivers)
        if (sliver is SliverToBoxAdapter &&
            sliver.child is SizedBox &&
            (sliver.child as SizedBox).height == 340)
          sliver
        else
          SliverPadding(
            padding: const EdgeInsets.only(left: 210),
            sliver: sliver,
          ),
    ];
  }

  Widget _buildContentScroller() {
    return CustomScrollView(
            slivers: _aetherAwareSlivers([
              if (appSettings.layout != 1) ...[
              SliverAppBar(
                pinned: true,
                backgroundColor: Colors.transparent,
                flexibleSpace: ClipRRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(color: Colors.black.withValues(alpha: 0.4)),
                  ),
                ),
                title: Row(
                  children: [
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _showSettings,
                      icon: const Icon(CupertinoIcons.settings),
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Kategorien aktualisieren',
                      onPressed: _refreshAll,
                      icon: const Icon(Icons.refresh),
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    if (!Platform.isAndroid) ...[
                      Icon(Icons.circle, size: 10, color: vpnActive ? Colors.green : Colors.grey),
                      const SizedBox(width: 8),
                    ],
                    if (!Platform.isAndroid)
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'xstream', label: Text('xStream')),
                          ButtonSegment(value: 'xship', label: Text('xShip')),
                        ],
                        selected: {addon},
                        onSelectionChanged: (s) => setState(() => addon = s.first),
                      )
                    else
                      DropdownButton<String>(
                        value: selectedSource,
                        dropdownColor: surf(context),
                        items: const [
                          DropdownMenuItem(value: 'Alle', child: Text('Alle Quellen')),
                          DropdownMenuItem(value: 'netzkino', child: Text('Netzkino')),
                          DropdownMenuItem(value: 'einschalten', child: Text('Einschalten')),
                          DropdownMenuItem(value: 'movie2k', child: Text('Movie2k')),
                          DropdownMenuItem(value: 'kellerkino', child: Text('Kellerkino')),
                          DropdownMenuItem(value: 'hd-filme', child: Text('HD Filme')),
                          DropdownMenuItem(value: 'streamcloud', child: Text('Streamcloud')),
                          DropdownMenuItem(value: 'filmpalast', child: Text('FilmPalast')),
                          DropdownMenuItem(value: 'filmo', child: Text('Filmo')),
                          DropdownMenuItem(value: 'megakino', child: Text('Megakino')),
                          DropdownMenuItem(value: 'gezkino', child: Text('GEZ Kino')),
                          DropdownMenuItem(value: 'trailer', child: Text('TMDB Trailers')),
                          DropdownMenuItem(value: 'custom', child: Text('Eigene Quellen')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => selectedSource = v);
                        },
                      ),
                    const SizedBox(width: 8),
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 170),
                      child: DropdownButton<int?>(
                        value: selectedProviderId,
                        hint: const Text('Anbieter'),
                        isExpanded: true,
                        dropdownColor: surf(context),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Alle Anbieter'),
                          ),
                          ...streamingProviders.map(
                            (p) => DropdownMenuItem<int?>(
                              value: p['id'] as int,
                              child: Text(
                                p['name']?.toString() ?? '',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: _selectProvider,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        enabled: true,
                        decoration: InputDecoration(
                          hintText: 'Suche...',
                          filled: true,
                          fillColor: surf(context),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                        ),
                        onSubmitted: (_) => _search(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _goHome, child: const Text('Home')),
                    TextButton(onPressed: () => _search(), child: const Text('Suche')),
                    if (!Platform.isAndroid)
                      TextButton(onPressed: () => _browseRoot(), child: const Text('Browse')),
                    if (!Platform.isAndroid)
                      TextButton(onPressed: _importConf, child: const Text('Import')),
                    IconButton(
                      tooltip: 'Favoriten',
                      color: Colors.white,
                      icon: Icon(
                        showFavorites ? Icons.favorite : Icons.favorite_border,
                        color: showFavorites ? accent(context) : Colors.white,
                      ),
                      onPressed: () => setState(() {
                        showFavorites = !showFavorites;
                        showHome = false;
                        heroItem = null;
                      }),
                    ),
                  ],
                ),
              )
              ],
              if (!Platform.isAndroid && !_wgConfigured())
                SliverToBoxAdapter(
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(8),
                    color: Colors.orange.shade900,
                    child: const Text('wg0.conf nicht mit echten Zugangsdaten befuellt.'),
                  ),
                ),
              if (!showFavorites && !showSourceEpisodes)
                SliverToBoxAdapter(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                    children: [
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: yearCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Jahr', isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8),
                          ),
                          onSubmitted: (_) => _onFilterChanged(),
                          onChanged: (_) => _onFilterChanged(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        value: monthFilter,
                        items: const [
                          DropdownMenuItem(value: 'Alle', child: Text('Monat alle')),
                          DropdownMenuItem(value: '01', child: Text('Januar')),
                          DropdownMenuItem(value: '02', child: Text('Februar')),
                          DropdownMenuItem(value: '03', child: Text('März')),
                          DropdownMenuItem(value: '04', child: Text('April')),
                          DropdownMenuItem(value: '05', child: Text('Mai')),
                          DropdownMenuItem(value: '06', child: Text('Juni')),
                          DropdownMenuItem(value: '07', child: Text('Juli')),
                          DropdownMenuItem(value: '08', child: Text('August')),
                          DropdownMenuItem(value: '09', child: Text('September')),
                          DropdownMenuItem(value: '10', child: Text('Oktober')),
                          DropdownMenuItem(value: '11', child: Text('November')),
                          DropdownMenuItem(value: '12', child: Text('Dezember')),
                        ],
                        onChanged: (v) {
                          setState(() => monthFilter = v ?? 'Alle');
                          _onFilterChanged();
                        },
                      ),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        value: filterType,
                        items: const [
                          DropdownMenuItem(value: '', child: Text('Alle')),
                          DropdownMenuItem(value: 'movie', child: Text('Filme')),
                          DropdownMenuItem(value: 'tv', child: Text('Serien')),
                        ],
                        onChanged: (v) {
                          setState(() {
                            filterType = v ?? '';
                            selectedGenre = null;
                          });
                          _loadGenres();
                          _onFilterChanged();
                        },
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 130,
                        child: DropdownButton<String?>(
                          isExpanded: true,
                          value: selectedGenre,
                          hint: const Text('Alle Genres'),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null, child: Text('Alle Genres'),
                            ),
                            ...genres.map(
                              (g) => DropdownMenuItem<String?>(
                                value: g['name']?.toString(),
                                child: Text(g['name']?.toString() ?? ''),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => selectedGenre = v);
                            _onFilterChanged();
                          },
                        ),
                      ),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        value: fskFilter,
                        items: const [
                          DropdownMenuItem(value: 'Alle', child: Text('FSK alle')),
                          DropdownMenuItem(value: 'FSK 0', child: Text('FSK 0')),
                          DropdownMenuItem(value: 'FSK 6', child: Text('FSK 6')),
                          DropdownMenuItem(value: 'FSK 12', child: Text('FSK 12')),
                          DropdownMenuItem(value: 'FSK 16', child: Text('FSK 16')),
                          DropdownMenuItem(value: 'FSK 18', child: Text('FSK 18')),
                        ],
                        onChanged: (v) {
                          setState(() => fskFilter = v ?? 'Alle');
                          _onFilterChanged();
                        },
                      ),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        value: sortOrder,
                        items: const [
                          DropdownMenuItem(value: 'Standard', child: Text('Sort: Standard')),
                          DropdownMenuItem(value: 'Jahr ↓', child: Text('Jahr ↓')),
                          DropdownMenuItem(value: 'Jahr ↑', child: Text('Jahr ↑')),
                          DropdownMenuItem(value: 'FSK ↑', child: Text('FSK ↑')),
                          DropdownMenuItem(value: 'FSK ↓', child: Text('FSK ↓')),
                          DropdownMenuItem(value: 'Bewertung', child: Text('Bewertung')),
                          DropdownMenuItem(value: 'Datum ↓', child: Text('Datum ↓')),
                          DropdownMenuItem(value: 'Datum ↑', child: Text('Datum ↑')),
                        ],
                        onChanged: (v) {
                          setState(() => sortOrder = v ?? 'Standard');
                          _onFilterChanged();
                        },
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            yearCtrl.clear();
                            filterType = '';
                            selectedGenre = null;
                            fskFilter = 'Alle';
                            monthFilter = 'Alle';
                            sortOrder = 'Standard';
                          });
                          _loadGenres();
                          _onFilterChanged();
                        },
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                ),
              ),
              if (showFavorites) ..._buildFavoriteSlivers(),
              if (showSourceEpisodes) ..._buildSourceEpisodeSlivers(),
              if (loading) const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (showHome) ..._buildHomeSlivers(),
              if (!showHome && !showFavorites && !showSourceEpisodes && _navStack.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: _goBack,
                          icon: const Icon(CupertinoIcons.back),
                          label: const Text('Zurück'),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            currentTitle,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: Colors.white70),
                          ),
                        ),
                        if (currentFolderUrl != null &&
                            currentFolderUrl!.contains('function=showSeasons'))
                          TextButton(
                            onPressed: _toggleEpisodeView,
                            child: Text(allEpisodesView ? 'Staffeln' : 'Alle Episoden'),
                          ),
                      ],
                    ),
                  ),
                ),
              if (!showHome && heroItem != null && appSettings.heroInBrowse)
                _heroBanner(
                  (heroItem as Map).cast<String, dynamic>(),
                  eyebrow: 'AUSGEWÄHLT',
                  onClose: () => setState(() => heroItem = null),
                  sources: heroSources,
                  sourcesLoading: heroSourcesLoading,
                  onSource: (url, label) =>
                      _onHeroSource(url, label, heroItem),
                  trailerKey: heroTrailerKey,
                  onTrailer: heroTrailerKey == null
                      ? null
                      : () => _openTrailer(
                          heroTrailerKey!,
                          (heroItem as Map)['title']?.toString() ?? '',
                        ),
                  onResume: prefs.positionFor((heroItem as Map)['title']?.toString() ?? '') > 30
                      ? () => _play((heroItem as Map)['url']?.toString() ?? '',
                          (heroItem as Map)['title']?.toString() ?? '', resume: true)
                      : null,
                  resumeInfo: _resumeInfo((heroItem as Map)['title']?.toString() ?? ''),
                  myRating: prefs.ratingFor((heroItem as Map)['title']?.toString() ?? ''),
                  myNote: prefs.noteFor((heroItem as Map)['title']?.toString() ?? ''),
                ),
              if (!showHome && !showFavorites && !showSourceEpisodes)
                SliverPadding(
                  padding: const EdgeInsets.all(8),
                  sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    // Episoden-Stills sind landschaftlich - kompakt anzeigen,
                    // damit moeglichst viele Folgen gleichzeitig sichtbar sind.
                    maxCrossAxisExtent: allEpisodesView ? 200 : 140,
                    childAspectRatio: allEpisodesView ? 16 / 10 : 2 / 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final item = results[i];
                      final title = item['title']?.toString() ?? '';
                      final url = item['url']?.toString() ?? '';
                      final poster = item['poster_url']?.toString() ?? '';
                      final year = item['year']?.toString() ?? '';
                      final rating = item['rating'];
                      final isFolder = item['isFolder'] == true;
                      return TvFocusable(
                        autofocus: i == 0,
                        onTap: () {
                          if (isFolder) {
                            _browseInto(url, title);
                          } else if (!showHome && appSettings.heroInBrowse) {
                            // Browse: Film oben als Hero mit Play-Button zeigen
                            setState(() {
                              heroItem = item;
                              selectedItem = item;
                            });
                            _loadHeroSources(title);
                            _loadHeroTrailer(item);
                          } else {
                            setState(() {
                              selectedItem = item;
                            });
                            _showDetail();
                          }
                        },
                        onLongPress: () {
                          if (!isFolder) {
                            _showItemMenuLongPress(
                                item.cast<String, dynamic>());
                          }
                        },
                        onSecondaryTapDown: (d) {
                          if (!isFolder) {
                            _showItemMenu(d, item.cast<String, dynamic>());
                          }
                        },
                        builder: (focused) => Container(
                          decoration: BoxDecoration(
                            color: surf(context),
                            borderRadius: BorderRadius.circular(16),
                            border: focused
                                ? Border.all(color: accent(context), width: 3)
                                : Border.all(color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (poster.isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Image.network(poster, fit: BoxFit.cover),
                                ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Colors.transparent, Colors.black.withValues(alpha: 0.8)],
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                                      Row(
                                        children: [
                                          if (year.isNotEmpty) Text(year, style: const TextStyle(fontSize: 9, color: Colors.white70)),
                                          const Spacer(),
                                          if (rating != null) Text('★ $rating', style: const TextStyle(fontSize: 9, color: Colors.amber)),
                                        ],
                                      ),
                                      if (_sourceLabel(item).isNotEmpty)
                                        Text(_sourceLabel(item),
                                            style: const TextStyle(fontSize: 9, color: Colors.lightBlueAccent)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    childCount: results.length,
                  ),
                ),
              ),
            ]),
          );
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Scaffold(
        body: Stack(
        children: [
          if (Platform.isAndroid) BrowserResolver.instance.buildHiddenView(),
          if (appSettings.layout == 1 && !Platform.isAndroid)
            Positioned.fill(
              child: Stack(
                children: [
                  _aetherFullBackground(),
                  _buildContentScroller(),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 210,
                    child: _aetherSidebar(),
                  ),
                ],
              ),
            )
          else
            _buildContentScroller(),
          if (showPlayer)
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    GestureDetector(
                      onTap: _showPlayerControls,
                      child: CallbackShortcuts(
                        bindings: {
                          SingleActivator(LogicalKeyboardKey.escape): () {
                            player.stop();
                            setState(() => showPlayer = false);
                          },
                        },
                        child: Video(controller: videoController, fit: BoxFit.contain),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ClipRRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.55),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: 'Zurück',
                                  icon: const Icon(Icons.arrow_back, size: 28),
                                  onPressed: () {
                                    player.stop();
                                    setState(() => showPlayer = false);
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Schließen',
                                  icon: const Icon(CupertinoIcons.xmark_circle_fill, size: 26),
                                  onPressed: () {
                                    player.stop();
                                    setState(() => showPlayer = false);
                                  },
                                ),
                                Expanded(
                                  child: Text(
                                    nowPlaying,
                                    style: const TextStyle(color: Colors.white, fontSize: 14),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  tooltip: playerVolume == 0 ? 'Ton an' : 'Stumm',
                                  icon: Icon(
                                    playerVolume == 0 ? Icons.volume_off : Icons.volume_down,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                  onPressed: () => player.setVolume(playerVolume == 0 ? 100 : 0),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Slider(
                                    value: playerVolume.clamp(0, 100).toDouble(),
                                    min: 0,
                                    max: 100,
                                    divisions: 20,
                                    onChanged: (v) {
                                      player.setVolume(v);
                                      setState(() => playerVolume = v);
                                    },
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Lauter',
                                  icon: const Icon(Icons.volume_up, color: Colors.white, size: 26),
                                  onPressed: () => player.setVolume((playerVolume + 10).clamp(0, 100)),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Text(
                                    'VPN Shield',
                                    style: TextStyle(color: Colors.green, fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: AnimatedOpacity(
                        opacity: playerControlsVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: IgnorePointer(
                          ignoring: !playerControlsVisible,
                          child: Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (playerDuration.inSeconds > 0)
                                  Slider(
                                    value: playerPosition.inSeconds
                                        .clamp(0, playerDuration.inSeconds)
                                        .toDouble(),
                                    min: 0,
                                    max: playerDuration.inSeconds.toDouble(),
                                    onChanged: (v) =>
                                        player.seek(Duration(seconds: v.toInt())),
                                  ),
                                Text(
                                  '${_fmtClock(playerPosition)} / ${_fmtClock(playerDuration)}'
                                  '${_endClock().isNotEmpty ? '  ·  bis ${_endClock()} Uhr' : ''}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                                ),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      onPressed: () => player.seek(
                                          player.state.position - const Duration(seconds: 10)),
                                      icon: const Icon(Icons.replay_10),
                                    ),
                                    IconButton(
                                      onPressed: () => player.playOrPause(),
                                      icon: const Icon(Icons.play_arrow),
                                    ),
                                    IconButton(
                                      onPressed: () => player.seek(
                                          player.state.position + const Duration(seconds: 10)),
                                      icon: const Icon(Icons.forward_10),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
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
