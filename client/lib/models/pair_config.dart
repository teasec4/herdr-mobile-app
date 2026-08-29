/// Relay pairing configuration, parsed from a pair link.
///
/// The relay generates the link: `herdrelay://pair?host=...&port=...&mode=...&token=...`
/// (see `cmd/relay/pair.go`). The client stores it in [ConfigStore] and uses it
/// to connect over WebSocket.
class PairConfig {
  const PairConfig({
    required this.host,
    required this.port,
    required this.mode,
    required this.token,
  });

  /// Relay host: IP or DNS name (for tailscale, a name like `mac.local.c.tailnet.ts.net`).
  final String host;

  /// Relay port (usually 8375).
  final int port;

  /// Network mode: lan / tailscale / funnel / gateway.
  final String mode;

  /// Pair secret (64 hex), also used as the WS token (`?token=` in the query).
  final String token;

  static const int defaultPort = 8375;
  static const String defaultMode = 'lan';

  static const String _scheme = 'herdrelay';
  static const String _pairHost = 'pair';

  /// Minimum token length to filter out obvious typos.
  static const int _minTokenLength = 16;

  /// Parses a pair link from a QR code or pasted text.
  ///
  /// Throws [FormatException] with a human-readable message if the link does
  /// not look like a relay pair link.
  factory PairConfig.fromLink(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) {
      throw const FormatException('Invalid link');
    }
    return PairConfig.fromUri(uri);
  }

  factory PairConfig.fromUri(Uri uri) {
    if (uri.scheme != _scheme || uri.host != _pairHost) {
      throw FormatException('Expected a link like $_scheme://$_pairHost?host=...');
    }

    final host = uri.queryParameters['host']?.trim();
    if (host == null || host.isEmpty) {
      throw const FormatException('Link is missing a host');
    }

    final portRaw = uri.queryParameters['port'];
    final int port;
    if (portRaw == null || portRaw.isEmpty) {
      port = defaultPort;
    } else {
      final parsed = int.tryParse(portRaw);
      if (parsed == null) {
        throw FormatException('Invalid port: $portRaw');
      }
      port = parsed;
    }
    if (port <= 0 || port > 65535) {
      throw FormatException('Invalid port: $portRaw');
    }

    final token = uri.queryParameters['token'] ?? '';
    if (token.length < _minTokenLength) {
      throw const FormatException('Token too short — corrupted link');
    }

    final mode = uri.queryParameters['mode'] ?? defaultMode;
    if (mode.isEmpty || mode.contains(' ')) {
      throw FormatException('Invalid mode: $mode');
    }

    return PairConfig(host: host, port: port, mode: mode, token: token);
  }

  /// Host wrapped in square brackets for IPv6 (`Uri.host` strips the brackets).
  String get _authority => host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  /// WS address of the relay for the WebSocket connection (token in the query).
  Uri get wsUri {
    // Funnel mode uses secure WebSocket (wss://) over HTTPS
    final scheme = mode == 'funnel' ? 'wss' : 'ws';
    final portSuffix = mode == 'funnel' ? '' : ':$port';
    return Uri.parse('$scheme://$_authority$portSuffix/ws?token=$token');
  }

  /// HTTP address of /healthz for a quick availability check.
  Uri get healthUri {
    final scheme = mode == 'funnel' ? 'https' : 'http';
    final portSuffix = mode == 'funnel' ? '' : ':$port';
    return Uri.parse('$scheme://$_authority$portSuffix/healthz');
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'mode': mode,
        'token': token,
      };

  factory PairConfig.fromJson(Map<String, dynamic> json) => PairConfig(
        host: json['host'] as String,
        port: (json['port'] as num?)?.toInt() ?? defaultPort,
        mode: json['mode'] as String? ?? defaultMode,
        token: json['token'] as String,
      );

  @override
  String toString() => 'PairConfig($mode $_authority:$port)';
}