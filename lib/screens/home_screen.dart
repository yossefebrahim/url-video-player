import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class _HomeScreenState extends State<HomeScreen> {
  // Reused by the "Add URL" bottom sheet each time it opens.
  final _titleCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _uaCtrl = TextEditingController();

  final _db = HistoryDatabase.instance;

  VideoItem? _current;
  List<VideoItem> _history = const [];
  List<VideoItem> _favorites = const [];
  int _contentIndex = 0; // 0 = History, 1 = Favorites
  StreamSubscription<ParsedLink>? _sub;

  /// Kept current by the local player; read when starting a Cast hand-off.
  final _localPosition = ValueNotifier<Duration>(Duration.zero);

  @override
  void initState() {
    super.initState();
    _reload();
    _initDeepLinks();
    CastService.instance.passiveDisconnects
        .addListener(_onPassiveCastDisconnect);
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

  void _onPassiveCastDisconnect() {
    if (mounted) _snack('Cast disconnected.');
  }

  /// A deep link / shared URL: persist to history, and play it if it was an
  /// explicit hand-off. A non-autoplay shared link simply lands in history
  /// (frame-safe — no bottom sheet at cold start).
  void _handleLink(ParsedLink link) {
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

  // ── Add-URL bottom sheet ──────────────────────────────────────────────────

  Future<void> _openAddUrlSheet([VideoItem? prefill]) async {
    if (prefill != null) {
      _titleCtrl.text = prefill.title;
      _urlCtrl.text = prefill.url;
      _uaCtrl.text = prefill.userAgent ?? '';
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: _buildAddUrlSheet,
    );
  }

  Widget _buildAddUrlSheet(BuildContext sheetContext) {
    final text = Theme.of(sheetContext).textTheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add a video URL', style: text.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _titleCtrl,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                hintText: 'Video Title (optional)',
                prefixIcon: Icon(Icons.title),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autofocus: _urlCtrl.text.isEmpty,
              onSubmitted: (_) => _submitFromSheet(sheetContext),
              decoration: InputDecoration(
                hintText: 'Video URL',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _pasteUrl,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Theme(
              data: Theme.of(sheetContext)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: const Text('Advanced'),
                children: [
                  TextField(
                    controller: _uaCtrl,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submitFromSheet(sheetContext),
                    decoration: const InputDecoration(
                      hintText: 'User Agent (optional)',
                      prefixIcon: Icon(Icons.public),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _submitFromSheet(sheetContext),
              icon: const Icon(Icons.play_arrow_rounded, size: 26),
              label: const Text('PLAY'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t != null && t.isNotEmpty) _urlCtrl.text = t;
  }

  Future<void> _submitFromSheet(BuildContext sheetContext) async {
    final ok = await _submitAddUrl();
    if (ok && sheetContext.mounted) Navigator.of(sheetContext).pop();
  }

  Future<bool> _submitAddUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _snack('Please enter a video URL');
      return false;
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
    _titleCtrl.clear();
    _urlCtrl.clear();
    _uaCtrl.clear();
    return true;
  }

  // ── list actions ──────────────────────────────────────────────────────────

  Future<void> _toggleFavorite(VideoItem item) async {
    await _db.setFavorite(item.url, !item.favorite);
    await _reload();
  }

  Future<void> _delete(VideoItem item) async {
    await _db.deleteByUrl(item.url);
    await _reload();
    if (!mounted) return;
    final name = item.title.isEmpty ? 'video' : item.title;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted “$name”'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              // Identity is the URL — upsert restores favorite + metadata.
              await _db.upsert(item);
              await _reload();
            },
          ),
        ),
      );
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text('This removes your watch history. '
            'Your favorites are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _db.clearHistory();
      await _reload();
      if (mounted) _snack('History cleared');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    CastService.instance.passiveDisconnects
        .removeListener(_onPassiveCastDisconnect);
    _sub?.cancel();
    _titleCtrl.dispose();
    _urlCtrl.dispose();
    _uaCtrl.dispose();
    _localPosition.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

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
            tooltip: 'More options',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              switch (value) {
                case 'privacy':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PrivacyPolicyScreen()));
                  break;
                case 'clear':
                  await _confirmClearHistory();
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddUrlSheet(),
        icon: const Icon(Icons.add_link),
        label: const Text('Add URL'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _playerStage(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        label: Text('History'),
                        icon: Icon(Icons.history)),
                    ButtonSegment(
                        value: 1,
                        label: Text('Favorites'),
                        icon: Icon(Icons.favorite_outline)),
                  ],
                  selected: {_contentIndex},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => _contentIndex = s.first),
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _contentIndex,
                children: [
                  _listTab(_history, 'No history yet',
                      'Videos you open will appear here.'),
                  _listTab(_favorites, 'No favorites yet',
                      'Tap the heart on any video to save it.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playerStage() {
    return ValueListenableBuilder<CastState>(
      valueListenable: CastService.instance.state,
      builder: (context, castState, _) {
        final Widget child;
        if (castState.isConnected) {
          // A cast session is forming or active — the local player MUST be fully
          // torn down. Gating on isConnected (not just isCasting) means the
          // local better_player is disposed the instant we start connecting, so
          // it can't keep decoding audio in the background ("two videos").
          child = castState.isCasting
              ? CastMiniController(
                  key: const ValueKey('cast'),
                  item: _current,
                  deviceName: castState.deviceName,
                )
              : _castConnecting(castState.deviceName);
        } else if (_current == null) {
          child = _idlePoster();
        } else {
          child = VideoPlayerView(
            key: ValueKey(_current!.url),
            item: _current!,
            positionSink: _localPosition,
            onEdit: () => _openAddUrlSheet(_current),
            onInitialized: (d, s) => _onPlayerInitialized(_current!.url, d, s),
          );
        }
        // NO AnimatedSwitcher: swapping the player must unmount + dispose the
        // outgoing controller in the SAME frame. A cross-fade keeps the old
        // VideoPlayerView mounted during the transition, and with
        // autoDispose:false an interrupted transition orphans a better_player
        // that keeps playing audio behind the new one (double playback).
        return Container(
          width: double.infinity,
          color: Colors.black,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: child,
          ),
        );
      },
    );
  }

  Widget _castConnecting(String? device) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 30,
            width: 30,
            child: CircularProgressIndicator(
                strokeWidth: 3, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Text(
            'Connecting to ${device ?? 'your TV'}…',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _idlePoster() {
    return Center(
      key: const ValueKey('idle'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_circle_outline,
              color: Colors.white38, size: 48),
          const SizedBox(height: 8),
          const Text(
            'No video playing',
            style:
                TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          TextButton.icon(
            onPressed: () => _openAddUrlSheet(),
            icon: const Icon(Icons.add_link, color: Colors.white),
            label:
                const Text('Add a URL', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _listTab(List<VideoItem> items, String emptyTitle, String emptyBody) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [_emptyState(emptyTitle, emptyBody)],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 4, bottom: 96),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final item = items[i];
                return HistoryTile(
                  item: item,
                  onPlay: () => _play(item),
                  onToggleFavorite: () => _toggleFavorite(item),
                  onDelete: () => _delete(item),
                );
              },
            ),
    );
  }

  Widget _emptyState(String title, String body) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      child: Column(
        children: [
          Icon(Icons.video_library_outlined,
              size: 54, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title,
              style: text.titleMedium?.copyWith(color: scheme.onSurface)),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => _openAddUrlSheet(),
            icon: const Icon(Icons.add_link),
            label: const Text('Add a URL'),
          ),
        ],
      ),
    );
  }
}
