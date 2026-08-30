# Protocol Layer

## Purpose
The relay wire protocol: JSON ⇄ typed frames, request-response matching,
timeouts, fail-on-disconnect, and automatic ping/pong. Independent of any
transport — the same code works over WebSocket now and over HTTP/gRPC later
(docs/09-refactoring-plan.md §2.2).

## Dependencies
- `dart:async` (Completer, Timer, StreamSubscription)
- `core/transport/transport.dart` (Transport interface)

## API
```dart
sealed class Frame {
  factory Frame.parse(String json);   // throws ProtocolException on garbage
  String encode();
}
// RequestFrame{id, method, params} · ResponseFrame{id, ok, result?, error?}
// EventFrame{event, data?} · PingFrame · PongFrame

class RequestResponseManager {
  RequestResponseManager(Transport t, {Duration requestTimeout = 15s,
                                       Duration connectWait = 8s});
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params);
  void dispose();
}
```

## Usage
```dart
final rpc = RequestResponseManager(transport);
final result = await rpc.request('agents.snapshot', {});
final agents = (result['agents'] as List?)?.map(RelayAgent.fromJson) ?? [];
```

## Testing
- `test/fakes/fake_transport.dart` — a scriptable `Transport`: drive frames
  with `simulateMessage`, inspect outbound via `sentMessages`.
- `test/core/protocol/relay_protocol_test.dart` — parse/encode every frame
  kind, garbage and unknown types.
- `test/core/protocol/request_response_manager_test.dart` — matching, error
  mapping, timeout, fail-on-disconnect, ping→pong, cold-start wait.

```dart
final t = FakeTransport();
final rpc = RequestResponseManager(t);
t.status.value = ConnectionStatus.connected;
final future = rpc.request('agents.snapshot', {});
t.simulateMessage('{"type":"response","id":1,"ok":true,"result":{"agents":[]}}');
expect(await future, {'agents': []});
```
