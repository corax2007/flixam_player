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
import 'widgets/live_tv/aether_widgets.dart';
import 'models/live_tv_viewmodel.dart';
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
  bool showProviderNew = false;
  bool providerNewLoading = false;
  bool showDownloads = false;
  List<dynamic> downloadItems = [];
  Timer? _downloadTimer;
  bool zapping = false;
  bool previewActive = false;
  bool playerFromLive = false;
  int _zapToken = 0;
  int zapSeconds = 5;
  Timer? _zapTimer;
  bool showLiveTv = false;
  bool liveLoading = false;
  List<dynamic> liveChannels = [];
  Map<String, dynamic> liveEpg = {};
  Map<String, dynamic> liveProgramInfo = {};
  int selectedLiveIndex = 0;
  int liveCategory = 0;
  bool liveMultiSelect = false;
  final Set<String> liveSelected = {};
  final TextEditingController liveSearchCtrl = TextEditingController();
  bool showViewPanel = false;
  final Map<String, Map<String, dynamic>> _listPreviewBySection = {};
  bool showAddonCatalog = false;
  bool addonCatalogLoading = false;
  List<dynamic> addonSites = [];
  String? addonCatalogSite;
  String addonCatalogType = 'movie';
  int addonCatalogPages = 10;
  List<dynamic> addonCatalogItems = [];
  bool showNewSeries = false;
  bool newSeriesOriginals = true;
  bool newSeriesLoading = false;
  List<dynamic> newSeriesGroups = [];
  List<dynamic> providerNewGroups = [];
  final Set<int> _expandedSeries = {};
  final Map<int, String> _seriesYears = {};
  final Map<int, List<dynamic>> _seriesMoreItems = {};
  final Set<int> _seriesMoreLoading = {};
  final Set<int> _expandedProviders = {};
  final Map<int, String> _providerYears = {};
  final Map<int, List<dynamic>> _providerMoreItems = {};
  final Set<int> _providerMoreLoading = {};
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
  final List<Map<String, dynamic>> _episodeQueue = [];
  int _episodeIndex = 0;
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
      if (!completed) return;
      if (currentPlayingTitle != null) {
        prefs.savePosition(currentPlayingTitle!, 0);
      }
      if (_episodeQueue.isNotEmpty && _episodeIndex < _episodeQueue.length) {
        _playNextEpisode();
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
    _loadAvailability();
    if (!Platform.isAndroid) {
      _loadDownloads();
      _downloadTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted) _loadDownloads();
      });
    }
    _autoRefreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted && showHome) _refreshAll();
    });
  }

  void _activateView(String view) {
    setState(() {
      showHome = view == 'home';
      showFavorites = view == 'favorites';
      showSourceEpisodes = view == 'source';
      showProviderNew = view == 'provider';
      showNewSeries = view == 'series';
      showAddonCatalog = view == 'addon';
      showLiveTv = view == 'live';
      showDownloads = view == 'downloads';
      if (view != 'home') heroItem = null;
    });
  }

  Future<void> _loadAvailability() async {
    try {
      await AvailabilityService.instance.load();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  bool _onlyAvailable() => appSettings.availabilityMode == 1;

  bool _coverAvailable(dynamic item) {
    final set = AvailabilityService.instance.loadedTitles;
    if (set == null || set.isEmpty) return true;
    if (item is! Map) return false;
    return AvailabilityService.instance
        .isAvailable(item['title']?.toString() ?? '');
  }

  bool _availableBadge(dynamic item) {
    final set = AvailabilityService.instance.loadedTitles;
    if (set == null || set.isEmpty || item is! Map) return false;
    return AvailabilityService.instance
        .isAvailable(item['title']?.toString() ?? '');
  }

  List<dynamic> _availabilityFiltered(Iterable<dynamic> items) {
    if (!_onlyAvailable()) return items.toList();
    final set = AvailabilityService.instance.loadedTitles;
    if (set == null || set.isEmpty) return items.toList();
    return items.where(_coverAvailable).toList();
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
      if (_onlyAvailable()) {
        data = await AvailabilityService.instance.filterHome(data);
      }
      if (!mounted) return;
      setState(() {
        rawHomeData = data;
        homeData = data;
        // Keine Spezialansicht (Downloads/Live TV/...) durch ein nachtraeglich
        // fertig werdendes _loadHome ueberschreiben.
        if (!showFavorites &&
            !showSourceEpisodes &&
            !showProviderNew &&
            !showNewSeries &&
            !showAddonCatalog &&
            !showLiveTv &&
            !showDownloads) {
          showHome = true;
        }
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
    _activateView('home');
    setState(() {
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
    _downloadTimer?.cancel();
    _zapTimer?.cancel();
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
    playerFromLive = false;
    _episodeQueue.clear();
    _episodeIndex = 0;
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
    await _openStream(streamUrl, headers, title, resume: resume);
  }

  Future<void> _openStream(
    String streamUrl,
    Map<String, String> headers,
    String title, {
    bool resume = false,
  }) async {
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

  /// Mehrere Folgen vorbereiten. Der Wechsel läuft über unseren eigenen
  /// Countdown (Netflix/Amazon-Stil), nicht über die media_kit-Playlist.
  Future<void> _playEpisodes(List<Map<String, dynamic>> episodes) async {
    if (episodes.isEmpty) return;
    final first = episodes.first;
    await _play(first['url']?.toString() ?? '',
        first['title']?.toString() ?? 'Folge');
    _episodeQueue.clear();
    _episodeIndex = 0;
    for (final ep in episodes.skip(1)) {
      try {
        final r = await api.resolve(ep['url']?.toString() ?? '');
        final stream = r['stream_url']?.toString() ?? '';
        if (stream.isEmpty) continue;
        _episodeQueue.add({
          'stream': stream,
          'headers': Map<String, String>.from(r['headers'] ?? {}),
          'title': ep['title']?.toString() ?? 'Folge',
        });
      } catch (_) {}
    }
  }

  Future<void> _playNextEpisode() async {
    if (_episodeIndex >= _episodeQueue.length) return;
    final item = _episodeQueue[_episodeIndex];
    _episodeIndex++;
    await _openStream(
      item['stream']?.toString() ?? '',
      Map<String, String>.from(item['headers'] ?? {}),
      item['title']?.toString() ?? 'Folge',
    );
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

  /// Filter und Suche - aus dem Inhalt in die Optionen ausgelagert.
  Widget _settingsFilters() {
    final dd = <Widget>[];
    Widget dropdown(String label, String value, List<String> values,
            void Function(String) onChanged) =>
        SizedBox(
          width: 132,
          child: DropdownButton<String>(
            isExpanded: true,
            value: values.contains(value) ? value : values.first,
            hint: Text(label),
            items: [
              for (final v in values)
                DropdownMenuItem<String>(value: v, child: Text(v)),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        );

    dd.add(dropdown('Monat', monthFilter, [
      'Alle', 'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
      'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
    ], (v) {
      final map = {
        'Januar': '01', 'Februar': '02', 'März': '03', 'April': '04',
        'Mai': '05', 'Juni': '06', 'Juli': '07', 'August': '08',
        'September': '09', 'Oktober': '10', 'November': '11',
        'Dezember': '12', 'Alle': 'Alle',
      };
      setState(() => monthFilter = map[v] ?? 'Alle');
      _onFilterChanged();
    }));
    dd.add(dropdown('Typ', filterType.isEmpty ? 'Alle' : filterType,
        ['Alle', 'Filme', 'Serien'], (v) {
      setState(() {
        filterType = v == 'Alle' ? '' : (v == 'Filme' ? 'movie' : 'tv');
        selectedGenre = null;
      });
      _loadGenres();
      _onFilterChanged();
    }));
    final genreValues = <String>['Alle', ...genres.map((g) => g.toString())];
    dd.add(dropdown('Genre', selectedGenre ?? 'Alle', genreValues, (v) {
      setState(() => selectedGenre = v == 'Alle' ? null : v);
      _onFilterChanged();
    }));
    dd.add(dropdown('FSK', fskFilter, [
      'Alle', 'FSK 0', 'FSK 6', 'FSK 12', 'FSK 16', 'FSK 18',
    ], (v) {
      setState(() => fskFilter = v);
      _onFilterChanged();
    }));
    dd.add(dropdown('Sortierung', sortOrder, [
      'Standard', 'Jahr ↓', 'Jahr ↑', 'FSK ↓', 'Bewertung', 'Datum ↓', 'Datum ↑',
    ], (v) {
      setState(() => sortOrder = v);
      _onFilterChanged();
    }));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: searchCtrl,
          decoration: const InputDecoration(
            hintText: 'Titel suchen...',
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
          ),
          onSubmitted: (_) => _search(),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(
              width: 100,
              child: TextField(
                controller: yearCtrl,
                decoration: const InputDecoration(
                  hintText: 'Jahr',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8),
                ),
                onSubmitted: (_) => _onFilterChanged(),
                onChanged: (_) => _onFilterChanged(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _search();
                },
                icon: const Icon(Icons.search, size: 16),
                label: const Text('Suchen'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: dd),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton(
              onPressed: () {
                setState(() {
                  yearCtrl.clear();
                  searchCtrl.clear();
                  filterType = '';
                  selectedGenre = null;
                  fskFilter = 'Alle';
                  monthFilter = 'Alle';
                  sortOrder = 'Standard';
                });
                _loadGenres();
                _onFilterChanged();
              },
              child: const Text('Filter zurücksetzen'),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _toggleLiveTv();
              },
              icon: const Icon(Icons.live_tv, size: 15),
              label: const Text('Live TV'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _toggleAddonCatalog();
              },
              icon: const Icon(Icons.storage, size: 15),
              label: const Text('Addon-Bestand'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _toggleProviderNew();
              },
              icon: const Icon(Icons.new_releases, size: 15),
              label: const Text('Neu bei Anbietern'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _toggleNewSeries();
              },
              icon: const Icon(Icons.tv_outlined, size: 15),
              label: const Text('Neue Serien'),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  int settingsTab = 0;
  final ValueNotifier<int> settingsRevision = ValueNotifier(0);
  final TextEditingController tmdbKeyCtrl = TextEditingController();

  Future<void> _showSettings() async {
    try {
      final f = File('${Platform.environment['HOME'] ?? '.'}/.flixam_tmdb_key');
      if (f.existsSync()) tmdbKeyCtrl.text = f.readAsStringSync().trim();
    } catch (_) {}
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _buildSettingsScreen(),
      ),
    );
  }

  Widget _settingsRail() {
    final items = <Map<String, dynamic>>[
      {'icon': Icons.home_outlined, 'label': 'Home', 'tap': _goHome},
      {'icon': Icons.search, 'label': 'Suche', 'tap': _search},
      {'icon': Icons.movie_outlined, 'label': 'Filme', 'tap': _browseRoot},
      {'icon': Icons.favorite_border, 'label': 'Favoriten', 'tap': () {
        setState(() {
          _activateView(showFavorites ? 'home' : 'favorites');
        });
      }},
      {'icon': Icons.settings_outlined, 'label': 'Einstellungen', 'tap': null},
    ];
    return SizedBox(
      width: 68,
      child: Container(
        color: surf(context),
        child: Column(
          children: [
            const SizedBox(height: 16),
            for (final it in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: IconButton(
                  tooltip: it['label'] as String,
                  icon: Icon(it['icon'] as IconData,
                      color: it['tap'] == null ? accent(context) : Colors.white70),
                  onPressed: it['tap'] == null
                      ? null
                      : () async {
                          Navigator.of(context).pop();
                          (it['tap'] as VoidCallback).call();
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _settingsSwitch(String label, bool value, Future<void> Function(bool) onChanged,
      {String? hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (hint != null)
                  Text(hint,
                      style: const TextStyle(fontSize: 10, color: Colors.white54)),
              ],
            ),
          ),
          CupertinoSwitch(
            value: value,
            onChanged: (v) async {
              await onChanged(v);
              settingsRevision.value++;
            },
          ),
        ],
      ),
    );
  }

  Widget _settingsCard({required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surf(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _settingsTabContent() {
    switch (settingsTab) {
      case 0:
        return Column(
          children: [
            _settingsCard(title: 'Suche & Filter', child: _settingsFilters()),
            _settingsCard(
              title: 'Layout',
              child: Row(
                children: [
                  for (var i = 0; i < flixamLayouts.length; i++) ...[
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          setState(() => appSettings.layout = i);
                          await appSettings.save();
                          settingsRevision.value++;
                        },
                        child: _layoutPreview(i,
                            selected: appSettings.layout == i),
                      ),
                    ),
                    if (i < flixamLayouts.length - 1) const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
            _settingsCard(
              title: 'Design',
              child: Row(
                children: [
                  for (var i = 0; i < flixamDesigns.length; i++) ...[
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          setState(() => appSettings.design = i);
                          await appSettings.save();
                          widget.onDesignChanged?.call(i);
                          settingsRevision.value++;
                        },
                        child: _designPreview(flixamDesigns[i],
                            selected: appSettings.design == i),
                      ),
                    ),
                    if (i < flixamDesigns.length - 1) const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        );
      case 1:
        return Column(
          children: [
            _settingsCard(
              title: 'Verfügbarkeit',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Zeige nur Titel, die in unseren Quellen vorhanden sind',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in [0, 1])
                        ChoiceChip(
                          label: Text(mode == 0 ? 'Alle Titel' : 'Nur in unseren Quellen'),
                          selected: appSettings.availabilityMode == mode,
                          onSelected: (_) async {
                            setState(() {
                              appSettings.availabilityMode = mode;
                              _fullSections.clear();
                            });
                            await appSettings.save();
                            settingsRevision.value++;
                            await _loadHome();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
            _settingsCard(
              title: 'Quellen',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (Platform.isAndroid)
                    _settingsSwitch(
                      'Nur verfügbare Titel zeigen',
                      appSettings.onlyAvailable,
                      (v) async {
                        setState(() => appSettings.onlyAvailable = v);
                        await appSettings.save();
                        await _loadHome();
                      },
                    ),
                  Text('Aktives Addon: ${addon == 'xstream' ? 'xStream' : 'xShip'}',
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 10),
                  Text('Eigene Quellen: ${CustomSources.path}',
                      style: const TextStyle(fontSize: 10, color: Colors.white54)),
                  TextButton(
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
          ],
        );
      case 2:
        return Column(
          children: [
            _settingsCard(
              title: 'Wiedergabe',
              child: Column(
                children: [
                  _settingsSwitch(
                    'Staffel ohne Pause abspielen',
                    appSettings.autoPlaySeason,
                    (v) async {
                      setState(() => appSettings.autoPlaySeason = v);
                      await appSettings.save();
                    },
                    hint: 'Folgen automatisch nacheinander',
                  ),
                  _settingsSwitch(
                    'Hero-Details beim Browse',
                    appSettings.heroInBrowse,
                    (v) async {
                      setState(() => appSettings.heroInBrowse = v);
                      await appSettings.save();
                    },
                  ),
                ],
              ),
            ),
            _settingsCard(
              title: 'Sprache der Titel',
              child: Wrap(
                spacing: 8,
                children: [
                  for (final mode in [0, 1, 2])
                    ChoiceChip(
                      label: Text(['Alle', 'Nur Deutsch', 'Nur Englisch'][mode]),
                      selected: appSettings.languageMode == mode,
                      onSelected: (_) async {
                        setState(() {
                          appSettings.languageMode = mode;
                          appSettings.onlyGerman = mode == 1;
                        });
                        await appSettings.save();
                        settingsRevision.value++;
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      case 3:
        return Column(
          children: [
            _settingsCard(
              title: 'VPN-Tunnel aktivieren (WireProxy)',
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.circle, size: 9,
                          color: hasVpnConfig ? Colors.green : Colors.orange),
                      const SizedBox(width: 6),
                      const Text('Wireproxy läuft: ja',
                          style: TextStyle(fontSize: 12)),
                      const Spacer(),
                      CupertinoSwitch(value: vpnEnabled,
                          onChanged: (v) async => _toggleVpn(v)),
                    ],
                  ),
                  if (!hasVpnConfig)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'wg0.conf nicht mit echten Zugangsdaten befüllt.',
                        style: TextStyle(color: Colors.orange, fontSize: 11),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _importConf,
                      icon: const Icon(Icons.upload_file, size: 16),
                      label: const Text('WireGuard-Config (.conf) importieren'),
                    ),
                  ),
                ],
              ),
            ),
            _settingsCard(
              title: 'TMDB API Key',
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: tmdbKeyCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Key speichern',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final key = tmdbKeyCtrl.text.trim();
                      try {
                        await File('${Platform.environment['HOME'] ?? '.'}/.flixam_tmdb_key')
                            .writeAsString(key);
                        if (!api.useDirect) await _saveTmdb(key);
                        TmdbService.instance.reload();
                      } catch (_) {}
                    },
                    child: const Text('Speichern'),
                  ),
                ],
              ),
            ),
            _settingsCard(
              title: 'Backend-Adresse (Fire TV / LAN)',
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: backendCtrl,
                      decoration: const InputDecoration(
                        hintText: 'http://127.0.0.1:8000',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
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
                      settingsRevision.value++;
                    },
                    child: const Text('Speichern'),
                  ),
                ],
              ),
            ),
          ],
        );
      case 4:
        return Column(
          children: [
            _settingsCard(
              title: 'HLS-Cache',
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 140, child: Text('Puffer (Sek.)')),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: cacheCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const SizedBox(width: 140, child: Text('Max. Cache (MB)')),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: demuxMaxCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const SizedBox(width: 140, child: Text('Burst (MB)')),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: demuxBurstCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(isDense: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton(
                      onPressed: _saveCacheSettings,
                      child: const Text('Cache-Einstellungen speichern'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      default:
        return _settingsCard(
          title: 'Erweitert',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Eigene Quellen',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(CustomSources.path,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              TextButton(
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
        );
    }
  }

  Widget _buildSettingsScreen() {
    final d = designAt(appSettings.design);
    final tabNames = [
      'Allgemein', 'Anbieter', 'Player', 'Netzwerk', 'Cache', 'Erweitert'
    ];
    return ValueListenableBuilder<int>(
      valueListenable: settingsRevision,
      builder: (context, revision, _) => Scaffold(
      backgroundColor: bg(context),
      body: Row(
        children: [
          _settingsRail(),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 60,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  decoration: BoxDecoration(
                    color: surf(context),
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text('XStream',
                          style: TextStyle(
                              color: d.accent,
                              fontSize: 16,
                              fontWeight: FontWeight.w800)),
                      Expanded(
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.settings_outlined,
                                  size: 20, color: d.accent),
                              const SizedBox(width: 8),
                              const Text('Einstellungen',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Schließen',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 18),
                      for (var i = 0; i < tabNames.length; i++) ...[
                        ChoiceChip(
                          label: Text(tabNames[i]),
                          selected: settingsTab == i,
                          onSelected: (_) {
                            setState(() => settingsTab = i);
                            settingsRevision.value++;
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 900),
                        child: _settingsTabContent(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
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
        if (!Platform.isAndroid)
          const PopupMenuItem(value: 'download', child: Text('Herunterladen')),
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
      case 'download':
        try {
          final r = await api.startDownload(
            item['url']?.toString() ?? '',
            title,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  r['ok'] == true
                      ? 'Download gestartet: $title'
                      : 'Download fehlgeschlagen: ${r['error'] ?? ''}',
                ),
              ),
            );
          }
        } catch (_) {}
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

  Future<void> _loadStreamingProviders() async {
    try {
      final list = await api.providers();
      if (!mounted) return;
      setState(() => streamingProviders = list);
    } catch (_) {}
  }

  Future<void> _loadNewSeries({bool? originals}) async {
    if (originals != null) newSeriesOriginals = originals;
    setState(() => newSeriesLoading = true);
    try {
      final groups = await api.newSeries(originals: newSeriesOriginals);
      if (mounted) setState(() => newSeriesGroups = groups);
    } catch (_) {}
    if (mounted) setState(() => newSeriesLoading = false);
  }

  Future<void> _toggleNewSeries() async {
    if (showNewSeries) {
      _activateView('home');
      return;
    }
    searchCtrl.clear();
    _activateView('series');
    if (newSeriesGroups.isEmpty) await _loadNewSeries();
  }

  Future<void> _changeSeriesYear(dynamic group, String year) async {
    final id = int.tryParse(group['id']?.toString() ?? '') ?? 0;
    setState(() {
      _seriesYears[id] = year;
      _expandedSeries.add(id);
      _seriesMoreLoading.add(id);
    });
    try {
      final items = await api.seriesNetworkItems(
        id,
        limit: year == 'Alle' ? 200 : 300,
        year: year,
      );
      if (mounted) setState(() => _seriesMoreItems[id] = items);
    } catch (_) {}
    if (mounted) setState(() => _seriesMoreLoading.remove(id));
  }

  Future<void> _toggleSeriesMore(dynamic group) async {
    final id = int.tryParse(group['id']?.toString() ?? '') ?? 0;
    if (_expandedSeries.contains(id)) {
      setState(() => _expandedSeries.remove(id));
      return;
    }
    setState(() {
      _expandedSeries.add(id);
      _seriesMoreLoading.add(id);
    });
    if (!_seriesMoreItems.containsKey(id)) {
      try {
        final items = await api.seriesNetworkItems(id, limit: 200);
        if (mounted) setState(() => _seriesMoreItems[id] = items);
      } catch (_) {}
    }
    if (mounted) setState(() => _seriesMoreLoading.remove(id));
  }

  List<Widget> _buildNewSeriesSlivers() {
    final list = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  newSeriesOriginals
                      ? 'Neue Serien · Eigenproduktionen'
                      : 'Neue Serien · alle',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              ActionChip(
                label: Text(
                    newSeriesOriginals ? 'Alle Serien' : 'Nur Originals'),
                onPressed: () => _loadNewSeries(
                    originals: !newSeriesOriginals),
              ),
              IconButton(
                tooltip: 'Schließen',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => showNewSeries = false),
              ),
            ],
          ),
        ),
      ),
    ];
    if (newSeriesLoading) {
      list.add(const SliverToBoxAdapter(
        child: SizedBox(
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        ),
      ));
      return list;
    }
    if (newSeriesGroups.isEmpty) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Keine neuen Serien gefunden.'),
        ),
      ));
      return list;
    }
    for (final g in newSeriesGroups) {
      final items = _availabilityFiltered(_langFiltered(
          ((g['items'] as List?) ?? [])
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())));
      if (items.isEmpty) continue;
      final finalSid = int.tryParse(g['id']?.toString() ?? '') ?? 0;
      list.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Icon(Icons.tv_outlined, size: 16, color: accent(context)),
              const SizedBox(width: 6),
              Text(
                g['name']?.toString() ?? 'Netzwerk',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _seriesYears[finalSid] ?? 'Alle',
                isDense: true,
                items: [
                  for (final y in [
                    'Alle', '2026', '2025', '2024', '2023', '2022', '2021', '2020'
                  ])
                    DropdownMenuItem<String>(value: y, child: Text(y)),
                ],
                onChanged: (v) {
                  if (v != null) _changeSeriesYear(g, v);
                },
              ),
              const Spacer(),
              if (_seriesMoreLoading.contains(finalSid))
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: () => _toggleSeriesMore(g),
                  child: Text(_expandedSeries.contains(finalSid)
                      ? 'weniger'
                      : 'mehr'),
                ),
            ],
          ),
        ),
      ));
      final showAll = _expandedSeries.contains(finalSid);
      final all = showAll
          ? _langFiltered(_seriesMoreItems[finalSid] ?? items)
          : items;
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
            (ctx, i) => _homeItemCard(all[i], autofocus: i == 0),
            childCount: all.length,
          ),
        ),
      ));
    }
    return list;
  }

  Future<void> _loadAddonCatalog({bool more = false}) async {
    if (addonCatalogSite == null || addonCatalogSite!.isEmpty) return;
    if (!more) {
      setState(() {
        addonCatalogPages = 10;
        addonCatalogItems = [];
        addonCatalogLoading = true;
      });
    } else {
      setState(() {
        addonCatalogPages += 10;
        addonCatalogLoading = true;
      });
    }
    final items = await api.addonCatalog(
      addonCatalogSite!,
      addonCatalogType,
      pages: addonCatalogPages,
    );
    if (mounted) {
      setState(() {
        addonCatalogItems = items;
        addonCatalogLoading = false;
      });
    }
  }

  static const List<String> liveCategories = [
    'Alle', 'Favoriten', 'Öffentlich-rechtlich', 'Sky', 'Sport', 'Filme',
    'Dokumentar', 'Nachrichten', 'Kinder', 'Musik', 'Sonstige',
    'Ausgeblendet',
  ];

  int _channelCategory(String title) {
    final t = title.toLowerCase();
    bool has(List<String> words) => words.any(t.contains);
    if (has(['sky'])) {
    return 3;
  }
    if (has([
      'ard', 'zdf', 'orf', 'srf', '3sat', 'arte', 'kika', 'wdr', 'ndr',
      'swr', 'mdr', 'rbb', 'deutschlandfunk', 'phoenix', 'zdfinfo',
      'tagesschau', 'srv', 'rts', 'vrt', 'npo', 'brav'
    ])) {
    return 2;
  }
    if (has([
      'sport', 'eurosport', 'dazn', 'wwe', 'fight', 'golf', 'tennis',
      'fussball', 'fußball', 'bundesliga', 'uefa', 'olympia',
      'motorsport', 'formula', 'nfl', 'nba', 'hockey', 'boxen',
      'sportdeutschland', 'sportschau'
    ])) {
    return 4;
  }
    if (has([
      'film', 'movie', 'cinema', 'kino', 'tcm', 'warner', 'universal',
      'action', 'thriller', 'horror', 'classic', 'sky cinema'
    ])) {
    return 5;
  }
    if (has([
      'doku', 'documentary', 'discovery', 'nat geo', 'national geographic',
      'animal', 'planet', 'history', 'wissen', 'biologie', 'technik'
    ])) {
    return 6;
  }
    if (has([
      'news', 'n24', 'welt', 'ntv', 'n-tv', 'cnn', 'bloomberg',
      'euronews', 'france 24', 'dw', 'deutsche welle'
    ])) {
    return 7;
  }
    if (has([
      'disney', 'nick', 'cartoon', 'kids', 'baby', 'junior', 'family',
      'zeichentrick', 'pbs kids'
    ])) {
    return 8;
  }
    if (has([
      'mtv', 'viva', 'music', 'musik', 'radio', 'hit', 'pop', 'rock',
      'jazz', 'classical', 'soundtrack'
    ])) {
    return 9;
  }
    return 10;
  }

  Future<void> _loadDownloads() async {
    final items = await api.downloadStatus();
    if (mounted) setState(() => downloadItems = items);
  }

  void _stopZap() {
    _zapToken++;
    _zapTimer?.cancel();
    _zapTimer = null;
    if (zapping) setState(() => zapping = false);
  }

  void _zapStep(int delta) {
    final vms = _liveChannelVms();
    if (vms.isEmpty) return;
    final next = (selectedLiveIndex + delta).clamp(0, vms.length - 1);
    _selectLiveChannel(next, vms);
    if (zapping) _zapOpenStream(vms[next]);
  }

  Future<void> _zapOpenStream(LiveChannelVm vm) async {
    final token = ++_zapToken;
    if (vm.url.isEmpty) return;
    try {
      final r = await api.resolve(vm.url);
      if (token != _zapToken || !mounted) return;
      final s = r['stream_url']?.toString() ?? '';
      if (s.isEmpty) {
        if (mounted) setState(() => previewActive = false);
        return;
      }
      await player.open(Media(
        s,
        httpHeaders: Map<String, String>.from(r['headers'] ?? {}),
      ));
      if (token != _zapToken || !mounted) return;
      await player.play();
      if (mounted) setState(() => previewActive = true);
    } catch (_) {
      if (token != _zapToken || !mounted) return;
      if (mounted) setState(() => previewActive = false);
    }
  }

  Future<void> _playLiveChannel(LiveChannelVm vm) async {
    await _play(vm.url, vm.name);
    playerFromLive = true;
    if (mounted) setState(() {});
  }

  Future<void> _switchLiveChannel(int delta) async {
    final vms = _liveChannelVms();
    if (vms.isEmpty) return;
    final idx = (selectedLiveIndex + delta) % vms.length;
    setState(() => selectedLiveIndex = idx);
    await _playLiveChannel(vms[idx]);
  }

  void _startZap() {
    if (zapping) {
      _stopZap();
      return;
    }
    setState(() => zapping = true);
    final vms = _liveChannelVms();
    if (vms.isNotEmpty) _zapOpenStream(vms[selectedLiveIndex]);
    _zapTimer = Timer.periodic(Duration(seconds: zapSeconds), (_) {
      if (!mounted || !showLiveTv || showPlayer) return;
      _zapStep(1);
    });
  }

  void _setZapSpeed(int seconds) {
    zapSeconds = seconds;
    setState(() {});
    if (zapping) {
      _zapTimer?.cancel();
      _zapTimer = Timer.periodic(Duration(seconds: zapSeconds), (_) {
        if (!mounted || !showLiveTv || showPlayer) return;
        _zapStep(1);
      });
    }
  }

  Future<void> _toggleDownloads() async {
    if (showDownloads) {
      _activateView('home');
      return;
    }
    _activateView('downloads');
    await _loadDownloads();
  }

  List<Widget> _buildDownloadsSlivers() {
    final list = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Downloads (${downloadItems.length})',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Schließen',
                icon: const Icon(Icons.close),
                onPressed: () => _toggleDownloads(),
              ),
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text(
            'Nur für Inhalte verwenden, die du legal abspeichern darfst.',
            style: TextStyle(fontSize: 10, color: Colors.white54),
          ),
        ),
      ),
    ];
    if (downloadItems.isEmpty) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Noch keine Downloads. Langdruck auf ein Cover → „Herunterladen".'),
        ),
      ));
      return list;
    }
    list.add(SliverList(
      delegate: SliverChildBuilderDelegate(
        (ctx, i) {
          final d = downloadItems[i] as Map<String, dynamic>;
          final key = d['key']?.toString() ?? '';
          final title = d['title']?.toString() ?? key;
          final status = d['status']?.toString() ?? '';
          final progress = (d['progress'] as num?)?.toDouble() ?? 0;
          return Card(
            color: surf(context),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(status,
                          style: TextStyle(
                            fontSize: 10,
                            color: status == 'done'
                                ? Colors.green
                                : Colors.white54,
                          )),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: status == 'done' ? 1.0 : progress,
                    minHeight: 5,
                    color: accent(context),
                    backgroundColor: Colors.white12,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status == 'done'
                        ? '100 % · abgeschlossen'
                        : status == 'error'
                            ? 'Fehler'
                            : '${(progress * 100).round()} %'
                                '${((d['duration'] as num?)?.toDouble() ?? 0) > 0
                                    ? ' · ${_fmtClock(Duration(seconds: (d['elapsed'] as num?)?.toInt() ?? 0))} / ${_fmtClock(Duration(seconds: (d['duration'] as num).toInt()))}'
                                    : ''}',
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (status == 'done')
                        ElevatedButton.icon(
                          onPressed: () =>
                              _play(api.downloadUrl(key), title),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('Abspielen'),
                        ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Löschen',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          await api.deleteDownload(key);
                          await _loadDownloads();
                        },
                      ),
                    ],
                  ),
                  if (d['error']?.toString().isNotEmpty ?? false)
                    Text(
                      d['error'].toString(),
                      maxLines: 2,
                      style: const TextStyle(
                          fontSize: 9, color: Colors.redAccent),
                    ),
                ],
              ),
            ),
          );
        },
        childCount: downloadItems.length,
      ),
    ));
    return list;
  }

  Future<void> _toggleLiveTv() async {
    if (showLiveTv) {
      _stopZap();
      _zapToken++;
      player.stop();
      if (mounted) setState(() => previewActive = false);
      _activateView('home');
      return;
    }
    searchCtrl.clear();
    _activateView('live');
    if (liveChannels.isEmpty) {
      setState(() => liveLoading = true);
      final channels = await api.vavooChannels();
      if (mounted) {
        setState(() {
          liveChannels = channels;
          liveLoading = false;
        });
        _loadLiveEpg();
      }
    }
  }

  Future<void> _loadLiveEpg() async {
    final epg = await api.vavooEpg();
    if (mounted) setState(() => liveEpg = epg);
  }

  List<dynamic> _filteredLiveChannels() {
    final q = liveSearchCtrl.text.trim().toLowerCase();
    return liveChannels.where((c) {
      final title = c['title']?.toString() ?? '';
      if (q.isNotEmpty && !title.toLowerCase().contains(q)) return false;
      final hidden = prefs.isChannelHidden(title);
      if (liveCategory == 11) return hidden;
      if (hidden) return false;
      final cat = _channelCategory(title);
      if (prefs.isCategoryHidden(cat)) return false;
      if (liveCategory == 1) return prefs.isFavoriteChannel(title);
      if (liveCategory == 0) return true;
      return cat == liveCategory;
    }).toList();
  }

  List<LiveChannelVm> _liveChannelVms() {
    return _filteredLiveChannels().map((raw) {
      final map = (raw as Map).cast<String, dynamic>();
      final name = map['title']?.toString() ?? '';
      return LiveChannelVm.fromRaw(
        channel: map,
        epg: (liveEpg[name] as Map?)?.cast<String, dynamic>(),
        favorite: prefs.isFavoriteChannel(name),
        category: liveCategories[_channelCategory(name)],
      );
    }).toList();
  }

  Future<void> _selectLiveChannel(int index, List<LiveChannelVm> vms) async {
    if (index < 0 || index >= vms.length) return;
    setState(() => selectedLiveIndex = index);
    final program = vms[index].program;
    if (program.isEmpty || liveProgramInfo.containsKey(program)) return;
    final info = await api.vavooProgramInfo(program);
    if (mounted) setState(() => liveProgramInfo[program] = info);
  }

  List<Widget> _buildLiveTvSlivers() {
    final list = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Live TV · Vavoo (${liveChannels.length})',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: zapping ? 'Zap stoppen' : 'Zap starten',
                icon: Icon(
                  zapping ? Icons.stop_circle : Icons.play_circle_outline,
                  color: zapping ? accent(context) : Colors.white70,
                ),
                onPressed: _startZap,
              ),
              IconButton(
                tooltip: 'Vorheriger Sender',
                icon: const Icon(Icons.skip_previous, size: 20),
                onPressed: () => _zapStep(-1),
              ),
              IconButton(
                tooltip: 'Nächster Sender',
                icon: const Icon(Icons.skip_next, size: 20),
                onPressed: () => _zapStep(1),
              ),
              DropdownButton<int>(
                value: zapSeconds,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 3, child: Text('3 s')),
                  DropdownMenuItem(value: 5, child: Text('5 s')),
                  DropdownMenuItem(value: 10, child: Text('10 s')),
                ],
                onChanged: (v) {
                  if (v != null) _setZapSpeed(v);
                },
              ),
              IconButton(
                tooltip: liveMultiSelect ? 'Auswahl beenden' : 'Mehrfachauswahl',
                icon: Icon(liveMultiSelect
                    ? Icons.checklist
                    : Icons.checklist_outlined),
                onPressed: () => setState(() {
                  liveMultiSelect = !liveMultiSelect;
                  liveSelected.clear();
                }),
              ),
              IconButton(
                tooltip: 'Schließen',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _stopZap();
                  _activateView('home');
                },
              ),
            ],
          ),
        ),
      ),
    ];
    if (zapping) {
      list.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            'Zap läuft · wechselt alle $zapSeconds Sekunden '
            '(Klick auf einen Sender stoppt)',
            style: TextStyle(fontSize: 11, color: accent(context)),
          ),
        ),
      ));
    }
    if (liveMultiSelect) {
      list.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 8,
            children: [
              Text('Auswahl: ${liveSelected.length}',
                  style: const TextStyle(fontSize: 12)),
              ActionChip(
                label: const Text('Alle auswählen'),
                onPressed: () => setState(() {
                  liveSelected.addAll(
                    _filteredLiveChannels()
                        .map((c) => c['title']?.toString() ?? ''),
                  );
                }),
              ),
              ActionChip(
                label: const Text('Zu Favoriten'),
                onPressed: () async {
                  await prefs.addFavoriteChannels(liveSelected);
                  if (!mounted) return;
                  setState(() {
                    liveCategory = 1;
                    liveMultiSelect = false;
                    liveSelected.clear();
                  });
                },
              ),
              ActionChip(
                label: const Text('Auswahl leeren'),
                onPressed: () => setState(() => liveSelected.clear()),
              ),
            ],
          ),
        ),
      ));
    }
    if (Platform.isAndroid) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Live TV benötigt das Linux-Backend (Vavoo-Addon).',
            style: TextStyle(color: Colors.orange),
          ),
        ),
      ));
      return list;
    }
    list.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: TextField(
          controller: liveSearchCtrl,
          decoration: const InputDecoration(
            hintText: 'Sender suchen...',
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
    ));
    list.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (var i = 0; i < liveCategories.length; i++)
              GestureDetector(
                onLongPress: i >= 2
                    ? () async {
                        await prefs.toggleHiddenCategory(i);
                        if (mounted) setState(() {});
                      }
                    : null,
                child: ChoiceChip(
                label: Text(
                  liveCategories[i],
                  style: TextStyle(
                    fontSize: 10,
                    color: prefs.isCategoryHidden(i) ? Colors.redAccent : null,
                    decoration: prefs.isCategoryHidden(i)
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                selected: liveCategory == i,
                tooltip: i >= 2
                    ? 'Langdruck: ${liveCategories[i]} aus-/einblenden'
                    : null,
                onSelected: (_) async {
                  setState(() => liveCategory = i);
                },
              ),
              ),
          ],
        ),
      ),
    ));
    if (liveLoading) {
      list.add(const SliverToBoxAdapter(
        child: SizedBox(
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        ),
      ));
      return list;
    }
    final channels = _filteredLiveChannels();
    if (channels.isEmpty) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Keine Sender gefunden.'),
        ),
      ));
      return list;
    }
    final vms = _liveChannelVms();
    if (vms.isEmpty) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Keine Sender gefunden.'),
        ),
      ));
      return list;
    }
    if (selectedLiveIndex >= vms.length) selectedLiveIndex = vms.length - 1;
    final currentVm = vms[selectedLiveIndex];
    final inspector = InspectorVm.fromRaw(
      channel: currentVm,
      info: (liveProgramInfo[currentVm.program] as Map?)
          ?.cast<String, dynamic>(),
    );
    list.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                    event.logicalKey == LogicalKeyboardKey.arrowUp ||
                    event.logicalKey == LogicalKeyboardKey.arrowRight ||
                    event.logicalKey == LogicalKeyboardKey.arrowLeft)) {
              final delta = (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                      event.logicalKey == LogicalKeyboardKey.arrowRight)
                  ? 1
                  : -1;
              _selectLiveChannel(
                (selectedLiveIndex + delta).clamp(0, vms.length - 1),
                vms,
              );
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
            height: 560,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 45,
                  child: ListView.builder(
                    itemCount: vms.length,
                    itemBuilder: (ctx, i) {
                      final vm = vms[i];
                      return ChannelListTile(
                        channel: vm,
                        selected: i == selectedLiveIndex,
                        onTap: () {
                          if (zapping) _stopZap();
                          if (liveMultiSelect) {
                            setState(() {
                              if (!liveSelected.remove(vm.name)) {
                                liveSelected.add(vm.name);
                              }
                            });
                          } else {
                            _selectLiveChannel(i, vms);
                          }
                        },
                        onDoubleTap: () => _playLiveChannel(vm),
                        onFavorite: () async {
                          await prefs.toggleFavoriteChannel(vm.name);
                          if (mounted) setState(() {});
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 400,
                  child: Card(
                    color: AetherColors.card.withValues(alpha: 0.82),
                    shape: RoundedRectangleBorder(
                      borderRadius: const BorderRadius.all(
                        AetherColors.cardRadius,
                      ),
                      side: const BorderSide(color: AetherColors.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: EpgInspectorPanel(
                        vm: inspector,
                        onPlay: () => _playLiveChannel(currentVm),
                        videoPreview: previewActive && !showPlayer
                            ? ClipRRect(
                                borderRadius: const BorderRadius.all(
                                  AetherColors.cardRadius,
                                ),
                                child: Video(
                                  controller: videoController,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    return list;
  }

  Future<void> _toggleAddonCatalog() async {
    if (showAddonCatalog) {
      _activateView('home');
      return;
    }
    searchCtrl.clear();
    _activateView('addon');
    if (addonSites.isEmpty) {
      final sites = await api.addonCatalogSites();
      if (mounted) setState(() => addonSites = sites);
      if (sites.isNotEmpty && addonCatalogSite == null) {
        addonCatalogSite = sites.first.toString();
      }
    }
    if (addonCatalogSite != null) await _loadAddonCatalog();
  }

  List<Widget> _buildAddonCatalogSlivers() {
    final list = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Addon-Bestand'
                  '${addonCatalogSite != null ? ' · $addonCatalogSite' : ''}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Schließen',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => showAddonCatalog = false),
              ),
            ],
          ),
        ),
      ),
    ];
    if (addonSites.isEmpty) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Keine Addon-Quellen gefunden.'),
        ),
      ));
      return list;
    }
    list.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            DropdownButton<String>(
              value: addonCatalogSite,
              items: [
                for (final site in addonSites)
                  DropdownMenuItem<String>(
                    value: site.toString(),
                    child: Text(site.toString()),
                  ),
              ],
              onChanged: (v) async {
                setState(() => addonCatalogSite = v);
                await _loadAddonCatalog();
              },
            ),
            ChoiceChip(
              label: const Text('Filme'),
              selected: addonCatalogType == 'movie',
              onSelected: (_) async {
                setState(() => addonCatalogType = 'movie');
                await _loadAddonCatalog();
              },
            ),
            ChoiceChip(
              label: const Text('Serien'),
              selected: addonCatalogType == 'tv',
              onSelected: (_) async {
                setState(() => addonCatalogType = 'tv');
                await _loadAddonCatalog();
              },
            ),
            if (!addonCatalogLoading && addonCatalogItems.isNotEmpty)
              ActionChip(
                label: const Text('mehr'),
                onPressed: () => _loadAddonCatalog(more: true),
              ),
          ],
        ),
      ),
    ));
    if (addonCatalogLoading) {
      list.add(const SliverToBoxAdapter(
        child: SizedBox(
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        ),
      ));
      return list;
    }
    if (addonCatalogItems.isEmpty) {
      list.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Keine Titel in dieser Quelle gefunden.'),
        ),
      ));
      return list;
    }
    var items = _availabilityFiltered(_langFiltered(addonCatalogItems));
    if (!api.useDirect) {
      items = items.map((m) {
        final copy = Map<String, dynamic>.from(m as Map);
        final poster = copy['poster_url']?.toString() ?? '';
        if (poster.startsWith('http') &&
            !poster.contains('image.tmdb.org')) {
          copy['poster_url'] =
              '${api.baseUrl}/art/proxy?url=${Uri.encodeComponent(poster)}';
        }
        return copy;
      }).toList();
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
          (ctx, i) => _homeItemCard(items[i], autofocus: i == 0),
          childCount: items.length,
        ),
      ),
    ));
    return list;
  }

  Future<void> _reloadProviderNew() async {
    setState(() {
      providerNewLoading = true;
      providerNewGroups = [];
    });
    final groups = await api.providerRecent();
    if (mounted) {
      setState(() {
        providerNewGroups = groups;
        providerNewLoading = false;
      });
    }
  }

  Future<void> _toggleProviderNew() async {
    if (showProviderNew) {
      _activateView('home');
      return;
    }
    searchCtrl.clear();
    _activateView('provider');
    setState(() => providerNewLoading = true);
    if (providerNewGroups.isEmpty) {
      try {
        final groups = await api.providerRecent();
        if (mounted) setState(() => providerNewGroups = groups);
      } catch (_) {}
    }
    if (mounted) setState(() => providerNewLoading = false);
  }

  Future<void> _changeProviderYear(dynamic group, String year) async {
    final id = int.tryParse(group['id']?.toString() ?? '') ?? 0;
    setState(() {
      _providerYears[id] = year;
      _expandedProviders.add(id);
      _providerMoreLoading.add(id);
    });
    try {
      final items = await api.providerRecentItems(
        id,
        limit: year == 'Alle' ? 200 : 300,
        year: year,
      );
      if (mounted) setState(() => _providerMoreItems[id] = items);
    } catch (_) {}
    if (mounted) setState(() => _providerMoreLoading.remove(id));
  }

  Future<void> _toggleProviderMore(dynamic group) async {
    final id = int.tryParse(group['id']?.toString() ?? '') ?? 0;
    if (_expandedProviders.contains(id)) {
      setState(() => _expandedProviders.remove(id));
      return;
    }
    setState(() {
      _expandedProviders.add(id);
      _providerMoreLoading.add(id);
    });
    if (!_providerMoreItems.containsKey(id)) {
      try {
        final items = await api.providerRecentItems(id, limit: 60);
        if (mounted) setState(() => _providerMoreItems[id] = items);
      } catch (_) {}
    }
    if (mounted) setState(() => _providerMoreLoading.remove(id));
  }

  List<Widget> _buildProviderNewSlivers() {
    if (providerNewLoading) {
      return [
        const SliverToBoxAdapter(
          child: SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (providerNewGroups.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Keine neuen Titel bei den Anbietern gefunden.'),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _reloadProviderNew,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Erneut laden'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    final list = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Neu bei allen Anbietern',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Schließen',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => showProviderNew = false),
              ),
            ],
          ),
        ),
      ),
    ];
    for (final g in providerNewGroups) {
      final items = _availabilityFiltered(_langFiltered(
          ((g['items'] as List?) ?? [])
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())));
      if (items.isEmpty) continue;
      final pid = int.tryParse(g['id']?.toString() ?? '') ?? 0;
      final expanded = _expandedProviders.contains(pid);
      list.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Icon(Icons.new_releases, size: 16, color: accent(context)),
              const SizedBox(width: 6),
              Text(
                g['name']?.toString() ?? 'Anbieter',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _providerYears[pid] ?? 'Alle',
                isDense: true,
                items: [
                  for (final y in [
                    'Alle', '2026', '2025', '2024', '2023', '2022', '2021', '2020'
                  ])
                    DropdownMenuItem<String>(value: y, child: Text(y)),
                ],
                onChanged: (v) {
                  if (v != null) _changeProviderYear(g, v);
                },
              ),
              const Spacer(),
              if (_providerMoreLoading.contains(pid))
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: () => _toggleProviderMore(g),
                  child: Text(expanded ? 'weniger' : 'mehr'),
                ),
            ],
          ),
        ),
      ));
      if (expanded) {
        final all = _providerMoreItems[pid] ?? items;
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
              (ctx, i) => _homeItemCard(all[i], autofocus: i == 0),
              childCount: all.length,
            ),
          ),
        ));
      } else {
        list.add(SliverToBoxAdapter(
          child: _buildCoverRow(items,
              section: g['name']?.toString() ?? ''),
        ));
      }
    }
    return list;
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
      if (_onlyAvailable()) {
        await AvailabilityService.instance.load();
        all = _availabilityFiltered(all);
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

  bool _langOk(dynamic item) {
    final mode = appSettings.languageMode;
    if (mode == 0) return true;
    if (item is! Map) return false;
    final lang = item['original_language']?.toString() ?? '';
    // Lokale deutsche Quellen sind als 'de' markiert.
    if (mode == 1) return lang == 'de';
    return lang == 'en';
  }

  List<dynamic> _langFiltered(Iterable<dynamic> items) =>
      items.where(_langOk).toList();

  Future<List<dynamic>> _applyFilters(List<dynamic> input, {bool skipFsk = false}) async {
    final year = yearCtrl.text.trim();
    var out = input.where((i) {
      if (!_langOk(i)) return false;
      if (!_coverAvailable(i)) return false;
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
  Widget _buildCoverRow(List<dynamic> items, {String section = ''}) {
    final mode = appSettings.viewMode;
    if (mode != 0 && mode != 1) {
      return SizedBox(
        height: _viewRowHeight(),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (ctx, i) =>
              _homeItemCard(items[i] as Map<String, dynamic>, autofocus: i == 0),
        ),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();
    final preview = _listPreviewBySection[section] ??
        (items.first as Map<String, dynamic>);
    final listPane = Expanded(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final it = items[i] as Map<String, dynamic>;
          final title = it['title']?.toString() ?? '';
          final selected = preview['title'] == it['title'];
          final thumb = it['poster_url']?.toString() ?? '';
          return ListTile(
            dense: true,
            selected: selected,
            selectedTileColor: accent(context).withValues(alpha: 0.22),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 42,
                height: 62,
                child: thumb.isNotEmpty
                    ? Image.network(thumb, fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Container(color: Colors.grey.shade900))
                    : Container(color: Colors.grey.shade900),
              ),
            ),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(it['year']?.toString() ?? '',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
            onTap: () {
              setState(() => _listPreviewBySection[section] = it);
              _loadHeroSources(title);
              _loadHeroTrailer(it);
            },
          );
        },
      ),
    );
    final poster = preview['poster_url']?.toString() ?? '';
    final previewPane = SizedBox(
      width: 240,
      child: Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: surf(context),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (poster.isNotEmpty)
              Image.network(poster, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      Container(color: Colors.grey.shade900))
            else
              Container(color: Colors.grey.shade900),
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(10),
                color: Colors.black.withValues(alpha: 0.75),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(preview['title']?.toString() ?? '',
                        maxLines: 2,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    if (preview['year'] != null)
                      Text(preview['year'].toString(),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return SizedBox(
      height: 350,
      child: Row(
        children: mode == 0 ? [listPane, previewPane] : [previewPane, listPane],
      ),
    );
  }

  double _viewCardWidth() {
    switch (appSettings.viewMode) {
      case 1: return 140;
      case 2: case 9: return 240;
      case 4: return 190;
      case 6: return 180;
      case 7: return 140;
      case 10: return 110;
      case 11: return 70;
      case 12: return 100;
      case 13: return 90;
      case 14: return 160;
      default: return 120;
    }
  }

  double _viewPosterHeight() {
    switch (appSettings.viewMode) {
      case 1: return 110;
      case 2: case 9: return 135;
      case 3: return 150;
      case 4: return 250;
      case 5: return 90;
      case 6: return 240;
      case 7: return 170;
      case 11: return 70;
      case 12: return 150;
      case 13: return 130;
      case 14: return 220;
      default: return 160;
    }
  }

  bool _viewWide() => [1, 2, 9].contains(appSettings.viewMode);
  bool _viewMinimal() => [5, 11].contains(appSettings.viewMode);
  double _viewRowHeight() => _viewPosterHeight() + 46;

  Widget _homeItemCard(Map<String, dynamic> it, {bool autofocus = false}) {
    final backdrop = it['backdrop_url']?.toString() ?? '';
    final poster = _viewWide() && backdrop.isNotEmpty
        ? backdrop
        : it['poster_url']?.toString() ?? '';
    final label = it['title']?.toString() ?? '';
    final avail = _availableBadge(it);
    final cardWidth = _viewCardWidth();
    final posterHeight = _viewPosterHeight();
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
          width: cardWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    SizedBox(
                      height: posterHeight,
                      width: cardWidth,
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
                        right: avail ? 26 : 4,
                        top: 4,
                        child: Icon(Icons.favorite, color: accent(context), size: 18),
                      ),
                    if (avail)
                      const Positioned(
                        right: 4,
                        top: 4,
                        child: Icon(Icons.verified, color: Colors.green, size: 17),
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
              if (!_viewMinimal()) ...[
                const SizedBox(height: 4),
                SizedBox(
                  height: Platform.isAndroid ? 34 : 28,
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: Platform.isAndroid ? 9 : 11),
                  ),
                ),
                if (it['rating'] != null)
                  SizedBox(
                    height: Platform.isAndroid ? 16 : 14,
                    child: Text(
                      '★ ${it['rating']}',
                      style: TextStyle(
                        fontSize: Platform.isAndroid ? 9 : 10,
                        color: Colors.amber,
                      ),
                    ),
                  ),
              ],
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
                    final queue = _sourceFollowingEpisodes(ep);
                    if (queue.isNotEmpty) {
                      _playEpisodes(queue);
                      return;
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
    final items = _availabilityFiltered(_langFiltered(prefs.favoriteList()));
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
        if (!_langOk(i)) return false;
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
      final items = _availabilityFiltered(
          _langFiltered((section['items'] as List?) ?? []));
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
        final allItems = _availabilityFiltered(_fullSections[title] ?? items);
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
          child: _buildCoverRow(
            items.map((i) => (i as Map).cast<String, dynamic>()).toList(),
            section: title,
          ),
        ));
      }
    }
    return list;
  }

  void _selectViewMode(int index) async {
    setState(() => appSettings.viewMode = index);
    await appSettings.save();
  }

  Widget _viewPanel() {
    return Container(
      width: 220,
      color: surf(context).withValues(alpha: 0.96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'ANSICHT AUSWÄHLEN',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                      color: Colors.white70,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Schließen',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => showViewPanel = false),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: flixamViewModes.length,
              itemBuilder: (ctx, i) {
                final selected = appSettings.viewMode == i;
                return ListTile(
                  dense: true,
                  selected: selected,
                  selectedTileColor: accent(context).withValues(alpha: 0.18),
                  title: Text(
                    flixamViewModes[i],
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? accent(context) : Colors.white70,
                    ),
                  ),
                  onTap: () => _selectViewMode(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  bool get _noSpecialView =>
      !showFavorites &&
      !showSourceEpisodes &&
      !showProviderNew &&
      !showNewSeries &&
      !showAddonCatalog &&
      !showLiveTv &&
      !showDownloads;

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
                  tooltip: 'Ansicht auswählen',
                  icon: const Icon(Icons.view_agenda_outlined, size: 18),
                  color: Colors.white70,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () =>
                      setState(() => showViewPanel = !showViewPanel),
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
              active: showHome && _noSpecialView, onTap: _goHome),
          _aetherNavItem(Icons.search, 'Suche',
              active: false, onTap: () => _search()),
          _aetherNavItem(Icons.movie_outlined, 'Filme',
              active: !showHome && _noSpecialView,
              onTap: _browseRoot),
          if (!Platform.isAndroid)
            _aetherNavItem(Icons.download_for_offline_outlined, 'Downloads',
                active: showDownloads, onTap: _toggleDownloads),
          _aetherNavItem(Icons.live_tv, 'Live TV',
              active: showLiveTv, onTap: _toggleLiveTv),
          _aetherNavItem(Icons.storage, 'Addon-Bestand',
              active: showAddonCatalog, onTap: _toggleAddonCatalog),
          _aetherNavItem(Icons.new_releases, 'Neu bei Anbietern',
              active: showProviderNew, onTap: _toggleProviderNew),
          _aetherNavItem(Icons.tv_outlined, 'Neue Serien',
              active: showNewSeries, onTap: _toggleNewSeries),
          _aetherNavItem(Icons.favorite_border, 'Favoriten', active: showFavorites,
              onTap: () => setState(() {
                    _activateView(showFavorites ? 'home' : 'favorites');
                  })),
          if (!Platform.isAndroid)
            _aetherNavItem(Icons.file_download_outlined, 'Import',
                active: false, onTap: _importConf),
          _aetherNavItem(Icons.settings_outlined, 'Einstellungen',
              active: false, onTap: _showSettings),
          const Spacer(),
          if (!Platform.isAndroid && downloadItems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: InkWell(
                onTap: _toggleDownloads,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.download, size: 13, color: accent(context)),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${downloadItems.length} Download(s)',
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: downloadItems
                              .where((d) =>
                                  (d['status']?.toString() ?? '') == 'running')
                              .isEmpty
                          ? 1.0
                          : downloadItems
                                  .where((d) =>
                                      (d['status']?.toString() ?? '') ==
                                      'running')
                                  .map((d) =>
                                      (d['progress'] as num?)?.toDouble() ?? 0)
                                  .reduce((a, b) => a + b) /
                              downloadItems
                                  .where((d) =>
                                      (d['status']?.toString() ?? '') ==
                                      'running')
                                  .length,
                      minHeight: 3,
                      color: accent(context),
                      backgroundColor: Colors.white12,
                    ),
                  ],
                ),
              ),
            ),
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
                      onPressed: () => _activateView(
                        showFavorites ? 'home' : 'favorites',
                      ),
                    ),
                  ],
                ),
              )
              ],
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
              if (showDownloads) ..._buildDownloadsSlivers(),
              if (showLiveTv) ..._buildLiveTvSlivers(),
              if (showAddonCatalog) ..._buildAddonCatalogSlivers(),
              if (showNewSeries) ..._buildNewSeriesSlivers(),
              if (showProviderNew) ..._buildProviderNewSlivers(),
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
                  Padding(
                    padding: EdgeInsets.only(
                      right: showViewPanel ? 220 : 0,
                    ),
                    child: _buildContentScroller(),
                  ),
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
            Padding(
              padding: EdgeInsets.only(right: showViewPanel ? 220 : 0),
              child: _buildContentScroller(),
            ),
          if (showViewPanel && !showPlayer)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: _viewPanel(),
            ),
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
                          if (playerFromLive)
                            SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                                _switchLiveChannel(-1),
                          if (playerFromLive)
                            SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                                _switchLiveChannel(1),
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
                                if (_episodeQueue.isNotEmpty &&
                                    _episodeIndex < _episodeQueue.length)
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: _playNextEpisode,
                                    icon: const Icon(Icons.skip_next, size: 18),
                                    label: const Text('Nächste Folge'),
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
                                    if (playerFromLive) ...[
                                      IconButton(
                                        tooltip: 'Vorheriger Sender',
                                        onPressed: () => _switchLiveChannel(-1),
                                        icon: const Icon(Icons.skip_previous),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    IconButton(
                                      tooltip: 'Zurück 10 s',
                                      onPressed: () => player.seek(
                                          player.state.position - const Duration(seconds: 10)),
                                      icon: const Icon(Icons.replay_10),
                                    ),
                                    IconButton(
                                      tooltip: 'Play/Pause',
                                      onPressed: () => player.playOrPause(),
                                      icon: const Icon(Icons.play_arrow),
                                    ),
                                    IconButton(
                                      tooltip: 'Vor 10 s',
                                      onPressed: () => player.seek(
                                          player.state.position + const Duration(seconds: 10)),
                                      icon: const Icon(Icons.forward_10),
                                    ),
                                    if (playerFromLive) ...[
                                      const SizedBox(width: 6),
                                      IconButton(
                                        tooltip: 'Nächster Sender',
                                        onPressed: () => _switchLiveChannel(1),
                                        icon: const Icon(Icons.skip_next),
                                      ),
                                    ],
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
