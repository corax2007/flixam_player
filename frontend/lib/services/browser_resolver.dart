import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Löst Hoster-Token im Browser-Kontext auf (Cloudflare blockt Dart-HTTP).
class BrowserResolver {
  static final BrowserResolver instance = BrowserResolver._();

  /// Master-Playlist durch die erste Variante ersetzen (stabiler in mpv).
  static Future<String> flattenMaster(
    String url,
    Map<String, String> headers,
  ) async {
    if (!url.contains('.m3u8')) return url;
    try {
      final r = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || !r.body.contains('#EXT-X-STREAM-INF')) {
        return url;
      }
      final lines = r.body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))
          .toList();
      if (lines.isEmpty) return url;
      return Uri.parse(url).resolve(lines.first).toString();
    } catch (_) {
      return url;
    }
  }

  static const String _channel = 'FlixamToken';
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 5.1.1; AFTT Build/LVY48F) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  late final WebViewController _controller;
  bool _initialized = false;

  BrowserResolver._();

  void init() {
    if (_initialized) return;
    _initialized = true;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..addJavaScriptChannel(
        _channel,
        onMessageReceived: (message) {
          if (!_result.isCompleted) _result.complete(message.message);
        },
      );
  }

  Completer<String> _result = Completer<String>();

  /// Unsichtbare WebView, die in der App eingehängt wird.
  Widget get hiddenView => const SizedBox(width: 1, height: 1);

  Widget buildHiddenView() {
    init();
    return SizedBox(
      width: 1,
      height: 1,
      child: WebViewWidget(controller: _controller),
    );
  }

  Future<String?> resolveGeneric(String url) async {
    if (!Platform.isAndroid) return null;
    init();
    _result = Completer<String>();
    final loaded = Completer<void>();
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onSslAuthError: (error) => error.proceed(),
        onPageFinished: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
      ),
    );
    await _controller.loadRequest(Uri.parse(url));
    await loaded.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    await Future.delayed(const Duration(milliseconds: 800));
    const js = '''
(function () {
  var html = document.documentElement.outerHTML;
  var res = [/["]?(https?:\\/\\/[^"'\\s<>]+?\\.m3u8[^"'\\s<>]*)["']?/,
             /["]?(https?:\\/\\/[^"'\\s<>]+?\\.mp4[^"'\\s<>]*)["']?/];
  for (var i = 0; i < res.length; i++) {
    var m = html.match(res[i]);
    if (m) { FlixamToken.postMessage(m[1]); return; }
  }
  var f = document.querySelector('iframe');
  if (f && f.src) { FlixamToken.postMessage('IFRAME:' + f.src); return; }
  FlixamToken.postMessage('');
})();
''';
    await _controller.runJavaScript(js);
    try {
      final value = await _result.future.timeout(const Duration(seconds: 15));
      if (value.startsWith('IFRAME:')) {
        return resolveGeneric(value.substring(7));
      }
      if (value.isEmpty) return null;
      final host = Uri.parse(url).host;
      final flat = await flattenMaster(value, {
        'User-Agent': _ua,
        'Referer': 'https://$host/',
      });
      return '$flat|Referer=https://$host/';
    } catch (_) {
      return null;
    }
  }

  Future<String?> resolve({required String eUrl, required String referer}) async {
    if (!Platform.isAndroid) return null;
    init();
    _result = Completer<String>();

    final loaded = Completer<void>();
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onSslAuthError: (error) => error.proceed(),
        onPageFinished: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
      ),
    );
    await _controller.loadRequest(
      Uri.parse(eUrl),
      headers: {'Referer': referer},
    );
    await loaded.future.timeout(const Duration(seconds: 25), onTimeout: () {});
    await Future.delayed(const Duration(milliseconds: 800));

    // ES5-kompatibles JS (auch alte Android-WebView kann das).
    const js = '''
(function () {
  var html = document.documentElement.outerHTML;
  var m = html.match(/dsplayer\\.hotkeys[^']+'([^']+)[\\s\\S]+?function\\s*makePlay[\\s\\S]+?return[^?]+([^"]+)/);
  if (!m) { FlixamToken.postMessage(''); return; }
  var path = m[1];
  var token = m[2];
  var xhr = new XMLHttpRequest();
  xhr.open('GET', path, true);
  xhr.onreadystatechange = function () {
    if (xhr.readyState !== 4) return;
    var body = (xhr.responseText || '').replace(/^\\s+|\\s+\$/g, '');
    if (body.indexOf('http') !== 0) { FlixamToken.postMessage(''); return; }
    var chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    var rand = '';
    for (var i = 0; i < 10; i++) rand += chars.charAt(Math.floor(Math.random() * chars.length));
    FlixamToken.postMessage(body + rand + token + Date.now());
  };
  xhr.send();
})();
''';
    await _controller.runJavaScript(js);
    try {
      final value = await _result.future.timeout(const Duration(seconds: 20));
      if (value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }
}
