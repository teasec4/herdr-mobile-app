import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/connection/connection_fallback_manager.dart';
import 'core/service_locator.dart';
import 'core/transport/transport.dart';
import 'models/pair_config.dart';
import 'pages/connection_page.dart';
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
  /// Root navigator so profile/add-device screens can be pushed on top of
  /// HomePage and popped from outside (e.g. in deep-link handlers).
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  PairConfig? _config;
  bool _loading = true;

  /// Watches the live transport and auto-switches to another saved endpoint
  /// when the current mode becomes unreachable (docs/AUTO_MODE_SWITCHING_PLAN.md,
  /// Phase 2). Re-armed via [_reattachFallback] on every config change.
  ConnectionFallbackManager? _fallbackManager;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _listenDeepLinks();
  }

  @override
  void dispose() {
    _fallbackManager?.dispose();
    _fallbackManager = null;
    teardownRelayServices();
    super.dispose();
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
    _reattachFallback(config);
    if (!mounted) return;
    setState(() {
      _config = config;
      _loading = false;
    });
  }

  /// (Re)arms the auto-fallback manager for the transport just created for
  /// [config]. Widget tests inject a fake client and no Transport is
  /// registered, so nothing is armed there.
  void _reattachFallback(PairConfig config) {
    if (getIt.isRegistered<Transport>()) {
      final transport = getIt<Transport>();
      if (_fallbackManager == null) {
        _fallbackManager = ConnectionFallbackManager(
          transport: transport,
          config: config,
          onFallback: _onAutoFallback,
        );
      } else {
        // Keep the same manager so the set of already-failed modes survives
        // the reconnect; otherwise an outage would bounce between the first
        // two dead endpoints and never reach funnel/gateway.
        _fallbackManager!.attach(transport, config);
      }
    } else {
      _fallbackManager?.dispose();
      _fallbackManager = null;
    }
  }

  /// Applies a candidate config from [ConnectionFallbackManager]: tell the
  /// user, remember the new endpoint set, and reconnect (which re-arms the
  /// manager for the next hop).
  Future<void> _onAutoFallback(PairConfig config) async {
    final nav = _navKey.currentContext;
    if (nav != null) {
      ScaffoldMessenger.of(nav).showSnackBar(
        SnackBar(
          content: Text('Relay unreachable — switched to ${config.mode} automatically'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    try {
      await getIt<ConfigStore>().saveProfile(config);
      await _setConfig(config);
    } catch (_) {
      // Save or reconnect failed; the current transport's own reconnect loop
      // keeps retrying the original endpoint, so nothing is lost.
    }
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
      // No profile left: disarm the fallback manager, otherwise it would keep
      // retrying the now-forgotten relay's endpoints in the background.
      _fallbackManager?.dispose();
      _fallbackManager = null;
      setState(() => _config = null);
    } else {
      await _setConfig(next);
    }
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

  /// Opens the Connection screen: status, mode, saved devices, pair entry.
  Future<void> _openConnection() async {
    final config = _config;
    if (config == null) return;
    await _navKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectionPage(
          config: config,
          onSwitch: _switchTo,
          onForgetActive: _forgetActive,
          onLink: (link) => _applyLink(Uri.parse(link)),
        ),
      ),
    );
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
        onRequestSwitch: _openConnection,
        onAddDevice: _showAddDevice,
        onForgetDevice: _forgetActive,
        onModeSelected: _switchTo,
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
