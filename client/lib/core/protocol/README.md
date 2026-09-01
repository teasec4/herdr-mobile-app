# Protocol Layer

## Purpose
The relay wire protocol: JSON ⇄ typed frames, request-response matching,
timeouts, fail-on-disconnect, and automatic ping/pong. Independent of any
transport — the same code works over WebSocket now and over HTTP/gRPC later
(docs/09-refactoring-plan.md §2.2).

## Dependencies
- `dart:async` (Completer, Timer, StreamSubscription)
- `core/transport/transport.dart` (Transport interface — status + send only)

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
  void handleMessage(String raw);   // parse + route (for raw-frame callers/tests)
  void handleFrame(Frame frame);    // route an already-parsed frame
  void dispose();
}
```

## Single-subscription routing (M2)
`RequestResponseManager` does **not** subscribe to `Transport.messages` itself.
The owning `RelayClientImpl` is the one transport subscriber: it parses each
inbound frame exactly once, surfaces `EventFrame`s to the UI, and routes
responses/server pings here via `handleFrame`. `handleMessage` exists for
callers (and tests) that only have the raw text — it parses, then delegates.

## Usage
```dart
final rpc = RequestResponseManager(transport);
final result = await rpc.request('agents.snapshot', {});
final agents = (result['agents'] as List?)?.map(RelayAgent.fromJson) ?? [];
// inbound frames are routed by the owning client:
//   rpc.handleMessage(rawFrame)  // or rpc.handleFrame(parsedFrame)
```

## Testing
- `test/fakes/fake_transport.dart` — a scriptable `Transport`: inspect outbound
  via `sentMessages`.
- `test/core/protocol/relay_protocol_test.dart` — parse/encode every frame
  kind, garbage and unknown types.
- `test/core/protocol/request_response_manager_test.dart` — matching, error
  mapping, timeout, fail-on-disconnect, ping→pong, cold-start wait. Because the
  manager no longer subscribes to the transport, tests drive frames through
  `rpc.handleMessage(...)` instead of `transport.simulateMessage(...)`.

```dart
final t = FakeTransport();
final rpc = RequestResponseManager(t);
t.status.value = ConnectionStatus.connected;
final future = rpc.request('agents.snapshot', {});
rpc.handleMessage('{"type":"response","id":1,"ok":true,"result":{"agents":[]}}');
expect(await future, {'agents': []});
```
