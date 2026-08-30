import 'dart:async';

import 'package:http/http.dart' as http;

/// Quick HTTP liveness check against the relay's `/healthz` endpoint.
///
/// A single check can fail on a transient network blip, so [check] retries
/// [attempts] times with a short linear backoff before reporting the relay as
/// offline (same behavior as the legacy `WsRelayClient.healthz`).
class HttpHealth {
  HttpHealth({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Returns true if [uri] answered HTTP 200 within the attempt budget.
  Future<bool> check(Uri uri, {int attempts = 3}) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final res = await _client.get(uri).timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) return true;
      } catch (_) {
        // transient failure — fall through and retry
      }
      if (attempt < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    return false;
  }

  void close() => _client.close();
}
