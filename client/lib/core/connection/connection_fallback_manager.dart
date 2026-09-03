import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/pair_config.dart';
import '../transport/transport.dart';

/// Watches the active [Transport] and, when the current mode becomes
/// unreachable, automatically retries over the other saved endpoints
/// (docs/AUTO_MODE_SWITCHING_PLAN.md, Phase 2).
///
/// Priority order defaults to tailscale → lan → funnel → gateway: when the
/// user leaves home the LAN goes dark and the app retries over Tailscale (or
/// Funnel) using endpoints the profile already remembers — no re-scanning, no
/// manual switch.
///
/// The manager deliberately does **not** touch [ConfigStore] or the UI: it
/// only reports a candidate config via [onFallback] and lets the app layer
/// decide how to persist/apply it. This keeps the class unit-testable without
/// SharedPreferences or widgets.
///
/// One fallback attempt is scheduled per outage (when the status first leaves
/// `connected`). On success the app brings up a fresh transport for the new
/// config and calls [attach]; the set of already-failed modes is kept across
/// those reconnects, so a single outage walks the whole priority list once
/// instead of bouncing between the first two dead endpoints.
class ConnectionFallbackManager {
  ConnectionFallbackManager({
    required Transport transport,
    required PairConfig config,
    required this.onFallback,
    this.fallbackDelay = const Duration(seconds: 8),
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
  /// The app persists it, reconnects, and re-attaches via [attach].
  final Future<void> Function(PairConfig config) onFallback;

  /// How long to wait after the connection drops before trying another mode
  /// (short enough not to stall the user, long enough to absorb a flaky drop).
  final Duration fallbackDelay;

  final List<String> _modePriority;

  /// The transport currently being watched; swapped by [attach] whenever the
  /// app brings up a new transport for a new config.
  Transport? _transport;

  /// Config of the mode currently being watched; updated by [attach] and
  /// advanced to the next mode before each [onFallback] call.
  late PairConfig _config;

  /// Modes already tried during the current outage, so a loop does not retry
  /// the same dead endpoint forever.
  final Set<String> _failedModes = {};
  Timer? _fallbackTimer;

  /// Starts (or restarts) watching [transport] for [config], cancelling any
  /// pending attempt that was scheduled for the previous transport.
  void attach(Transport transport, PairConfig config) {
    _transport?.status.removeListener(_onStatusChanged);
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _transport = transport;
    _config = config;
    transport.status.addListener(_onStatusChanged);
    if (transport.status.value == ConnectionStatus.connected) {
      // Fresh transport already up (e.g. after a manual switch): start with a
      // clean slate.
      _failedModes.clear();
    } else {
      // Already offline at attach: start the first fallback countdown instead
      // of waiting for a status change that never comes.
      _scheduleFallback();
    }
  }

  void _onStatusChanged() {
    final transport = _transport;
    if (transport == null) return;
    if (transport.status.value == ConnectionStatus.connected) {
      // Back online: the current mode works again, reset the fallback state.
      _failedModes.clear();
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
    } else if (_fallbackTimer == null) {
      // disconnected / connecting: plan one attempt. Later status updates
      // while the timer is pending must not stack additional attempts.
      _scheduleFallback();
    }
  }

  void _scheduleFallback() {
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(fallbackDelay, () {
      _fallbackTimer = null;
      _tryFallback();
    });
  }

  Future<void> _tryFallback() async {
    final transport = _transport;
    if (transport == null) return;
    // The connection may have recovered while the timer was pending.
    if (transport.status.value == ConnectionStatus.connected) return;

    _failedModes.add(_config.mode);
    final next = _findNextMode();
    if (next == null) {
      // Every known mode failed: reset so the next outage starts a fresh
      // priority walk, and stay on the current mode (its reconnect loop
      // keeps trying on its own).
      _failedModes.clear();
      return;
    }
    final endpoint = _config.endpointFor(next);
    if (endpoint == null) {
      _failedModes.clear();
      return;
    }
    _config = _config.connectVia(next, endpoint);
    try {
      await onFallback(_config);
    } catch (e) {
      // The app-layer handler failed (e.g. its own setup threw). Never let the
      // error escape into the timer's zone as an unhandled async failure: the
      // current transport keeps its own reconnect loop running, and a later
      // status change will schedule a fresh fallback attempt.
      debugPrint('ConnectionFallbackManager: fallback to $next failed: $e');
    }
  }

  /// First mode in [_modePriority] that is not the current one, was not tried
  /// yet, and has a saved endpoint.
  String? _findNextMode() {
    for (final mode in _modePriority) {
      if (_failedModes.contains(mode)) continue;
      if (mode == _config.mode) continue;
      if (_config.endpointFor(mode) != null) return mode;
    }
    return null;
  }

  void dispose() {
    _transport?.status.removeListener(_onStatusChanged);
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }
}
