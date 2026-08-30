import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/service_locator.dart';
import 'models/pair_config.dart';
import 'pages/home_page.dart';
import 'pages/pair_page.dart';
import 'pages/profile_page.dart';
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

class _HerdRelayAppState extends State<HerdRelayApp> with WidgetsBindingObserver {
  /// Root navigator so profile/add-device screens can be pushed on top of
  /// HomePage and popped from outside (e.g. in deep-link handlers).
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  PairConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
    _listenDeepLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    teardownRelayServices();
    super.dispose();
  }

  /// Pauses/resumes WS reconnects while the app is backgrounded: keeps the
  /// reconnect loop from draining battery and avoids stale reconnects on
  /// resume (iOS suspends network sockets ~30 s after backgrounding).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!getIt.isRegistered<RelayClient>()) return;
    final client = getIt<RelayClient>();
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        client.pauseReconnect();
      case AppLifecycleState.resumed:
        client.resumeReconnect();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _bootstrap() async {
    final store = getIt<ConfigStore>();
    final config = await store.loadActive();
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
      // Upsert: re-pairing the same relay (same relayId) replaces the saved
      // profile instead of adding a duplicate.
      await getIt<ConfigStore>().saveProfile(config);
      await _setConfig(config);
    } on FormatException {
      // invalid link — ignore
    }
  }

  /// Makes the profile active and reconnects to it.
  Future<void> _switchTo(PairConfig config) async {
    await getIt<ConfigStore>().setActive(config.profileKey);
    await _setConfig(config);
  }

  /// Forgets the active relay: closes the client and either returns to the
  /// scanner (no profiles left) or reconnects to the next active profile.
  Future<void> _forgetActive() async {
    final store = getIt<ConfigStore>();
    final active = _config;
    if (active != null) await store.forget(active.profileKey);
    await teardownRelayServices();
    final next = await store.loadActive();
    if (!mounted) return;
    if (next == null) {
      setState(() => _config = null);
    } else {
      await _setConfig(next);
    }
  }

  /// Forgets an arbitrary profile from the picker; if it was the active one,
  /// behaves like [_forgetActive].
  Future<void> _forgetProfile(String profileKey) async {
    final store = getIt<ConfigStore>();
    if (_config?.profileKey == profileKey) {
      await _forgetActive();
      return;
    }
    await store.forget(profileKey);
  }

  Future<void> _showProfilePicker() async {
    await _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => ProfilePage(
          onSwitch: _switchTo,
          onForget: _forgetProfile,
        ),
      ),
    );
  }

  Future<void> _showAddDevice() async {
    await _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => PairPage(onPaired: _onPairedFromScanner),
      ),
    );
  }

  /// Scanner (from Add device) may be opened on top of HomePage; on success
  /// pop it back, then reconnect to the freshly saved (upserted) profile.
  Future<void> _onPairedFromScanner(PairConfig config) async {
    await getIt<ConfigStore>().saveProfile(config);
    if (mounted && (_navKey.currentState?.canPop() ?? false)) {
      _navKey.currentState?.pop();
    }
    await _setConfig(config);
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
            await getIt<ConfigStore>().saveProfile(config);
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
        onRequestSwitch: _showProfilePicker,
        onAddDevice: _showAddDevice,
        onForgetDevice: _forgetActive,
      ),
    );
  }

  Widget _app(Widget home) {
    return MaterialApp(
      navigatorKey: _navKey,
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
