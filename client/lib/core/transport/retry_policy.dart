import 'dart:math';

/// Reconnect/retry policy: decides whether to retry and how long to wait.
///
/// Lives in the Connection layer so different policies can be A/B tested
/// without touching Transport or Protocol (docs/09-refactoring-plan.md §2.4).
abstract class RetryPolicy {
  /// Whether attempt [attempt] (0-based) should be retried after [error].
  bool shouldRetry(int attempt, Object error);

  /// Delay before attempt [attempt] (0-based).
  Duration nextDelay(int attempt);
}

/// Classic exponential backoff: 1 s, 2 s, 4 s, … capped at [maxDelay].
class ExponentialBackoff implements RetryPolicy {
  ExponentialBackoff({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
  });

  final Duration baseDelay;
  final Duration maxDelay;

  @override
  bool shouldRetry(int attempt, Object error) => true;

  @override
  Duration nextDelay(int attempt) {
    final ms = min(
      pow(2, attempt).toInt() * baseDelay.inMilliseconds,
      maxDelay.inMilliseconds,
    );
    return Duration(milliseconds: ms);
  }
}

/// Constant delay between retries (useful for tests and LAN links).
class FixedDelay implements RetryPolicy {
  FixedDelay(this.delay);

  final Duration delay;

  @override
  bool shouldRetry(int attempt, Object error) => true;

  @override
  Duration nextDelay(int attempt) => delay;
}
