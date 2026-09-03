import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Production channel factory for VM/mobile/desktop: forwards [headers] on the
/// WebSocket handshake (dart:io `WebSocket.connect` supports them), so the
/// relay can authenticate via `Authorization: Bearer` instead of a token in
/// the URL. Selected via conditional import in [WebSocketTransport].
WebSocketChannel connectWithHeaders(Uri uri, Map<String, dynamic> headers) =>
    IOWebSocketChannel.connect(uri, headers: headers);