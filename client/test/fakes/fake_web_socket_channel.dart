import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A controllable [WebSocketChannel] for tests: no real network.
///
/// The test pushes inbound frames with [simulateMessage]/[simulateError]/
/// [simulateDone] and inspects what the client sent via [sent].
///
/// [connected] controls whether `ready` completes immediately (default) or
/// stays pending — use `connected: false` to test cold-start behavior.
class FakeWebSocketChannel with StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeWebSocketChannel({bool connected = true}) {
    if (connected) _ready.complete();
  }

  final Completer<void> _ready = Completer<void>();
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  late final FakeWebSocketSink _sink = FakeWebSocketSink(sent);

  /// Frames the client sent through the sink.
  final List<dynamic> sent = [];

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  /// Completes `ready` for a channel created with `connected: false`.
  void completeConnection() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Delivers an inbound frame to the client.
  void simulateMessage(dynamic data) => _incoming.add(data);

  /// Fails the inbound stream (like a dropped socket).
  void simulateError(Object error) => _incoming.addError(error);

  /// Closes the inbound stream (like a remote close).
  void simulateDone() => _incoming.close();
}

/// Sink half of [FakeWebSocketChannel]: records `add` calls, `close` is a no-op
/// that completes `done` immediately.
class FakeWebSocketSink implements WebSocketSink {
  FakeWebSocketSink(this.sent);

  final List<dynamic> sent;
  final Completer<void> _done = Completer<void>();

  @override
  Future get done => _done.future;

  @override
  void add(dynamic data) {
    sent.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future close([int? closeCode, String? closeReason]) {
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }
}
