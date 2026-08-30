import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client/core/transport/http_transport.dart';
import 'package:client/core/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// HttpTransport against a mock relay (dart:io HttpServer) that speaks the
/// Phase 5 endpoints: POST /api/rpc (request frame in, response frame out)
/// and GET /api/events/stream (SSE event frames).
///
/// Note: the mock writes SSE bodies from the request handler (timers), not
/// from async stream listeners — dart:io only flushes a body chunk written
/// in the handler context (verified empirically; Go's SSE flush is standard).
void main() {
  late HttpServer server;
  late Uri baseUri;

  Future<void> waitFor(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('condition not met');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server.port}');

    server.listen((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/rpc') {
        final body = await utf8.decodeStream(req);
        final frame = jsonDecode(body) as Map<String, dynamic>;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'type': 'response',
          'id': frame['id'],
          'ok': true,
          'result': {'echo': frame['method']},
        }));
        await req.response.close();
        return;
      }

      if (req.method == 'GET' && req.uri.path == '/api/events/stream') {
        req.response.headers.set('Content-Type', 'text/event-stream');
        // dart:io only flushes the body on close (not on flush), so the mock
        // writes the event and closes the stream; Go's SSE flushes live.
        req.response.headers.chunkedTransferEncoding = true;
        req.response.write(':\n\n');
        req.response.write('data: {"type":"event","event":"pane.updated",'
            '"data":{"pane_id":"p1"}}\n\n');
        await req.response.close();
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('connect opens the SSE stream and reports connected', () async {
    final t = HttpTransport(baseUri: baseUri, token: 'secret');
    await t.connect(baseUri);
    expect(t.status.value, ConnectionStatus.connected);
    await t.close();
  });

  test('send posts a request frame and delivers the response frame',
      () async {
    final t = HttpTransport(baseUri: baseUri, token: 'secret');
    final frames = <String>[];
    final sub = t.messages.listen(frames.add);
    await t.connect(baseUri);

    t.send(jsonEncode({
      'type': 'request',
      'id': 1,
      'method': 'agents.snapshot',
      'params': <String, dynamic>{},
    }));

    await waitFor(
      () => frames.any((f) => (jsonDecode(f) as Map)['type'] == 'response'),
    );
    final response = frames
        .map(jsonDecode)
        .cast<Map<String, dynamic>>()
        .firstWhere((f) => f['type'] == 'response');
    expect(response['id'], 1);
    expect(response['ok'], isTrue);
    expect((response['result'] as Map)['echo'], 'agents.snapshot');

    await sub.cancel();
    await t.close();
  });

  test('SSE event frames are delivered into messages', () async {
    final t = HttpTransport(baseUri: baseUri, token: 'secret');
    final frames = <String>[];
    final sub = t.messages.listen(frames.add);
    await t.connect(baseUri);

    // The mock pushes one event ~100 ms after the stream opens.
    await waitFor(() => frames.isNotEmpty);
    final event = jsonDecode(frames.single) as Map<String, dynamic>;
    expect(event['type'], 'event');
    expect(event['event'], 'pane.updated');
    expect((event['data'] as Map)['pane_id'], 'p1');

    await sub.cancel();
    await t.close();
  });

  test('SSE stream loss triggers disconnected + reconnect', () async {
    var sseConnections = 0;
    // Replace the server with one that drops the first SSE connection.
    final inner = server;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server.port}');
    await inner.close(force: true);

    server.listen((req) async {
      if (req.method == 'GET' && req.uri.path == '/api/events/stream') {
        sseConnections++;
        req.response.headers.set('Content-Type', 'text/event-stream');
        req.response.headers.chunkedTransferEncoding = true;
        if (sseConnections == 1) {
          req.response.write(':\n\n');
          await req.response.flush();
          // Simulate the server dropping the stream.
          await req.response.close();
          return;
        }
        req.response.write(':\n\n');
        await req.response.flush();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final t = HttpTransport(baseUri: baseUri, token: 'secret');
    await t.connect(baseUri);
    expect(sseConnections, 1);
    expect(t.status.value, ConnectionStatus.connected);

    // The first SSE stream was closed by the server -> disconnected, then
    // reconnect after the 1 s backoff.
    await waitFor(() => t.status.value == ConnectionStatus.disconnected);
    await waitFor(() => t.status.value == ConnectionStatus.connected,
        timeout: const Duration(seconds: 3));
    expect(sseConnections, 2, reason: 'reconnected to a fresh SSE stream');

    await t.close();
  });
}
