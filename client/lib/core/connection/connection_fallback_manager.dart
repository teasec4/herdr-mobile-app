import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/pair_config.dart';
import '../transport/transport.dart';

/// Watches the active [Transport] and, when the current mode stays
/// unreachable, falls back to another saved endpoint
/// (docs/AUTO_MODE_SWITCHING_PLAN.md, Phase 2).
///
/// The manager deliberately does **not** touch [ConfigStore] or the UI: it
/// only reports a candidate config via [onFallback] and lets the app layer
/// decide how to persist/apply it. This keeps the class unit-testable without
/// SharedPreferences or widgets.
///
/// Behavior is built for the real world (leaving home / riding the metro):
///
/// 1. **A single drop is absorbed by the transport's own reconnect loop.** A
///    mode switch is only considered after [switchAfterFailures] consecutive
///    failures (a dropped connection or a failed reconnect attempt each count
///    as one). A slow-but-live handshake over Tailscale on cellular is never
///    interrupted by a switch racing the reconnect.
/// 2. **Recently-dead modes are remembered.** A mode we switch away from is
///    not proposed again for [deadModeTtl], so a metro ride does not bounce
///    LAN↔Tailscale on every outage: once LAN went dark here it stays dark
///    until the deadline expires or it connects again.
/// 3. **Dead zones self-heal to the last-good mode.** When every alternative
///    is dead or unknown, the manager falls back to the config that last
///    connected — or, before anything connected this process (a cold start
///    straight into a dead zone), to the mode the app booted into — instead of
///    stranding the app on an endpoint that never worked. That mode's own
///    reconnect loop picks the session back up as soon as the outage ends
///    (e.g. the Tailscale tunnel recovers mid-ride).
///
/// The app reconnects after [onFallback] and re-attaches via [attach]; the
/// failure memory is kept across those reconnects so one outage walks the
/// whole priority list once instead of bouncing between two dead endpoints.
class ConnectionFallbackManager {
  ConnectionFallbackManager({
    required Transport transport,
    required PairConfig config,
    required this.onFallback,
    this.switchAfterFailures = 2,
    this.deadModeTtl = const Duration(minutes: 10),
    List<String>? modePriority,
  }) : _modePriority = modePriority ?? _defaultModePriority {
    attach(transport, config);
  }

  static const List<String> _defaultModePriority = [
    'tailscale',
    'lan',
    'funnel',
    'gateway',
  ];

  /// Called with the next candidate [PairConfig] when the current mode fails.
  /// The app reconnects over it and re-attaches via [attach].
  final Future<void> Function(PairConfig config) onFallback;

  /// How many consecutive failures must accumulate before a mode switch is
  /// considered. A dropped connection and each failed reconnect attempt count
  /// as one failure; a successful connect resets the counter.
  final int switchAfterFailures;

  /// How long a mode stays "recently dead" after a failed switch away from it.
  final Duration deadModeTtl;

  final List<String> _modePriority;

  /// The transport currently being watched; swapped by [attach] whenever the
  /// app brings up a new transport for a new config.
  Transport? _transport;

  /// Config of the mode currently being watched; updated by [attach] and
  /// advanced to the next mode before each [onFallback] call.
  late PairConfig _config;

  /// Consecutive failures since the last successful connect (or the last
  /// switch attempt). Reset on every connect.
  int _failures = 0;

  /// True while [onFallback] is being applied: status events during that gap
  /// (the old transport is being torn down) must not schedule a second switch
  /// on top of the first. Cleared by [attach] or on a failed app handler.
  bool _switching = false;

  /// Modes that failed recently and are not proposed again until the stored
  /// deadline. Checked lazily on every candidate walk.
  final Map<String, DateTime> _deadUntil = {};

  /// The config that was actually connected most recently — the preferred
  /// revert target when every alternative is dead or unknown, so the app is
  /// not stranded on an endpoint that never worked.
  PairConfig? _lastConnectedConfig;

  /// The mode the app booted into (or the user manually switched to): the
  /// fallback revert target when nothing has connected yet in this process
  /// (e.g. a cold start straight into a dead zone).
  PairConfig? _anchorConfig;

  /// True while an auto-switch ([onFallback]) is being applied; the attach
  /// that follows is the app reconnecting over our proposal, so it must NOT
  /// move [_anchorConfig].
  bool _autoSwitchPending = false;

  /// Starts (or restarts) watching [transport] for [config], cancelling any
  /// pending state of the previous transport.
  void attach(Transport transport, PairConfig config) {
    _transport?.status.removeListener(_onStatusChanged);
    _transport = transport;
    _config = config;
    _switching = false;
    if (!_autoSwitchPending) {
      // Boot or user-initiated attach: this is the mode the app wants right
      // now — anchor dead-zone reverts to it. Attaches that follow our own
      // auto-switch proposal keep the original anchor.
      _anchorConfig = config;
    }
    _autoSwitchPending = false;
    // A device switch (another relay) must not be pulled back to the previous
    // device's last-good mode by the revert logic.
    if (_lastConnectedConfig != null &&
        !_sameDevice(_lastConnectedConfig!, config)) {
      _lastConnectedConfig = null;
    }
    transport.status.addListener(_onStatusChanged);
    if (transport.status.value == ConnectionStatus.connected) {
      // Fresh transport already up (e.g. a manual switch over a working mode,
      // or a very fast connect): reset the failure state immediately and
      // remember this config as last-good — otherwise the stale failure
      // counter from the previous transport would trigger an instant switch.
      _onConnected();
    }
  }

  void _onStatusChanged() {
    final transport = _transport;
    if (transport == null) return;
    final status = transport.status.value;
    if (status == ConnectionStatus.connected) {
      _onConnected();
    } else if (status == ConnectionStatus.disconnected && !_switching) {
      // A dropped connection or a failed reconnect attempt both surface as
      // "disconnected" (the transport reports disconnected after each failed
      // handshake). Count them; only act once the current mode has failed
      // enough times that a switch is clearly better than waiting for the
      // next reconnect attempt.
      _failures++;
      if (_failures >= switchAfterFailures) {
        _failures = 0;
        // ignore: unawaited_futures
        _trySwitch();
      }
    }
    // connecting: an attempt is in flight — wait for its outcome.
  }

  /// Back online over the current mode: it demonstrably works again, so reset
  /// the failure counter and forget any recent-failure memory for it.
  void _onConnected() {
    _failures = 0;
    _lastConnectedConfig = _config;
    _deadUntil.remove(_config.mode);
  }

  Future<void> _trySwitch() async {
    final transport = _transport;
    if (transport == null || _switching) return;
    // The connection may have recovered while events were settling.
    if (transport.status.value == ConnectionStatus.connected) return;

    final candidate = _findCandidate();
    if (candidate != null) {
      // Leaving the current mode because it failed: do not bounce back into
      // it until the dead-mode memory expires.
      _markDead(_config.mode);
      final endpoint = _config.endpointFor(candidate);
      if (endpoint == null) return;
      await _switchTo(_config.connectVia(candidate, endpoint));
      return;
    }

    // Every alternative is dead or unknown. Do not strand the app on the
    // current (failing) endpoint: go back to the last mode that actually
    // connected — or, if nothing has connected yet in this process (cold start
    // straight into a dead zone), back to the mode the app booted into. That
    // mode's own reconnect loop reconnects as soon as the dead zone ends.
    final revertTo = _lastConnectedConfig ?? _anchorConfig;
    if (revertTo != null &&
        _sameDevice(revertTo, _config) &&
        revertTo.mode != _config.mode) {
      _markDead(_config.mode);
      await _switchTo(revertTo);
    }
  }

  /// True when both configs describe the same relay machine (by stable
  /// [PairConfig.relayId]). Legacy profiles carry no identity, so two configs
  /// without a relayId are assumed to be the same device — mode switches of
  /// one legacy relay swap hostnames, which is indistinguishable from a device
  /// switch without the relayId.
  bool _sameDevice(PairConfig a, PairConfig b) {
    if (a.relayId != null || b.relayId != null) return a.relayId == b.relayId;
    return true;
  }

  /// First mode in [_modePriority] that is not the current one, was not marked
  /// dead recently, and has a saved endpoint.
  String? _findCandidate() {
    final now = DateTime.now();
    _deadUntil.removeWhere((mode, until) => !until.isAfter(now));
    for (final mode in _modePriority) {
      if (mode == _config.mode) continue;
      final until = _deadUntil[mode];
      if (until != null && until.isAfter(now)) continue;
      if (_config.endpointFor(mode) != null) return mode;
    }
    return null;
  }

  void _markDead(String mode) {
    _deadUntil[mode] = DateTime.now().add(deadModeTtl);
  }

  Future<void> _switchTo(PairConfig config) async {
    if (_switching) return;
    _switching = true;
    _autoSwitchPending = true;
    _config = config;
    try {
      await onFallback(config);
    } catch (e) {
      // The app-layer handler failed (e.g. its own setup threw). Never let the
      // error escape into an unhandled async failure: the current transport
      // keeps its own reconnect loop running, and a later status change will
      // schedule a fresh switch attempt.
      debugPrint('ConnectionFallbackManager: fallback to ${config.mode} failed: $e');
      _switching = false;
      _autoSwitchPending = false;
    }
    // On success the app brings up a fresh transport and calls [attach], which
    // clears [_switching] and re-arms the watcher for the new mode.
  }

  void dispose() {
    _transport?.status.removeListener(_onStatusChanged);
    _transport = null;
  }
}
