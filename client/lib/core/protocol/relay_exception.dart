/// Relay protocol error: either a `code`/`message` from a relay response
/// frame's `error` object, or a local one (timeout, disconnected,
/// not_connected).
///
/// Lives in the Protocol layer; `services/relay_client.dart` re-exports it so
/// UI and tests keep importing it from the same place as before
/// (docs/09-refactoring-plan.md, decision #3).
class RelayException implements Exception {
  const RelayException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Structured error from a relay `response` frame.
class RelayError {
  const RelayError({required this.code, required this.message});

  final String code;
  final String message;
}

/// Thrown when a frame cannot be parsed (invalid JSON, unknown type).
class ProtocolException implements Exception {
  const ProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}
