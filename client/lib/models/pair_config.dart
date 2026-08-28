/// Конфигурация пары с релеем, полученная из пары-ссылки.
///
/// Ссылку генерирует релей: `herdrelay://pair?host=...&port=...&mode=...&token=...`
/// (см. `cmd/relay/pair.go`). Клиент хранит её в [ConfigStore] и по ней
/// подключается по WebSocket.
class PairConfig {
  const PairConfig({
    required this.host,
    required this.port,
    required this.mode,
    required this.token,
  });

  /// Хост релея: IP или DNS-имя (для tailscale — имя вида `mac.local.c.tailnet.ts.net`).
  final String host;

  /// Порт релея (обычно 8375).
  final int port;

  /// Режим сети: lan / tailscale / funnel / gateway.
  final String mode;

  /// Секрет пары (64 hex), он же WS-токен (`?token=` в query).
  final String token;

  static const int defaultPort = 8375;
  static const String defaultMode = 'lan';

  static const String _scheme = 'herdrelay';
  static const String _pairHost = 'pair';

  /// Минимальная длина токена, чтобы отсечь очевидные опечатки.
  static const int _minTokenLength = 16;

  /// Разбирает пару-ссылку из QR или вставленного текста.
  ///
  /// Бросает [FormatException] с человекочитаемым сообщением, если ссылка
  /// не похожа на пару-ссылку релея.
  factory PairConfig.fromLink(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) {
      throw const FormatException('Некорректная ссылка');
    }
    return PairConfig.fromUri(uri);
  }

  factory PairConfig.fromUri(Uri uri) {
    if (uri.scheme != _scheme || uri.host != _pairHost) {
      throw FormatException('Ожидается ссылка вида $_scheme://$_pairHost?host=...');
    }

    final host = uri.queryParameters['host']?.trim();
    if (host == null || host.isEmpty) {
      throw const FormatException('В ссылке не указан host');
    }

    final portRaw = uri.queryParameters['port'];
    final int port;
    if (portRaw == null || portRaw.isEmpty) {
      port = defaultPort;
    } else {
      final parsed = int.tryParse(portRaw);
      if (parsed == null) {
        throw FormatException('Некорректный port: $portRaw');
      }
      port = parsed;
    }
    if (port <= 0 || port > 65535) {
      throw FormatException('Некорректный port: $portRaw');
    }

    final token = uri.queryParameters['token'] ?? '';
    if (token.length < _minTokenLength) {
      throw const FormatException('Слишком короткий токен — ссылка повреждена');
    }

    final mode = uri.queryParameters['mode'] ?? defaultMode;
    if (mode.isEmpty || mode.contains(' ')) {
      throw FormatException('Некорректный mode: $mode');
    }

    return PairConfig(host: host, port: port, mode: mode, token: token);
  }

  /// Host с квадратными скобками для IPv6 (в `Uri.host` скобки сняты).
  String get _authority => host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

  /// ws-адрес релея для WebSocket-подключения (токен в query).
  Uri get wsUri => Uri.parse('ws://$_authority:$port/ws?token=$token');

  /// http-адрес healthz для быстрой проверки доступности.
  Uri get healthUri => Uri.parse('http://$_authority:$port/healthz');

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