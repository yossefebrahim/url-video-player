import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_theme.dart';
import '../models/video_item.dart';

/// Full-screen WebView player for links whose deep-link host resolved to the
/// "web" mode (or non play/web hosts). Mirrors the original app's WebPlayer.
class WebPlayerScreen extends StatefulWidget {
  final VideoItem item;
  const WebPlayerScreen({super.key, required this.item});

  @override
  State<WebPlayerScreen> createState() => _WebPlayerScreenState();
}

class _WebPlayerScreenState extends State<WebPlayerScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      );
    _load();
  }

  /// Applies the custom user agent (if any) *before* loading, so the request
  /// carries it — setUserAgent and loadRequest are async and must be ordered.
  Future<void> _load() async {
    final ua = widget.item.userAgent;
    if (ua != null && ua.isNotEmpty) {
      await _controller.setUserAgent(ua);
    }
    await _controller.loadRequest(Uri.parse(widget.item.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppTheme.primaryRed,
        title: Text(
          widget.item.title.isEmpty ? 'Web Player' : widget.item.title,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
        ],
      ),
    );
  }
}
