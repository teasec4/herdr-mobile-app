import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../services/relay_client.dart';

/// Repository for agent operations
/// Provides typed interface over RelayClient
class AgentRepository {
  /// Cache key for the last successful agent snapshot, shown when the relay is
  /// offline so the user still sees the last known agent list.
  static const String _cacheKey = 'last_snapshot';

  final RelayClient _client;
  final SharedPreferences _prefs;

  AgentRepository(this._client, this._prefs);

  /// Get all agents snapshot.
  ///
  /// On success the result is cached; on failure the last cached snapshot is
  /// returned (with its timestamp) so an offline relay shows stale-but-useful
  /// data instead of an empty error screen. Rethrows only when no cache exists.
  Future<List<RelayAgent>> getAgents() async {
    try {
      final agents = await _client.snapshot();
      await _cacheAgents(agents);
      return agents;
    } catch (_) {
      final cached = await _loadCachedAgents();
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  /// When the last successful snapshot was cached (null if never).
  Future<DateTime?> lastCachedAt() async {
    final raw = _prefs.getString('$_cacheKey:ts');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> _cacheAgents(List<RelayAgent> agents) async {
    await _prefs.setString(
      _cacheKey,
      jsonEncode([for (final a in agents) a.toJson()]),
    );
    await _prefs.setString(
      '$_cacheKey:ts',
      DateTime.now().toIso8601String(),
    );
  }

  Future<List<RelayAgent>> _loadCachedAgents() async {
    final raw = _prefs.getString(_cacheKey);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => RelayAgent.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt cache: drop it rather than crashing.
      return const [];
    }
  }

  /// Get agent output
  Future<String> getOutput(String agentId, {int lines = 500}) async {
    return await _client.output(agentId, lines: lines, format: 'ansi');
  }

  /// Send prompt to agent
  Future<void> sendPrompt(String agentId, String text) async {
    await _client.prompt(agentId, text);
  }

  /// Send literal text into a plain terminal pane.
  Future<void> sendText(String paneId, String text) async {
    await _client.sendText(paneId, text);
  }

  /// Send keys to agent
  Future<void> sendKeys(String agentId, List<String> keys) async {
    await _client.keys(agentId, keys);
  }

  /// Stream of typed events
  Stream<RelayEvent> get events => _client.events;

  /// Connection status
  ValueNotifier<RelayStatus> get status => _client.status;

  /// Close connection
  Future<void> close() async {
    await _client.close();
  }
}
