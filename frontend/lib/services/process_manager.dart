import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ProcessManager {
  static final ProcessManager instance = ProcessManager._();
  ProcessManager._();

  Process? _uvicorn;
  Process? _wireproxy;
  final ValueNotifier<String> status = ValueNotifier('Backend startet');

  Future<void> startAll({String baseUrl = 'http://127.0.0.1:8000'}) async {
    // Fire TV / Android: kein lokales Python-Backend starten - die App
    // verbindet sich mit einem Backend im LAN (siehe Einstellungen).
    if (Platform.isAndroid) {
      status.value = 'Verbinde mit $baseUrl';
      return;
    }
    status.value = 'Starte Backend…';
    final backendHost = Platform.environment['FLIXAM_BACKEND_HOST'] ?? '127.0.0.1';
    _uvicorn = await Process.start(
      '/home/joerg/flixam_player/backend/venv/bin/uvicorn',
      ['server:app', '--host', backendHost, '--port', '8000'],
      workingDirectory: '/home/joerg/flixam_player/backend',
    );
    _uvicorn!.stdout.transform(utf8.decoder).listen((d) => debugPrint('[uvicorn] $d'));
    _uvicorn!.stderr.transform(utf8.decoder).listen((d) => debugPrint('[uvicorn] $d'));

    bool ready = false;
    for (int i = 0; i < 20; i++) {
      try {
        final r = await http.get(Uri.parse('http://127.0.0.1:8000/vpn/status')).timeout(const Duration(milliseconds: 300));
        if (r.statusCode == 200) {
          ready = true;
          break;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (!ready) {
      status.value = 'Backend nicht erreichbar';
      return;
    }
    status.value = 'Backend bereit';
  }

  Future<void> startWireproxy() async {
    if (Platform.isAndroid) return;
    final conf = File('/home/joerg/flixam_player/vpn/wg0.conf');
    if (File('/home/joerg/flixam_player/vpn/wireproxy').existsSync() && conf.existsSync()) {
      _wireproxy = await Process.start(
        '/home/joerg/flixam_player/vpn/wireproxy',
        ['-c', '/home/joerg/flixam_player/vpn/wg0.conf'],
        workingDirectory: '/home/joerg/flixam_player/vpn',
      );
      _wireproxy!.stdout.transform(utf8.decoder).listen((d) => debugPrint('[wireproxy] $d'));
      _wireproxy!.stderr.transform(utf8.decoder).listen((d) => debugPrint('[wireproxy] $d'));
    }
  }

  Future<void> stopWireproxy() async {
    _wireproxy?.kill();
    _wireproxy = null;
  }

  Future<void> restartWireproxy() async {
    await stopWireproxy();
    await startWireproxy();
  }

  Future<void> stopAll() async {
    _wireproxy?.kill();
    _uvicorn?.kill();
    _wireproxy = null;
    _uvicorn = null;
  }
}
