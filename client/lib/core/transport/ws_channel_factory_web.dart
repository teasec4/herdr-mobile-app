import 'package:web_socket_channel/web_socket_channel.dart';

/// Browser fallback for the production channel factory (selected via
/// conditional import on web targets). The browser WebSocket API cannot set
/// HTTP headers, so [headers] is dropped here; the relay keeps accepting
/// `?token=` for web-compatible clients. This app's web target is scaffold
/// only — mobile/desktop use [WebSocketTransport] with token auth.
WebSocketChannel connectWithHeaders(Uri uri, Map<String, dynamic> headers) =>
    WebSocketChannel.connect(uri);