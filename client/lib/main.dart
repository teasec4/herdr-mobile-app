import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/service_locator.dart';
import 'models/pair_config.dart';
import 'pages/home_page.dart';
import 'pages/pair_page.dart';
import 'services/config_store.dart';
import 'services/relay_client.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize dependency injection
  await setupDependencies();

  // Draw behind the system bars and match them to the dark theme; otherwise the
  // white system navigation/status bar shows as a light band under the app.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
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
  PairConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _listenDeepLinks();
  }

  @override
  void dispose() {
    teardownRelayServices();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final store = getIt<ConfigStore>();
    final config = await store.load();
    if (!mounted) return;
    if (config == null) {
      setState(() => _loading = false);
    } else {
      await _setConfig(config);
    }
  }

  /// Replaces the pair: closes the old relay and brings up a new one.
  Future<void> _setConfig(PairConfig config) async {
    await teardownRelayServices();
    setupRelayServices(config, clientFactory: widget.clientFactory);
    if (!mounted) return;
    setState(() {
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
      final store = getIt<ConfigStore>();
      await store.save(config);
      await _setConfig(config);
    } on FormatException {
      // invalid link — ignore
    }
  }

  /// Unpair: clear the saved config and close the client.
  Future<void> _disconnect() async {
    final store = getIt<ConfigStore>();
    await store.clear();
    await teardownRelayServices();
    if (mounted) setState(() => _config = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _app(const Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    final config = _config;
    if (config == null) {
      return _app(
        PairPage(
          onPaired: (config) async {
            final store = getIt<ConfigStore>();
            await store.save(config);
            await _setConfig(config);
          },
        ),
      );
    }
    // Key derived from config: when the pair changes via deep link, the screen
    // is recreated with the new services.
    return _app(
      HomePage(
        key: ValueKey('${config.host}:${config.port}:${config.token}'),
        config: config,
        onDisconnect: _disconnect,
      ),
    );
  }

  Widget _app(Widget home) {
    return MaterialApp(
      title: 'HerdRelay',
      debugShowCheckedModeBanner: false,
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
