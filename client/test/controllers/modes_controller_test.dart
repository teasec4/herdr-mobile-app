import 'package:client/controllers/modes_controller.dart';
import 'package:client/core/connection/mode_service.dart';
import 'package:client/models/pair_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = PairConfig(
    host: 'h',
    port: 8375,
    mode: 'lan',
    token: '0123456789abcdef0123456789abcdef',
    relayId: 'r1',
  );

  const twoModes = [
    RelayModeInfo(
      mode: 'lan',
      url: 'ws://192.168.1.5:8375',
      link: '',
      description: 'Local network',
    ),
    RelayModeInfo(
      mode: 'tailscale',
      url: 'ws://mac.ts.net:8375',
      link: '',
      description: 'Tailscale VPN',
    ),
  ];

  group('ModesController.load', () {
    test('успешная загрузка кладёт данные в state', () async {
      final controller = ModesController((_) async => twoModes);
      await controller.load(config);

      expect(controller.state.hasData, isTrue);
      expect(controller.state.dataOrNull, hasLength(2));
    });

    test('ошибка fetch переходит в hasError', () async {
      final controller = ModesController(
        (_) async => throw const ModeFetchException('Cannot reach relay'),
      );
      await controller.load(config);

      expect(controller.state.hasError, isTrue);
      expect(controller.state.errorOrNull, isA<ModeFetchException>());
    });

    test('повторный load той же конфигурации обслуживается из кэша', () async {
      var fetches = 0;
      final controller = ModesController((_) async {
        fetches++;
        return twoModes;
      });

      await controller.load(config);
      await controller.load(config);

      expect(fetches, 1, reason: 'второй load должен попасть в кэш');
    });

    test('параллельные load той же конфигурации дедуплицируются (in-flight)',
        () async {
      var fetches = 0;
      final controller = ModesController((_) async {
        fetches++;
        return twoModes;
      });

      await Future.wait([controller.load(config), controller.load(config)]);

      expect(fetches, 1, reason: 'in-flight guard должен переиспользовать вызов');
    });

    test('force: true ре-фетчит даже при свежем кэше', () async {
      var fetches = 0;
      final controller = ModesController((_) async {
        fetches++;
        return twoModes;
      });

      await controller.load(config);
      await controller.load(config, force: true);

      expect(fetches, 2);
    });

    test('смена mode даёт новый ключ кэша и ре-фетчит', () async {
      var fetches = 0;
      final controller = ModesController((_) async {
        fetches++;
        return twoModes;
      });
      final viaTailscale = config.connectVia(
        'tailscale',
        const RelayEndpoint(host: 'mac.ts.net', port: 8375),
      );

      await controller.load(config);
      await controller.load(viaTailscale);

      expect(fetches, 2,
          reason: 'другой mode того же профиля — отдельный кэш-ключ');
    });
  });

  group('ModesController.switchMode', () {
    test('меняет активный mode и сохраняет остальные endpoint-ы', () async {
      final controller = ModesController((_) async => twoModes);
      await controller.load(config);

      final switched =
          controller.switchMode(config, twoModes[1]); // tailscale

      expect(switched.mode, 'tailscale');
      expect(switched.host, 'mac.ts.net');
      expect(switched.endpointFor('lan'),
          const RelayEndpoint(host: '192.168.1.5', port: 8375));
      expect(switched.endpointFor('tailscale'),
          const RelayEndpoint(host: 'mac.ts.net', port: 8375));
    });
  });
}
