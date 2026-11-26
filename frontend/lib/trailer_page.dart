import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Vollbild-WebView für YouTube-Trailer (TMDB Trailers).
class TrailerPage extends StatelessWidget {
  final String videoKey;
  final String title;

  const TrailerPage({super.key, required this.videoKey, required this.title});

  @override
  Widget build(BuildContext context) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..loadRequest(
        Uri.parse(
          'https://www.youtube.com/embed/$videoKey?autoplay=1&rel=0',
        ),
      );
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('Trailer: $title', style: const TextStyle(fontSize: 15)),
      ),
      body: WebViewWidget(controller: controller),
    );
  }
}
