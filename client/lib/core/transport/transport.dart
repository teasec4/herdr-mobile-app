import 'package:flutter/foundation.dart';

/// Connection status of a [Transport], exposed for the UI and upper layers.
///
/// Mirrors the legacy `RelayStatus` enum; the client layer maps between the
/// two so the UI contract stays unchanged.
enum ConnectionStatus { disconnected, connecting, connected }

/// Low-level transport contract (docs/09-refactoring-plan.md §2.1).
///
/// A [Transport] owns the raw connection: opening it, sending/receiving
/// **string** frames, reconnecting with backoff, and reporting status. It
/// knows nothing about JSON, requests, events, or the relay protocol — those
/// live in the Protocol layer.
///
/// Dependencies: `dart:async`, `flutter/foundation` (ValueNotifier).
abstract class Transport {
  /// Inbound raw text frames (one per WebSocket message).
  Stream<String> get messages;

  /// Connection status; subscribe to react to connect/disconnect.
  ValueNotifier<ConnectionStatus> get status;

  /// Last connection error, if any (shown to the user instead of a generic
  /// message). Cleared on a successful connect.
  String? get lastError;

  /// Opens the connection to [uri] and starts delivering frames to [messages].
  /// Subsequent calls (including reconnects) use the same uri.
  Future<void> connect(Uri uri);

  /// Sends one raw text frame. No-op while disconnected.
  void send(String data);

  /// Pauses the reconnect loop (e.g. app backgrounded). Does not close an
  /// established connection.
  void pause();

  /// Resumes the reconnect loop; reconnects immediately if disconnected.
  void resume();

  /// Closes the connection and stops all reconnects.
  Future<void> close();
}
