import 'package:flutter/foundation.dart';

import '../core/connection/connection_fallback_manager.dart';
import '../core/service_locator.dart';
import '../core/transport/transport.dart';
import '../models/pair_config.dart';
import '../services/config_store.dart';
import '../services/notification_service.dart';
import '../services/relay_client.dart';

/// Root app session: which pair config is active and the lifecycle of the
/// relay services backing it.
///
/// Owns the orchestration that used to live in [_HerdrMobileAppState]:
///   - [setConfig] runs the full teardown→setup cycle exactly once, serialized
///     (a config arriving while a cycle is in flight is queued and applied
///     right after — last one wins), so two set-ups never interleave on the
///     service locator (docs/plan doctor-fate…, Critical 2+3);
///   - every applied change bumps [version], which pages use to detect that the
///     relay services were recreated and their cached getIt references are
///     stale — they pop/recreate instead of talking to disposed objects;
///   - it owns the [ConnectionFallbackManager] (auto-switch to another saved
///     endpoint when the current mode becomes unreachable) and re-arms it on
///     every config change;
///   - it is registered globally in [setupDependencies], so it survives relay
///     teardown and is the stable home of fallback/notification wiring.
class AppSessionController extends ChangeNotifier {
  /// Injectable for tests; defaults to the production WS relay client.
  ///
  /// Set by the app before [bootstrap] runs; used for every [setConfig] call
  /// that does not pass its own factory.
  RelayClient Function(PairConfig config)? clientFactory;

  /// Opens an agent pane from a notification tap; wired by the app layer so
  /// notifications keep working across config switches.
  Future<void> Function(String paneId)? onOpenAgent;

  /// Shows the "relay unreachable — switched to mode X" snackbar; wired by the
  /// app layer (needs a BuildContext).
  void Function(PairConfig config)? onAutoFallback;

  final _configStore = getIt<ConfigStore>();

  PairConfig? _config;
  int _version = 0;
  bool _busy = false;
  Future<void> Function()? _queuedAction;

  /// Watches the live transport and auto-switches to another saved endpoint
  /// when the current mode becomes unreachable. Re-armed via
  /// [_reattachFallback] on every config change.
  ConnectionFallbackManager? _fallbackManager;
  bool _disposed = false;

  /// Mode currently stored for the active profile. Persistence follows
  /// reality: a mode is written to [ConfigStore] only after a real connect, so
  /// the profile never points at an endpoint that the fallback manager merely
  /// *proposed* and that never answered (e.g. LAN while away from home).
  String? _persistedMode;

  /// The relay client whose status is watched to persist the mode on connect.
  RelayClient? _watchedClient;

  /// The currently active pair, or null when the app is unpaired.
  PairConfig? get config => _config;

  /// Bumped every time a config change was applied (services were recreated).
  /// Pages compare it against the value at open time to detect staleness.
  int get version => _version;

  /// The relay client registered for the active config, or null when the app
  /// is unpaired. Pages resolve the client through the session instead of
  /// asking getIt directly, so a config switch (which tears down and recreates
  /// the client) is always observed from the same place.
  RelayClient? get liveClient =>
      getIt.isRegistered<RelayClient>() ? getIt<RelayClient>() : null;

  /// Cold start: restore the previously active profile (if any). Returns
  /// without doing anything when no profile is saved.
  Future<void> bootstrap() async {
    final config = await _configStore.loadActive();
    if (config == null) return;
    // The loaded profile is by definition what the store holds: seed the
    // persisted-mode marker so a plain cold-start connect does not rewrite it.
    _persistedMode = config.mode;
    await setConfig(config);
  }

  /// Replaces the active pair: closes the old relay and brings up a new one.
  ///
  /// Serialized: concurrent callers each run the full teardown→setup cycle; a
  /// config that arrives while a cycle is in flight is queued and applied right
  /// after (last one wins).
  Future<void> setConfig(
    PairConfig config, {
    RelayClient Function(PairConfig)? clientFactory,
  }) {
    return _run(() => _applyConfig(config, clientFactory: clientFactory));
  }

  /// Unpairs: closes every relay service and returns the app to the scanner.
  Future<void> clear() => _run(_clearLocked);

  /// Forgets the active relay: closes the client and either returns to the
  /// scanner (no profiles left) or reconnects to the next active profile.
  Future<void> forgetActive() {
    return _run(() async {
      final active = _config;
      if (active != null) await _configStore.forget(active.profileKey);
      final next = await _configStore.loadActive();
      if (next == null) {
        // No profile left: disarm the fallback manager, otherwise it would keep
        // retrying the now-forgotten relay's endpoints in the background.
        await _clearLocked();
      } else {
        await _applyConfig(next);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _detachClientStatusListener();
    _disarmFallback();
    super.dispose();
  }

  /// Runs [action] as the only teardown→setup cycle in flight. A new call while
  /// one is running is remembered and runs right after — the last one wins
  /// ([clear] queued late overrides an earlier [setConfig]).
  ///
  /// [_busy] stays true for the whole drain, so a call that lands while a
  /// queued action is executing still queues instead of starting a second
  /// concurrent cycle.
  Future<void> _run(Future<void> Function() action) {
    if (_busy) {
      _queuedAction = action;
      return Future<void>.value();
    }
    _busy = true;
    return _drain(action);
  }

  Future<void> _drain(Future<void> Function() first) async {
    try {
      Future<void> Function()? action = first;
      while (action != null) {
        await action();
        // Pick up whatever was queued while [action] ran; a single slot keeps
        // last-one-wins semantics (the newest request overwrites older ones).
        action = _queuedAction;
        _queuedAction = null;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _applyConfig(
    PairConfig config, {
    RelayClient Function(PairConfig)? clientFactory,
  }) async {
    _detachClientStatusListener();
    await teardownRelayServices();
    await setupRelayServices(config, clientFactory: clientFactory ?? this.clientFactory);
    // Notification taps (and cold-start launches) open the agent pane; the
    // listener survives relay teardown, so re-wire it onto the fresh service.
    getIt<NotificationService>().onOpenAgent = onOpenAgent;
    _reattachFallback(config);
    _setActive(config);
    // Persist the mode once it actually connects (a fallback candidate that
    // never connects must not become the stored profile mode).
    _attachClientStatusListener();
  }

  Future<void> _clearLocked() async {
    _detachClientStatusListener();
    await teardownRelayServices();
    _disarmFallback();
    _setActive(null);
  }

  void _setActive(PairConfig? config) {
    _config = config;
    _version++;
    if (!_disposed) notifyListeners();
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
      _disarmFallback();
    }
  }

  void _disarmFallback() {
    _fallbackManager?.dispose();
    _fallbackManager = null;
  }

  /// Applies a candidate config from [ConnectionFallbackManager]: tell the
  /// user and reconnect (which re-arms the manager for the next hop). The
  /// profile is deliberately NOT rewritten here — a fallback candidate may be
  /// unreachable (LAN while away), so the mode is only persisted once it
  /// actually connects ([_onRelayClientStatus]).
  Future<void> _onAutoFallback(PairConfig config) async {
    onAutoFallback?.call(config);
    try {
      await setConfig(config);
    } catch (_) {
      // Reconnect failed; the current transport's own reconnect loop keeps
      // retrying the original endpoint, so nothing is lost.
    }
  }

  /// Watches the client that was just set up: the active mode is persisted
  /// only once the relay is really reachable over it, so a cold start never
  /// resumes on an endpoint the app could not reach when it last connected.
  void _attachClientStatusListener() {
    if (getIt.isRegistered<RelayClient>()) {
      _watchedClient = getIt<RelayClient>();
      _watchedClient!.status.addListener(_onRelayClientStatus);
      // The client may already be connected (fast connect while services were
      // being set up): persist now instead of waiting for an event.
      _onRelayClientStatus();
    }
  }

  void _detachClientStatusListener() {
    _watchedClient?.status.removeListener(_onRelayClientStatus);
    _watchedClient = null;
  }

  void _onRelayClientStatus() {
    final client = _watchedClient;
    final config = _config;
    if (client == null || config == null) return;
    if (client.status.value != RelayStatus.connected) return;
    if (config.mode == _persistedMode) return;
    _persistedMode = config.mode;
    // Fire-and-forget: persistence is best-effort and must not stall anything.
    // ignore: unawaited_futures
    _configStore.saveProfile(config);
  }
}
