import 'package:flutter/foundation.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../services/relay_client.dart' hide RelayEvent;

/// Repository for agent operations
/// Provides typed interface over RelayClient
class AgentRepository {
  final RelayClient _client;

  AgentRepository(this._client);

  /// Get all agents snapshot
  Future<List<RelayAgent>> getAgents() async {
    return await _client.snapshot();
  }

  /// Get agent output
  Future<String> getOutput(String agentId, {int lines = 500}) async {
    return await _client.output(agentId, lines: lines, format: 'ansi');
  }

  /// Send prompt to agent
  Future<void> sendPrompt(String agentId, String text) async {
    await _client.prompt(agentId, text);
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
