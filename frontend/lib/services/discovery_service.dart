import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Findet das Flixam-Backend im LAN per UDP-Broadcast (Fire TV).
class BackendDiscovery {
  static const int port = 9000;
  static const String magic = 'FLIXAM_DISCOVER';
  static const String prefix = 'FLIXAM_BACKEND ';

  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    RawDatagramSocket? socket;
    Timer? timeoutTimer;
    Timer? retryTimer;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final completer = Completer<String?>();

      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final message = utf8.decode(datagram.data, allowMalformed: true);
        if (message.startsWith(prefix) && !completer.isCompleted) {
          completer.complete(message.substring(prefix.length).trim());
        }
      });

      void send() {
        try {
          socket?.send(utf8.encode(magic), InternetAddress('255.255.255.255'), port);
        } catch (_) {}
      }

      send();
      retryTimer = Timer(const Duration(milliseconds: 500), send);

      final result = await completer.future;
      timeoutTimer.cancel();
      retryTimer.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      timeoutTimer?.cancel();
      retryTimer?.cancel();
      socket?.close();
    }
  }
}
