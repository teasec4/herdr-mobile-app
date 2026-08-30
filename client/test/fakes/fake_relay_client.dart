import 'dart:async';

import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/models/relay_session.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter/foundation.dart';

/// Fake relay client for widget tests: no network, controlled from the test.
///
/// Serves from preset fields and records calls (`prompts`, `keysCalls`) so
/// tests can verify the UI actually talks to the relay.
class FakeRelayClient implements RelayClient {
  @override
  final ValueNotifier<RelayStatus> status =
      ValueNotifier<RelayStatus>(RelayStatus.connected);

  final StreamController<RelayEvent> _eventsController = StreamController.broadcast();

  @override
  Stream<RelayEvent> get events => _eventsController.stream;

  /// Snapshot that `snapshot()` will return.
  List<RelayAgent> agents = const [];

  /// Session that `session()` will return (workspaces/panes).
  RelaySession sessionData = const RelaySession(
    workspaces: [],
    panes: [],
  );

  /// Text that `output()` returns for any agent.
  String outputText = '';

  /// When true, `snapshot()` throws [RelayException].
  bool snapshotError = false;

  /// Number of `session()` calls (reconnect tests).
  int sessionCalls = 0;

  /// Number of `paneOutput()` calls (plain-terminal reads).
  int paneOutputCalls = 0;

  /// Number of `snapshot()` calls (tests assert pages do NOT re-fetch on
  /// status events).
  int snapshotCalls = 0;

  /// Number of `output()` calls (tests assert a status event does not trigger
  /// an output re-read).
  int outputCalls = 0;

  /// When set, the FIRST `session()` call waits for this completer before
  /// returning; later calls return immediately. Lets tests exercise
  /// overlapping refreshes (generation guards).
  Completer<void>? firstSessionGate;

  /// When set, the FIRST `snapshot()` call waits for this completer before
  /// returning; later calls return immediately.
  Completer<void>? firstSnapshotGate;

  /// What `healthz()` returns (default: relay is healthy).
  bool healthzResult = true;

  /// Recorded `prompt(target, text)` calls.
  final List<(String, String)> prompts = [];

  /// Recorded `sendText(paneId, text)` calls.
  final List<(String, String)> sendTextCalls = [];

  /// Recorded `startAgent(name, kind, paneId)` calls.
  final List<(String, String, String)> startAgentCalls = [];

  /// Id returned by `createWorkspace()`.
  String newWorkspaceId = 'w-new';

  /// Recorded `keys(target, keys)` calls.
  final List<(String, List<String>)> keysCalls = [];

  @override
  Future<List<RelayAgent>> snapshot() async {
    snapshotCalls++;
    final result = agents;
    if (snapshotCalls == 1 && firstSnapshotGate != null) {
      await firstSnapshotGate!.future;
    }
    if (snapshotError) {
      throw const RelayException('boom', 'ошибка снимка');
    }
    return result;
  }

  @override
  Future<RelaySession> session() async {
    sessionCalls++;
    final result = sessionData;
    if (sessionCalls == 1 && firstSessionGate != null) {
      await firstSessionGate!.future;
    }
    return result;
  }

  @override
  Future<String> paneOutput(
      String paneId, {int lines = 200, String format = 'text'}) async {
    paneOutputCalls++;
    return outputText;
  }

  @override
  Future<void> sendText(String paneId, String text) async {
    sendTextCalls.add((paneId, text));
  }

  @override
  Future<void> startAgent(String name, String kind, String paneId) async {
    startAgentCalls.add((name, kind, paneId));
  }

  @override
  Future<String> createWorkspace({String? label, String? cwd}) async {
    return newWorkspaceId;
  }

  @override
  Future<String> output(String target, {int lines = 200, String format = 'text'}) async {
    outputCalls++;
    return outputText;
  }

  @override
  Future<void> keys(String target, List<String> keys) async {
    keysCalls.add((target, keys));
  }

  @override
  Future<void> prompt(String target, String text) async {
    prompts.add((target, text));
  }

  @override
  Future<bool> healthz() async => healthzResult;

  @override
  void pauseReconnect() {
    _paused = true;
  }

  @override
  void resumeReconnect() {
    _paused = false;
  }

  /// True while [pauseReconnect] is in effect (lifecycle test hook).
  bool _paused = false;
  bool get reconnectPaused => _paused;

  @override
  Future<void> close() async {}

  /// Emits a typed event the way it would arrive over WS.
  void emit(RelayEvent event) => _eventsController.add(event);
}
