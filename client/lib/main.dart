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

  /// Relay client factory: [WsRelayClient] in production, a fake in tests.
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

  /// Replaces the pair: closes the old relay client and brings up a new one.
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

  /// Deep links `herdrelay://pair?...` (Android intent-filter / iOS
  /// URL scheme) let the app be reconfigured from a link — including via
  /// scanning a QR from another app.
  void _listenDeepLinks() {
    final appLinks = AppLinks();
    appLinks.uriLinkStream.listen(_applyLink);
    appLinks.getInitialLink().then((uri) {
      if (uri != null) _applyLink(uri);
    }).catchError((_) {
      // deep links may be unsupported on desktop/web — not critical
    });
  }

  Future<void> _applyLink(Uri uri) async {
    if (uri.scheme != 'herdrelay') return;
    try {
      final config = PairConfig.fromUri(uri);
      await _store.save(config);
      await _setConfig(config);
    } on FormatException {
      // invalid link — ignore
    }
  }

  /// Unpair: clear the saved config and close the client.
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
    // The relay client is shared across the app (list and details use one WS channel);
    // Provider sits above MaterialApp so push routes can see it too.
    return Provider<RelayClient>.value(
      value: client,
      child: _app(
        // Key derived from config: when the pair changes via deep link, the screen
        // is recreated with the new client.
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: home,
    );
  }
}
