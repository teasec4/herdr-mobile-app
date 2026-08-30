import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../models/relay_session.dart';

// Re-export the protocol exception so UI/tests keep importing it from this
// library (docs/09-refactoring-plan.md, decision #3).
export '../core/protocol/relay_exception.dart' show RelayException;

/// Relay connection phase.
enum RelayStatus { disconnected, connecting, connected }

/// Relay client contract for the UI: connection, snapshot, agent operations.
///
/// Implementations: [RelayClientImpl] (`services/relay_client_impl.dart`) on
/// the layered Transport+Protocol stack; in widget tests — a fake
/// (`test/fakes/fake_relay_client.dart`).
abstract class RelayClient {
  /// Connection status; subscribe to changes to update the UI.
  ValueNotifier<RelayStatus> get status;

  /// Stream of relay events (e.g. `pane.agent_status_changed`).
  Stream<RelayEvent> get events;

  /// List of agents (`agents.snapshot`).
  Future<List<RelayAgent>> snapshot();

  /// Full session (`session.snapshot`): workspaces, panes (agent panes and
  /// plain terminals) and focused targets.
  Future<RelaySession> session();

  /// Writes literal text into a pane (`pane.send_text`) — input for plain
  /// terminals that have no agent.
  Future<void> sendText(String paneId, String text);

  /// Starts an agent of [kind] in an existing pane (`agent.start`).
  Future<void> startAgent(String name, String kind, String paneId);

  /// Creates a workspace (`workspace.create`) and returns its id.
  Future<String> createWorkspace({String? label, String? cwd});

  /// Agent terminal output (`agent.output`).
  Future<String> output(String target, {int lines = 200, String format = 'text'});

  /// Sends key combinations to the agent (`agent.keys`): ['enter'], ['ctrl', 'c'].
  Future<void> keys(String target, List<String> keys);

  /// Sends text as a message to the agent (`agent.prompt`).
  Future<void> prompt(String target, String text);

  /// Quick check that the relay is alive via http /healthz.
  Future<bool> healthz();

  /// Pauses reconnect attempts while the app is in the background.
  void pauseReconnect();

  /// Resumes reconnect attempts when the app returns to the foreground.
  void resumeReconnect();

  /// Closes the client: stops reconnects and events.
  Future<void> close();
}
