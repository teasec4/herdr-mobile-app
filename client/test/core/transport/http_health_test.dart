import 'dart:io';

import 'package:client/core/transport/http_health.dart';
import 'package:flutter_test/flutter_test.dart';

/// HttpHealth tests against a real loopback HTTP server (dart:io).
void main() {
  late HttpServer server;
  late Uri uri;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/healthz');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('returns true when the endpoint answers 200', () async {
    server.listen((req) {
      req.response.statusCode = 200;
      req.response.write('{"ok":true}');
      req.response.close();
    });

    final health = HttpHealth();
    expect(await health.check(uri), isTrue);
    health.close();
  });

  test('returns false when the endpoint answers 500', () async {
    server.listen((req) {
      req.response.statusCode = 500;
      req.response.close();
    });

    final health = HttpHealth();
    expect(await health.check(uri, attempts: 2), isFalse);
    health.close();
  });

  test('returns false when nothing listens on the port', () async {
    // Close the server first: connection refused on every attempt.
    await server.close(force: true);

    final health = HttpHealth();
    expect(await health.check(uri, attempts: 2), isFalse);
    health.close();
  });
}
