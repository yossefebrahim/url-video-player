import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/video_item.dart';
import '../services/cast_service.dart';
import '../services/deep_link_service.dart';
import '../services/history_database.dart';
import '../services/link_parser.dart';
import '../services/metadata_service.dart';
import '../widgets/cast_button.dart';
import '../widgets/cast_mini_controller.dart';
import '../widgets/history_tile.dart';
import '../widgets/video_player_view.dart';
import 'privacy_policy_screen.dart';
import 'web_player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _titleCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _uaCtrl = TextEditingController();

  late final TabController _tab;
  final _db = HistoryDatabase.instance;

  VideoItem? _current;
  List<VideoItem> _history = const [];
  List<VideoItem> _favorites = const [];
  StreamSubscription<ParsedLink>? _sub;

  /// Kept current by the local player; read when starting a Cast hand-off.
  final _localPosition = ValueNotifier<Duration>(Duration.zero);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _reload();
    _initDeepLinks();
  }

  Future<void> _initDeepLinks() async {
    try {
      final initial = await DeepLinkService.instance.getInitialLink();
      if (initial != null && mounted) _handleLink(initial);
    } catch (e, s) {
      debugPrint('HomeScreen._initDeepLinks failed: $e');
      debugPrintStack(stackTrace: s);
    }
    _sub = DeepLinkService.instance.linkStream.listen(_handleLink);
  }

  /// Populates the form with [item] and switches to the PLAYER tab.
  void _selectItem(VideoItem item) {
    _titleCtrl.text = item.title;
    _urlCtrl.text = item.url;
    _uaCtrl.text = item.userAgent ?? '';
    _tab.animateTo(0);
  }

  void _handleLink(ParsedLink link) {
    _selectItem(link.item);
    _openItem(link.item, autoPlay: link.autoPlay);
  }

  Future<void> _reload() async {
    final h = await _db.getHistory();
    final f = await _db.getFavorites();
    if (mounted) {
      setState(() {
        _history = h;
        _favorites = f;
      });
    }
  }

  Future<void> _openItem(VideoItem item, {required bool autoPlay}) async {
    try {
      final saved = await _db.upsert(item);
      await _reload();
      if (!mounted) return;
      if (autoPlay) _play(saved);
    } catch (e, s) {
      debugPrint('HomeScreen._openItem failed: $e');
      debugPrintStack(stackTrace: s);
    }
  }

  void _play(VideoItem item) {
    if (!mounted) return;
    if (item.mode == PlayerMode.web) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => WebPlayerScreen(item: item)),
      );
      return;
    }
    setState(() => _current = item);
    _enrichThumbnail(item);
  }

  Future<void> _enrichThumbnail(VideoItem item) async {
    if (item.thumbnailPath != null) return;
    final path = await MetadataService.instance
        .generateThumbnail(item.url, userAgent: item.userAgent);
    if (path != null) {
      await _db.updateMetadata(item.url, thumbnailPath: path);
      await _reload();
    }
  }

  void _onPlayerInitialized(String url, Duration duration, Size size) {
    _db.updateMetadata(
      url,
      durationMs: duration.inMilliseconds,
      width: size.width.toInt(),
      height: size.height.toInt(),
    );
    _reload();
  }

  Future<void> _saveAndPlay() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _snack('Please enter a video URL');
      return;
    }
    final title = _titleCtrl.text.trim();
    final ua = _uaCtrl.text.trim();
    final item = VideoItem(
      title: title.isEmpty ? LinkParser.titleFromUrl(url) : title,
      url: url,
      userAgent: ua.isEmpty ? null : ua,
      mode: PlayerMode.native,
      source: VideoSource.manual,
    );
    FocusScope.of(context).unfocus();
    await _openItem(item, autoPlay: true);
  }

  Future<void> _toggleFavorite(VideoItem item) async {
    await _db.setFavorite(item.url, !item.favorite);
    await _reload();
  }

  Future<void> _delete(VideoItem item) async {
    await _db.deleteByUrl(item.url);
    await _reload();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tab.dispose();
    _titleCtrl.dispose();
    _urlCtrl.dispose();
    _uaCtrl.dispose();
    _localPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Url Video Player'),
        actions: [
          CastButton(
            current: _current,
            localPosition: () => _localPosition.value,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              switch (value) {
                case 'privacy':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PrivacyPolicyScreen()));
                  break;
                case 'clear':
                  await _db.clearHistory();
                  await _reload();
                  _snack('History cleared');
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'privacy', child: Text('Privacy Policy')),
              PopupMenuItem(value: 'clear', child: Text('Clear History')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final playerHeight =
                (constraints.maxHeight * 0.32).clamp(150.0, 260.0);
            return Column(
              children: [
                _statusPill(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: SizedBox(
                    height: playerHeight,
                    width: double.infinity,
                    child: _playerBox(),
                  ),
                ),
                Expanded(child: _sheet()),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _statusPill() {
    final playing = _current != null;
    final quality = _current?.resolutionLabel ?? 'HD Quality';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.circle,
                size: 10,
                color: playing ? AppTheme.online : Colors.white),
            const SizedBox(width: 8),
            Text(
              playing ? 'Playing' : 'Ready to Play',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(quality,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _playerBox() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        color: Colors.black,
        child: ValueListenableBuilder<CastState>(
          valueListenable: CastService.instance.state,
          builder: (context, castState, _) {
            // While casting, the receiver owns playback — show remote controls
            // in place of the local player (which is torn down to avoid double
            // audio).
            if (castState.isCasting) {
              return CastMiniController(
                item: _current,
                deviceName: castState.deviceName,
              );
            }
            if (_current == null) {
              return Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'ADD OR SELECT VIDEO TO PLAY',
                    style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5),
                  ),
                ),
              );
            }
            return VideoPlayerView(
              key: ValueKey(_current!.url),
              item: _current!,
              positionSink: _localPosition,
              onInitialized: (d, s) =>
                  _onPlayerInitialized(_current!.url, d, s),
            );
          },
        ),
      ),
    );
  }

  Widget _sheet() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F3F3),
              borderRadius: BorderRadius.circular(14),
            ),
            child: TabBar(
              controller: _tab,
              indicator: BoxDecoration(
                color: AppTheme.tabTint,
                borderRadius: BorderRadius.circular(14),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: AppTheme.primaryRed,
              unselectedLabelColor: Colors.black54,
              labelStyle: const TextStyle(
                  fontWeight: FontWeight.w700, letterSpacing: 0.4),
              tabs: const [
                Tab(text: 'PLAYER'),
                Tab(text: 'HISTORY'),
                Tab(text: 'FAVORITES'),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _playerTab(),
                _listTab(_history, 'No history yet',
                    'Videos you open will appear here.'),
                _listTab(_favorites, 'No favorites yet',
                    'Tap the heart on any video to save it.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _playerTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        children: [
          TextField(
            controller: _titleCtrl,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              hintText: 'Video Title',
              prefixIcon:
                  Icon(Icons.title, color: AppTheme.primaryRed),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              hintText: 'Video URL',
              prefixIcon: Icon(Icons.link, color: AppTheme.primaryRed),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _uaCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: 'User Agent (Optional)',
              prefixIcon: Icon(Icons.public, color: AppTheme.primaryRed),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _saveAndPlay,
            icon: const Icon(Icons.play_arrow_rounded, size: 26),
            label: const Text('SAVE AND PLAY'),
          ),
        ],
      ),
    );
  }

  Widget _listTab(List<VideoItem> items, String emptyTitle, String emptyBody) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.video_library_outlined,
                  size: 54, color: Colors.black26),
              const SizedBox(height: 12),
              Text(emptyTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: Colors.black54)),
              const SizedBox(height: 6),
              Text(emptyBody,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.black38, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        return HistoryTile(
          item: item,
          onPlay: () {
            _selectItem(item);
            _play(item);
          },
          onToggleFavorite: () => _toggleFavorite(item),
          onDelete: () => _delete(item),
        );
      },
    );
  }
}
