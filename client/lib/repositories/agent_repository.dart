import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../services/app_settings.dart';
import '../services/relay_client.dart';

/// Repository for agent operations
/// Provides typed interface over RelayClient
class AgentRepository {
  final RelayClient _client;
  final AppSettings _settings;

  /// JSON of the last cached snapshot — snapshots that did not change skip the
  /// disk write (status bursts can trigger many refreshes per second).
  String? _lastCachedJson;

  /// In-memory cache of the last fetched output per pane (id -> text+revision).
  /// A live refresh whose revision matches what we already hold skips the RPC
  /// entirely (docs/14-terminal-stream-implementation-plan.md §2.4).
  final Map<String, _CachedOutput> _outputCache = {};

  AgentRepository(this._client, this._settings);

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
    final raw = _settings.agentSnapshotAt;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> _cacheAgents(List<RelayAgent> agents) async {
    final json = jsonEncode([for (final a in agents) a.toJson()]);
    if (json == _lastCachedJson) return; // unchanged snapshot: skip the write
    _lastCachedJson = json;
    _settings.setAgentSnapshot(json);
    _settings.setAgentSnapshotAt(DateTime.now().toIso8601String());
  }

  Future<List<RelayAgent>> _loadCachedAgents() async {
    final raw = _settings.agentSnapshot;
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

  /// Get agent output.
  ///
  /// When [knownRevision] matches the revision of the last fetched output, the
  /// cached text is returned without an RPC (the pane has not changed since).
  Future<String> getOutput(String agentId,
      {int lines = 500, int? knownRevision}) async {
    final cached = _outputCache[agentId];
    if (knownRevision != null &&
        cached != null &&
        cached.revision == knownRevision) {
      return cached.text;
    }
    final result = await _client.output(agentId, lines: lines, format: 'ansi');
    _outputCache[agentId] = _CachedOutput(result.text, result.revision);
    return result.text;
  }

  /// Get a plain-terminal pane output (pane.read — no agent needed).
  Future<String> getPaneOutput(String paneId,
      {int lines = 500, int? knownRevision}) async {
    final cached = _outputCache[paneId];
    if (knownRevision != null &&
        cached != null &&
        cached.revision == knownRevision) {
      return cached.text;
    }
    final result = await _client.paneOutput(paneId, lines: lines, format: 'ansi');
    _outputCache[paneId] = _CachedOutput(result.text, result.revision);
    return result.text;
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

/// One entry of [AgentRepository]'s output cache: the last fetched text plus
/// the revision it corresponds to.
class _CachedOutput {
  _CachedOutput(this.text, this.revision);

  final String text;
  final int revision;
}
