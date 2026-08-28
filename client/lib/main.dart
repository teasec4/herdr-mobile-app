import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/pair_config.dart';
import 'pages/home_page.dart';
import 'pages/pair_page.dart';
import 'services/config_store.dart';
import 'services/relay_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HerdRelayApp());
}

class HerdRelayApp extends StatefulWidget {
  const HerdRelayApp({super.key, this.clientFactory});

  /// Фабрика клиента релея: в проде [WsRelayClient], в тестах — фейк.
  final RelayClient Function(PairConfig config)? clientFactory;

  @override
  State<HerdRelayApp> createState() => _HerdRelayAppState();
}

class _HerdRelayAppState extends State<HerdRelayApp> {
  final ConfigStore _store = ConfigStore();
  PairConfig? _config;
  RelayClient? _client;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _listenDeepLinks();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final config = await _store.load();
    if (!mounted) return;
    if (config == null) {
      setState(() => _loading = false);
    } else {
      await _setConfig(config);
    }
  }

  /// Заменяет пару: закрывает старый клиент релея, поднимает новый.
  Future<void> _setConfig(PairConfig config) async {
    await _client?.close();
    final client = (widget.clientFactory ?? WsRelayClient.new)(config);
    if (!mounted) {
      await client.close();
      return;
    }
    setState(() {
      _client = client;
      _config = config;
      _loading = false;
    });
  }

  /// Глубокие ссылки `herdrelay://pair?...` (Android intent-filter / iOS
  /// URL scheme) позволяют повторно сконфигурировать приложение по ссылке —
  /// в т.ч. со сканом QR из другого приложения.
  void _listenDeepLinks() {
    final appLinks = AppLinks();
    appLinks.uriLinkStream.listen(_applyLink);
    appLinks.getInitialLink().then((uri) {
      if (uri != null) _applyLink(uri);
    }).catchError((_) {
      // на десктопе/вебе deep link может быть не поддержан — не критично
    });
  }

  Future<void> _applyLink(Uri uri) async {
    if (uri.scheme != 'herdrelay') return;
    try {
      final config = PairConfig.fromUri(uri);
      await _store.save(config);
      await _setConfig(config);
    } on FormatException {
      // некорректная ссылка — игнорируем
    }
  }

  /// Разрыв пары: очистить сохранённый конфиг и закрыть клиент.
  Future<void> _disconnect() async {
    await _store.clear();
    final client = _client;
    _client = null;
    await client?.close();
    if (mounted) setState(() => _config = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _app(const Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    final config = _config;
    final client = _client;
    if (client == null || config == null) {
      return _app(
        PairPage(
          onPaired: (config) async {
            await _store.save(config);
            await _setConfig(config);
          },
        ),
      );
    }
    // Клиент релея доступен всему приложению (список и детали — один WS-канал);
    // Provider выше MaterialApp, чтобы его видели и push-роуты.
    return Provider<RelayClient>.value(
      value: client,
      child: _app(
        // Ключ по конфигу: при смене пары по deep link экран пересоздаётся
        // с новым клиентом.
        HomePage(
          key: ValueKey('${config.host}:${config.port}:${config.token}'),
          config: config,
          onDisconnect: _disconnect,
        ),
      ),
    );
  }

  Widget _app(Widget home) {
    return MaterialApp(
      title: 'HerdRelay',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: home,
    );
  }
}
