import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controllers/agents_store.dart';
import 'controllers/app_session_controller.dart';
import 'core/service_locator.dart';
import 'models/pair_config.dart';
import 'pages/agent_page.dart';
import 'pages/connection_page.dart';
import 'pages/home_page.dart';
import 'pages/pair_page.dart';
import 'services/config_store.dart';
import 'services/notification_api.dart';
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
  runApp(const HerdrMobileApp());
}

class HerdrMobileApp extends StatefulWidget {
  const HerdrMobileApp({super.key, this.clientFactory});

  /// Relay client factory: [WsRelayClient] in production, a fake in tests.
  final RelayClient Function(PairConfig config)? clientFactory;

  @override
  State<HerdrMobileApp> createState() => _HerdrMobileAppState();
}

class _HerdrMobileAppState extends State<HerdrMobileApp> {
  /// Root navigator so profile/add-device screens can be pushed on top of
  /// HomePage and popped from outside (e.g. in deep-link handlers).
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  /// Root app session: owns which config is active, serializes config switches
  /// (teardown→setup), and publishes [AppSessionController.version] so pages
  /// recreate when the relay services behind them change. The app state only
  /// wires its UI-facing callbacks onto it and mirrors its config in `build`.
  late final AppSessionController _session;

  bool _loading = true;

  /// Deep-link stream subscription; cancelled in [dispose] so the handler is
  /// never invoked after teardown.
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _session = getIt<AppSessionController>();
    // UI-facing wiring that needs BuildContext/navigator lives here; the
    // controller calls it when a notification is tapped or a fallback fires.
    _session.clientFactory = widget.clientFactory;
    _session.onOpenAgent = _openAgentFromNotification;
    _session.onAutoFallback = _showFallbackSnackBar;
    _bootstrap();
    _listenDeepLinks();
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    // The session is a global getIt singleton (survives relay teardown); the
    // container owns its lifecycle, not the root widget — which is never
    // disposed during a real app run anyway.
    teardownRelayServices();
    super.dispose();
  }

  /// Cold start: restore the active relay (if any) and drop the splash screen.
  ///
  /// The splash must never stick. Whatever happens below — a storage error, a
  /// hung restore, an exception anywhere in the session — the app always lands
  /// on a real screen: HomePage (which shows the connection gate when the relay
  /// is unreachable) when a config is active, the scanner otherwise. Both the
  /// try/catch and the deadline guarantee this: a thrown error cannot leave
  /// `_loading` true forever, and neither can a future that never completes.
  Future<void> _bootstrap() async {
    try {
      await _session.bootstrap().timeout(
            const Duration(seconds: 15),
            // Safety net: even a hung restore must fall through to a screen.
            onTimeout: () {},
          );
    } catch (_) {
      // Restore/setup failure — fall through to the scanner or HomePage instead
      // of an endless spinner; the gate on HomePage surfaces unreachable relays.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    if (_session.config != null) {
      try {
        await _handleNotificationLaunch();
      } catch (_) {
        // Notification launch is best-effort; a failure must not crash the app.
      }
    }
  }

  /// Cold-start path: the app was launched by tapping a notification. The
  /// services are up by now, so resolve the pane and push the agent page.
  Future<void> _handleNotificationLaunch() async {
    final details = await getIt<NotificationApi>().getLaunchDetails();
    if (details?.launchedFromNotification ?? false) {
      final paneId = details?.paneId;
      if (paneId != null) await _openAgentFromNotification(paneId);
    }
  }

  /// Opens the agent pane for a tapped notification. Uses the live store:
  /// on a cold start the first snapshot may still be loading, so refresh
  /// before looking the pane up.
  Future<void> _openAgentFromNotification(String paneId) async {
    final store = getIt<AgentsStore>();
    await store.refresh();
    final agent = store.byId(paneId);
    if (agent == null || !mounted) return;
    await _navKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => AgentPage(agent: agent)),
    );
  }

  /// Tells the user an auto-fallback switched the active mode (called by
  /// [AppSessionController] before it reconnects).
  void _showFallbackSnackBar(PairConfig config) {
    final nav = _navKey.currentContext;
    if (nav != null) {
      ScaffoldMessenger.of(nav).showSnackBar(
        SnackBar(
          content: Text('Relay unreachable — switched to ${config.mode} automatically'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Deep links `herdrelay://pair?...` (Android intent-filter / iOS
  /// URL scheme) let the app be reconfigured from a link — including via
  /// scanning a QR from another app.
  void _listenDeepLinks() {
    // Deep links are a nice-to-have, not a hard dependency: on platforms or
    // embeddings without the plugin (desktop/web/tests) a throwing AppLinks
    // must not take startup down with it.
    try {
      final appLinks = AppLinks();
      // Keep the subscription so it can be cancelled in dispose; the handler
      // swaps the active relay and must not run after teardown.
      _linkSub = appLinks.uriLinkStream.listen(_applyLink);
      appLinks.getInitialLink().then((uri) {
        if (uri != null) _applyLink(uri);
      }).catchError((_) {
        // deep links may be unsupported on desktop/web — not critical
      });
    } catch (_) {
      // Deep-link plugin unavailable — proceed without it.
    }
  }

  Future<void> _applyLink(Uri uri) async {
    if (uri.scheme != 'herdrelay') return;
    try {
      final config = PairConfig.fromUri(uri);
      // Upsert: re-pairing the same relay (same relayId) replaces the saved
      // profile instead of adding a duplicate.
      await getIt<ConfigStore>().saveProfile(config);
      await _session.setConfig(config);
    } on FormatException {
      // invalid link — ignore
    }
  }

  /// Makes the profile active and reconnects to it.
  Future<void> _switchTo(PairConfig config) async {
    await getIt<ConfigStore>().setActive(config.profileKey);
    await _session.setConfig(config);
  }

  /// Forgets the active relay (delegates to the session, which either returns
  /// to the scanner or reconnects to the next active profile).
  Future<void> _forgetActive() => _session.forgetActive();

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
    await _session.setConfig(config);
  }

  /// Opens the Connection screen: status, mode, saved devices, pair entry.
  Future<void> _openConnection() async {
    final config = _session.config;
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
    // The MaterialApp stays constant for the app's lifetime: its navigatorKey
    // keeps pushed routes (ConnectionPage, AgentPage, scanner) alive across
    // config switches. The root screen swaps inside `home` instead — a live
    // Navigator never replaces its own '/' route when MaterialApp.home is
    // mutated, which is exactly what used to leave the splash on screen after
    // bootstrap finished.
    return MaterialApp(
      navigatorKey: _navKey,
      title: 'Herdr Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _appRoot(),
    );
  }

  /// Root screen switcher: splash while bootstrapping, the scanner when there
  /// is no active relay, HomePage otherwise. HomePage is recreated whenever the
  /// session applies a change (its key includes profileKey + mode + version) so
  /// it never outlives the relay services it caches getIt references to.
  Widget _appRoot() {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final config = _session.config;
        if (config == null) {
          return PairPage(
            onPaired: (config) async {
              await getIt<ConfigStore>().saveProfile(config);
              await _session.setConfig(config);
            },
          );
        }
        return HomePage(
          key: ValueKey('${config.profileKey}:${config.mode}:${_session.version}'),
          config: config,
          onRequestSwitch: _openConnection,
          onAddDevice: _showAddDevice,
          onForgetDevice: _forgetActive,
          onModeSelected: _switchTo,
        );
      },
    );
  }
}
