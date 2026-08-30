import 'dart:async';

import 'package:client/core/transport/transport.dart';
import 'package:client/core/transport/websocket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/fake_web_socket_channel.dart';

/// Transport-layer tests: raw frames, status transitions, reconnect with
/// backoff, pause/resume — against a fake WebSocketChannel, no network.
///
/// The transport must know nothing about JSON/requests/events; every test
/// here speaks plain strings.
void main() {
  final uri = Uri.parse('ws://localhost:8375/ws');

  Future<void> waitStatus(
    WebSocketTransport t,
    ConnectionStatus wanted, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (t.status.value == wanted) return;
    final done = Completer<void>();
    void listener() {
      if (t.status.value == wanted && !done.isCompleted) done.complete();
    }

    t.status.addListener(listener);
    await done.future.timeout(timeout);
    t.status.removeListener(listener);
  }

  group('WebSocketTransport', () {
    test('connect delivers status transitions and inbound string frames',
        () async {
      final channel = FakeWebSocketChannel();
      final t = WebSocketTransport(channelFactory: (_) => channel);

      expect(t.status.value, ConnectionStatus.disconnected);
      final messages = <String>[];
      final sub = t.messages.listen(messages.add);

      await t.connect(uri);
      expect(t.status.value, ConnectionStatus.connected);

      channel.simulateMessage('hello');
      channel.simulateMessage('world');
      await pumpEventQueue();
      expect(messages, ['hello', 'world']);

      await sub.cancel();
      await t.close();
    });

    test('send writes the raw string to the channel', () async {
      final channel = FakeWebSocketChannel();
      final t = WebSocketTransport(channelFactory: (_) => channel);
      await t.connect(uri);

      t.send('{"type":"ping"}');
      t.send('plain text');
      expect(channel.sent, ['{"type":"ping"}', 'plain text']);

      await t.close();
    });

    test('non-string inbound frames are ignored', () async {
      final channel = FakeWebSocketChannel();
      final t = WebSocketTransport(channelFactory: (_) => channel);
      final messages = <String>[];
      final sub = t.messages.listen(messages.add);
      await t.connect(uri);

      channel.simulateMessage(42);
      channel.simulateMessage('{"a":1}');
      await pumpEventQueue();
      expect(messages, ['{"a":1}']);

      await sub.cancel();
      await t.close();
    });

    test('disconnect triggers reconnect with backoff', () async {
      var calls = 0;
      late FakeWebSocketChannel first;
      final channels = <FakeWebSocketChannel>[];
      final t = WebSocketTransport(channelFactory: (u) {
        calls++;
        final c = FakeWebSocketChannel();
        channels.add(c);
        if (calls == 1) first = c;
        return c;
      });

      await t.connect(uri);
      expect(calls, 1);
      expect(t.status.value, ConnectionStatus.connected);

      first.simulateDone();
      await waitStatus(t, ConnectionStatus.disconnected);
      expect(t.status.value, ConnectionStatus.disconnected);

      // First backoff is 1 s (2^0); wait past it plus connect time.
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(calls, 2);
      expect(t.status.value, ConnectionStatus.connected);

      await t.close();
    });

    test('pause stops reconnect; resume restarts it', () async {
      var calls = 0;
      late FakeWebSocketChannel first;
      final t = WebSocketTransport(channelFactory: (u) {
        calls++;
        final c = FakeWebSocketChannel();
        if (calls == 1) first = c;
        return c;
      });

      await t.connect(uri);
      t.pause();
      first.simulateDone();
      await waitStatus(t, ConnectionStatus.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(calls, 1, reason: 'no reconnect while paused');

      t.resume();
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(calls, 2, reason: 'reconnect after resume');

      await t.close();
    });

    test('error on the stream is treated as a disconnect', () async {
      final channel = FakeWebSocketChannel();
      final t = WebSocketTransport(channelFactory: (_) => channel);
      await t.connect(uri);

      channel.simulateError(Exception('socket blew up'));
      await waitStatus(t, ConnectionStatus.disconnected);
      expect(t.status.value, ConnectionStatus.disconnected);
      expect(t.lastError, isNotNull);

      await t.close();
    });

    test('close stops reconnects and closes the message stream', () async {
      var calls = 0;
      late FakeWebSocketChannel first;
      final t = WebSocketTransport(channelFactory: (u) {
        calls++;
        final c = FakeWebSocketChannel();
        if (calls == 1) first = c;
        return c;
      });

      await t.connect(uri);
      await t.close();
      expect(t.status.value, ConnectionStatus.disconnected);

      first.simulateDone();
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(calls, 1, reason: 'no reconnect after close');
    });

    test('connect failure schedules a reconnect (bad channel ready)', () async {
      var calls = 0;
      final t = WebSocketTransport(channelFactory: (u) {
        calls++;
        // Channel whose ready never completes: connect stalls, no crash.
        return FakeWebSocketChannel(connected: false);
      });

      // Do not await: ready never completes, connect() would hang.
      // ignore: unawaited_futures
      t.connect(uri);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(t.status.value, ConnectionStatus.connecting);
      expect(calls, 1);

      await t.close();
    });
  });
}
