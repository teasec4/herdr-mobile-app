import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/pair_config.dart';

/// A connection mode offered by the relay's `/pair` endpoint.
class RelayModeInfo {
  const RelayModeInfo({
    required this.mode,
    required this.url,
    required this.link,
    required this.description,
  });

  final String mode;
  final String url;
  final String link;
  final String description;
}

/// Thrown when the relay's modes could not be fetched. [message] is
/// user-presentable; [retriable] is false for errors where another attempt
/// cannot help (e.g. an invalid token).
class ModeFetchException implements Exception {
  const ModeFetchException(this.message, {this.cause, this.retriable = true});

  final String message;
  final Object? cause;
  final bool retriable;

  @override
  String toString() => message;
}

/// Fetches the relay's available connection modes from GET /pair.
///
/// Retry policy: up to [maxAttempts] attempts with a linear backoff for
/// transient failures (network/timeout/5xx); an invalid token fails
/// immediately with a clear message. Every failure surfaces as a
/// [ModeFetchException] with a user-presentable message, so callers never
/// have to interpret raw exceptions.
class ModeService {
  ModeService({
    http.Client? client,
    this.maxAttempts = 3,
    this.timeout = const Duration(seconds: 5),
    this.retryBackoff = const Duration(milliseconds: 500),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxAttempts;
  final Duration timeout;
  final Duration retryBackoff;

  /// Fetches the available modes (available == true only).
  Future<List<RelayModeInfo>> fetch(PairConfig config) async {
    Object? last;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await _fetchOnce(config);
      } on ModeFetchException catch (e) {
        if (!e.retriable) rethrow;
        last = e;
      } catch (e) {
        last = e;
      }
      if (attempt < maxAttempts - 1) {
        await Future<void>.delayed(retryBackoff * (attempt + 1));
      }
    }
    throw ModeFetchException(_friendlyMessage(last), cause: last);
  }

  Future<List<RelayModeInfo>> _fetchOnce(PairConfig config) async {
    final uri = config.httpBaseUri
        .replace(path: '/pair')
        .replace(queryParameters: {'token': config.token});
    final res = await _client.get(uri).timeout(timeout);

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const ModeFetchException(
        'Invalid token — re-scan the pairing QR.',
        retriable: false,
      );
    }
    if (res.statusCode != 200) {
      throw ModeFetchException('Relay answered HTTP ${res.statusCode}.');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final urls = (data['urls'] as Map?)?.cast<String, dynamic>() ?? const {};
    final modes = <RelayModeInfo>[];
    urls.forEach((mode, info) {
      if (info is Map<String, dynamic> && info['available'] == true) {
        modes.add(RelayModeInfo(
          mode: mode,
          url: info['url'] as String? ?? '',
          link: info['link'] as String? ?? '',
          description: info['description'] as String? ?? '',
        ));
      }
    });
    return modes;
  }

  String _friendlyMessage(Object? error) {
    if (error is ModeFetchException) return error.message;
    if (error is TimeoutException) {
      return 'Relay did not respond in time. Try again.';
    }
    if (error is http.ClientException) {
      return 'Cannot reach relay — check your network or that the relay is running.';
    }
    return 'Could not load connection modes ($error).';
  }

  /// Releases the underlying HTTP client (same contract as [HttpHealth.close]).
  ///
  /// The service is a global singleton that outlives relay connections, so
  /// production never calls this; it exists so tests and a full DI teardown
  /// do not leak a socket per service.
  void close() => _client.close();
}
