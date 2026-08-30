# Transport Layer

## Purpose
Owns the raw connection: open, send/receive **string** frames, auto-reconnect
with a retry policy, pause/resume for the app lifecycle, and optional
keepalive that detects half-dead sockets. Knows nothing about JSON, requests,
or the relay protocol — those live in the Protocol layer
(docs/09-refactoring-plan.md §2.1).

## Dependencies
- `dart:async` (Stream, Future, Timer)
- `flutter/foundation` (ValueNotifier)
- `web_socket_channel` (WebSocket implementation)
- `core/connection/retry_policy.dart` (reconnect delay schedule)

## API
```dart
enum ConnectionStatus { disconnected, connecting, connected }

abstract class Transport {
  Stream<String> get messages;
  ValueNotifier<ConnectionStatus> get status;
  String? get lastError;

  Future<void> connect(Uri uri);
  void send(String data);
  void pause();
  void resume();
  Future<void> close();
}
```

## Usage
```dart
final transport = WebSocketTransport();               // keepalive on (20 s)
await transport.connect(Uri.parse('ws://host:8375/ws'));
transport.messages.listen((msg) => print('Got: $msg'));
transport.send('{"type":"ping"}');
```

## Testing
- `test/fakes/fake_web_socket_channel.dart` — a controllable
  `WebSocketChannel` (no network): drive inbound frames with
  `simulateMessage/simulateError/simulateDone`, inspect outbound via `sent`.
- `test/core/transport/websocket_transport_test.dart` — status transitions,
  send/receive, reconnect with backoff, pause/resume, keepalive.
- `test/core/transport/http_health_test.dart` — against a real loopback
  `HttpServer` (dart:io).

```dart
final channel = FakeWebSocketChannel();
final t = WebSocketTransport(channelFactory: (_) => channel);
await t.connect(uri);
channel.simulateMessage('hello');
expect(await t.messages.first, 'hello');
```
