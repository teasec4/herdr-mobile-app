import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import 'config_store.dart';
import 'notification_api.dart';

/// Background blocked-agent watch (Android WorkManager).
///
/// The live WebSocket path ([NotificationService]) notifies instantly while
/// the app process is alive, but the OS can suspend or kill the app after
/// long background periods. This periodic task (WorkManager floor: 15 min)
/// re-checks the relay snapshot from a background isolate and posts a local
/// notification for agents that became blocked meanwhile — so "agent stuck
/// waiting on me" is not silently lost overnight.
///
/// Unlike the foreground path this works over plain HTTP (relay RPC), which a
/// background isolate can reach — no in-process tunnel required.
///
/// Suppression:
///  - while the app is foregrounded/active the foreground writes a heartbeat;
///    a fresh heartbeat makes the task a no-op (the WS path already covers it);
///  - per-pane dedup via a persisted "seen blocked" set — a pane notifies once
///    per blocked episode, and re-notifies only after it left the blocked state.

const String backgroundTaskUniqueName = 'herdrelay.blocked-watch';
const String backgroundTaskName = 'blockedWatch';
const Duration backgroundWatchFrequency = Duration(minutes: 15);

const String _seenKey = 'blocked_seen_v1';
const String _heartbeatKey = 'blocked_fg_heartbeat';

/// While the foreground heartbeat is fresher than this, the background task
/// stays quiet (the app is in active use and the WS path handles blocking).
const Duration heartbeatFreshWindow = Duration(seconds: 60);

bool _registered = false;

// ── Pure logic (unit-tested) ───────────────────────────────────────────────

/// Blocked agents the user has not been notified about yet.
List<RelayAgent> newlyBlocked(List<RelayAgent> agents, Set<String> seen) {
  return [
    for (final agent in agents)
      if (agent.isBlocked && !seen.contains(agent.id)) agent,
  ];
}

/// Next seen set: every currently blocked pane id. Panes that left the
/// blocked state drop out so a future blocked episode notifies again.
Set<String> nextSeen(List<RelayAgent> agents) => {
      for (final agent in agents)
        if (agent.isBlocked) agent.id,
    };

/// True when [heartbeatMs] (epoch ms written by the foreground) is fresh
/// enough to suppress the background task.
bool heartbeatFresh(int nowMs, int? heartbeatMs,
    [Duration window = heartbeatFreshWindow]) {
  if (heartbeatMs == null) return false;
  return nowMs - heartbeatMs < window.inMilliseconds;
}

// ── Persistence helpers (SharedPreferences) ───────────────────────────────

Future<Set<String>> readSeen(SharedPreferences prefs) async {
  final raw = prefs.getString(_seenKey);
  if (raw == null || raw.isEmpty) return <String>{};
  try {
    return (jsonDecode(raw) as List<dynamic>).map((e) => e.toString()).toSet();
  } catch (_) {
    return <String>{};
  }
}

Future<void> writeSeen(SharedPreferences prefs, Set<String> seen) =>
    prefs.setString(_seenKey, jsonEncode(seen.toList()));

/// Foreground activity marker; see [heartbeatFresh].
Future<void> touchForegroundHeartbeat() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _heartbeatKey, DateTime.now().millisecondsSinceEpoch);
  } catch (_) {
    // Non-fatal: worst case the background task re-notifies conservatively.
  }
}

// ── Registration (foreground) ─────────────────────────────────────────────

/// Registers the periodic background task. Idempotent per process; no-op on
/// the web (the WorkManager platform implementation only covers Android; the
/// Apple/Linux implementations do not support periodic tasks).
Future<void> registerBackgroundWatch() async {
  if (kIsWeb || _registered) return;
  _registered = true;
  try {
    await Workmanager()
        .initialize(blockedWatchDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundTaskUniqueName,
      backgroundTaskName,
      frequency: backgroundWatchFrequency,
    );
  } catch (_) {
    _registered = false; // let a later call retry
  }
}

/// Removes the periodic background task (notifications disabled).
Future<void> cancelBackgroundWatch() async {
  if (kIsWeb) return;
  _registered = false;
  try {
    await Workmanager().cancelByUniqueName(backgroundTaskUniqueName);
  } catch (_) {
    // The task may already be gone (fresh install / unsupported platform).
  }
}

// ── Background task ───────────────────────────────────────────────────────

@pragma('vm:entry-point')
void blockedWatchDispatcher() {
  Workmanager().executeTask((task, inputData) => _runBackgroundWatch());
}

Future<bool> _runBackgroundWatch() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final heartbeat =
        prefs.getInt(_heartbeatKey);
    if (heartbeatFresh(DateTime.now().millisecondsSinceEpoch, heartbeat)) {
      return true; // app in active use — foreground WS path is live
    }
    final config = await ConfigStore().loadActive();
    if (config == null) return true; // nothing paired
    final agents = await _fetchAgents(config);
    final blocked = [
      for (final agent in agents)
        if (agent.isBlocked) agent,
    ];
    if (blocked.isEmpty) return true;

    final seen = await readSeen(prefs);
    final fresh = newlyBlocked(blocked, seen);
    if (fresh.isEmpty) return true;

    // The background isolate needs its own plugin session for the local
    // notifications plugin; failures here are swallowed so a transient
    // platform issue never fails the worker (next run retries).
    final api = LocalNotificationsApi();
    await api.init(onTap: (_) {});
    for (final agent in fresh) {
      await api.showBlocked(agent.id, agent.agent);
    }
    await writeSeen(prefs, nextSeen(blocked));
  } catch (_) {
    // Network down, relay unreachable, corrupt state: stay quiet and retry on
    // the next scheduled run.
  }
  return true;
}

/// One-shot `agents.snapshot` over the relay HTTP RPC — the background
/// twin of `RelayClient.snapshot()` (which needs a live transport).
Future<List<RelayAgent>> _fetchAgents(PairConfig config) async {
  final response = await http
      .post(
        config.httpBaseUri.replace(path: '/api/rpc'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.token}',
        },
        body: jsonEncode({
          'type': 'request',
          'id': 1,
          'method': 'agents.snapshot',
          'params': <String, dynamic>{},
        }),
      )
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) return const [];
  final decoded = jsonDecode(response.body);
  final result = decoded is Map ? decoded['result'] : null;
  final agents = (result is Map ? result['agents'] : null) ??
      (decoded is Map ? decoded['agents'] : null);
  if (agents is! List) return const [];
  return [
    for (final raw in agents)
      if (raw is Map)
        RelayAgent.fromJson(raw.cast<String, dynamic>()),
  ];
}
