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

    test('token с недопустимыми символами бросает FormatException', () {
      // Кодированные `&`, `#`, `?` и пробел (в середине) попадают в token
      // после декодирования query-строки и должны отклоняться — они сломали
      // бы wsUri или недопустимы в токене.
      for (final bad in [
        'a' * 16 + '%26b=1', // & → токен становится двумя параметрами
        'a' * 16 + '%23frag', // # → обрезает query
        'a' * 16 + '%3Fx', // ? → обрезает query
        'a' * 16 + ' x', // пробел внутри токена (передаётся напрямую через fromUri)
      ]) {
        expect(
          () => PairConfig.fromLink('herdrelay://pair?host=x&token=$bad'),
          throwsFormatException,
          reason: 'token должен отклоняться: $bad',
        );
      }
    });

    test('token с пробелами по краям обрезается', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=x&token=${'d' * 16}%20%20',
      );
      expect(config.token, 'd' * 16);
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

    test('toJsonSafe маскирует token', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=my-mac&token=${'g' * 64}'
        '&relay_id=relay-123&name=My%20Mac',
      );
      final safe = config.toJsonSafe();
      expect(safe['token'], '${'g' * 8}***');
      expect(safe['token'], isNot(contains('g' * 16)));
      expect(safe['host'], config.host);
      expect(safe['relay_id'], 'relay-123');
      expect(safe['name'], 'My Mac');
    });
  });

  group('PairConfig relay identity', () {
    test('парсит relay_id и name из ссылки', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=192.168.1.5&token=${'a' * 64}'
        '&relay_id=relay-0123456789abcdef&name=My%20Mac',
      );
      expect(config.relayId, 'relay-0123456789abcdef');
      expect(config.name, 'My Mac');
      expect(config.profileKey, 'relay-0123456789abcdef');
      expect(config.displayName, 'My Mac');
    });

    test('без relay_id/name — profileKey из host:port, displayName = host', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=my-mac&port=9000&token=${'b' * 64}',
      );
      expect(config.relayId, isNull);
      expect(config.name, isNull);
      expect(config.profileKey, 'my-mac:9000');
      expect(config.displayName, 'my-mac');
    });

    test('пустые relay_id/name превращаются в null', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=h&token=${'c' * 64}&relay_id=&name=%20',
      );
      expect(config.relayId, isNull);
      expect(config.name, isNull);
    });

    test('toJson/fromJson сохраняют relay_id и name', () {
      final config = PairConfig.fromLink(
        'herdrelay://pair?host=my-mac&token=${'d' * 64}'
        '&relay_id=relay-123&name=My%20Mac',
      );
      final restored = PairConfig.fromJson(config.toJson());
      expect(restored.relayId, 'relay-123');
      expect(restored.name, 'My Mac');
    });

    test('fromJson терпит отсутствие relay_id и name', () {
      final restored = PairConfig.fromJson({
        'host': 'h',
        'token': 'x' * 64,
      });
      expect(restored.relayId, isNull);
      expect(restored.name, isNull);
    });
  });
}