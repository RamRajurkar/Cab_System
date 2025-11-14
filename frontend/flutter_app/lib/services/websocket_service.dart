import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config/api_config.dart';

typedef WsCallback = void Function(Map<String, dynamic>);

class WebSocketService {
  static final WebSocketService _singleton = WebSocketService._internal();
  factory WebSocketService() => _singleton;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  final List<WsCallback> _listeners = [];
  bool _isConnecting = false;

  Future<void> connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    try {
      final url = ApiConfig.wsUrl;
      _channel = WebSocketChannel.connect(Uri.parse(url));
      print("🟢 WS Connected");

      _channel!.stream.listen(
        (event) {
          final decoded = json.decode(event);
          for (var cb in _listeners) cb(decoded);
        },
        onDone: () {
          print("🔴 WS closed");
          _reconnect();
        },
        onError: (e) {
          print("❌ WS Error: $e");
          _reconnect();
        },
      );
    } catch (e) {
      print("WS Connect error: $e");
      _reconnect();
    }

    _isConnecting = false;
  }

  void _reconnect() {
    Future.delayed(const Duration(seconds: 2), connect);
  }

  void addListener(WsCallback cb) => _listeners.add(cb);
  void removeListener(WsCallback cb) => _listeners.remove(cb);
}
