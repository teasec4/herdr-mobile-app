import 'dart:convert';
import 'dart:io';

import 'package:client/core/connection/mode_service.dart';
import 'package:client/models/pair_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// ModeService: retries, attempt limits, timeouts and user-presentable
/// errors, verified against a real loopback HTTP server.
void main() {
  final config = PairConfig(
    host: '127.0.0.1',
    port: 0, // replaced below with the test server's port
    mode: 'lan',
    token: '0123456789abcdef0123456789abcdef',
  );

  HttpServer? server;
  int pairRequests = 0;

  /// Serves /pair with [status] and optional [body]; counts requests.
  Future<void> startServer({
    int status = 200,
    String? body,
    List<int> statuses = const [],
  }) async {
    pairRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((req) async {
      if (req.uri.path != '/pair') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      pairRequests++;
      final idx = pairRequests - 1;
      final s = idx < statuses.length ? statuses[idx] : status;
      req.response.statusCode = s;
      if (body != null) req.response.write(body);
      await req.response.close();
    });
  }

  Future<PairConfig> cfg() async =>
      PairConfig(host: '127.0.0.1', port: server!.port, mode: 'lan',
          token: config.token);

  tearDown(() async {
    await server?.close(force: true);
  });

  final okBody = jsonEncode({
    'mode': 'lan',
    'primary': 'lan',
    'urls': {
      'lan': {
        'url': 'ws://192.168.1.5:8375',
        'link': 'herdrelay://pair?host=192.168.1.5&mode=lan&token=x',
        'available': true,
        'description': 'Local network',
      },
      'tailscale': {
        'url': 'ws://mac.ts.net:8375',
        'link': 'herdrelay://pair?host=mac.ts.net&mode=tailscale&token=x',
        'available': false,
        'description': 'Tailscale VPN',
      },
    },
  });

  test('returns only available modes from a 200 response', () async {
    await startServer(body: okBody);
    final service = ModeService();
    final modes = await service.fetch(await cfg());
    expect(modes.map((m) => m.mode), ['lan']); // tailscale marked unavailable
  });

  test('retries transient failures and succeeds on the second attempt',
      () async {
    await startServer(statuses: [500, 200], body: okBody);
    final service = ModeService(retryBackoff: const Duration(milliseconds: 10));
    final modes = await service.fetch(await cfg());
    expect(pairRequests, 2);
    expect(modes, hasLength(1));
  });

  test('gives up after maxAttempts with a user-presentable error', () async {
    await startServer(statuses: const [500, 500, 500]);
    final service =
        ModeService(maxAttempts: 3, retryBackoff: const Duration(milliseconds: 10));
    await expectLater(
      service.fetch(await cfg()),
      throwsA(isA<ModeFetchException>()
          .having((e) => e.message, 'message', contains('HTTP 500'))),
    );
    expect(pairRequests, 3);
  });

  test('invalid token fails immediately without retries', () async {
    await startServer(status: 401);
    final service = ModeService(retryBackoff: const Duration(milliseconds: 10));
    await expectLater(
      service.fetch(await cfg()),
      throwsA(isA<ModeFetchException>()
          .having((e) => e.message, 'message', contains('Invalid token'))),
    );
    expect(pairRequests, 1, reason: '401 must not be retried');
  });

  test('unreachable relay produces a network error after all attempts',
      () async {
    // No server: bind a port, close it, then try to connect to it.
    final tmp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = tmp.port;
    await tmp.close(force: true);

    final service = ModeService(retryBackoff: const Duration(milliseconds: 10));
    final c = PairConfig(host: '127.0.0.1', port: port, mode: 'lan',
        token: config.token);
    await expectLater(
      service.fetch(c),
      throwsA(isA<ModeFetchException>()
          .having((e) => e.message, 'message', contains('Cannot reach relay'))),
    );
  });
}
