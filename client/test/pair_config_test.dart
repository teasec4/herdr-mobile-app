import 'package:client/models/pair_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairConfig.fromLink', () {
    test('разбирает корректную ссылку из QR', () {
      final link =
          'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan&token=${'a' * 64}';
      final config = PairConfig.fromLink(link);
      expect(config.host, '192.168.1.5');
      expect(config.port, 8375);
      expect(config.mode, 'lan');
      expect(config.token, 'a' * 64);
    });

    test('применяет дефолтные port и mode', () {
      final config =
          PairConfig.fromLink('herdrelay://pair?host=mac.local&token=${'b' * 64}');
      expect(config.port, PairConfig.defaultPort);
      expect(config.mode, PairConfig.defaultMode);
    });

    test('игнорирует лишние пробелы вокруг ссылки', () {
      final config = PairConfig.fromLink(
        '  herdrelay://pair?host=h&token=${'c' * 64}  ',
      );
      expect(config.host, 'h');
    });

    test('некорректный scheme бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('https://example.com/pair?host=x&token=${'c' * 64}'),
        throwsFormatException,
      );
    });

    test('не тот host в URI бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('herdrelay://relay?host=x&token=${'c' * 64}'),
        throwsFormatException,
      );
    });

    test('без host бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('herdrelay://pair?token=${'c' * 64}'),
        throwsFormatException,
      );
    });

    test('слишком короткий token бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('herdrelay://pair?host=x&token=short'),
        throwsFormatException,
      );
    });

    test('нечисловой port бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('herdrelay://pair?host=x&port=abc&token=${'c' * 64}'),
        throwsFormatException,
      );
    });

    test('port вне диапазона бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('herdrelay://pair?host=x&port=999999&token=${'c' * 64}'),
        throwsFormatException,
      );
    });

    test('не-URI бросает FormatException', () {
      expect(
        () => PairConfig.fromLink('это вообще не ссылка'),
        throwsFormatException,
      );
    });
  });

  group('PairConfig.wsUri / healthUri', () {
    test('wsUri содержит хост, порт и токен', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=192.168.1.5&token=${'f' * 64}',
      );
      expect(config.wsUri.toString(), 'ws://192.168.1.5:8375/ws?token=${'f' * 64}');
    });

    test('IPv6 host оборачивается в квадратные скобки', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=fd7a:115c:a1e0::1&token=${'f' * 64}',
      );
      expect(config.wsUri.host, 'fd7a:115c:a1e0::1');
      expect(config.wsUri.toString(), startsWith('ws://[fd7a:115c:a1e0::1]:8375/ws'));
    });

    test('healthUri ведёт на /healthz', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=mac.local&port=9000&token=${'f' * 64}',
      );
      expect(config.healthUri.toString(), 'http://mac.local:9000/healthz');
    });
  });

  group('PairConfig serialization', () {
    test('toJson/fromJson — round-trip', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=my-mac&port=9000&mode=tailscale&token=${'g' * 64}',
      );
      final restored = PairConfig.fromJson(config.toJson());
      expect(restored.host, config.host);
      expect(restored.port, config.port);
      expect(restored.mode, config.mode);
      expect(restored.token, config.token);
    });

    test('fromJson терпит отсутствие mode и port', () {
      final restored = PairConfig.fromJson({
        'host': 'h',
        'token': 'x' * 64,
      });
      expect(restored.port, PairConfig.defaultPort);
      expect(restored.mode, PairConfig.defaultMode);
    });
  });
}