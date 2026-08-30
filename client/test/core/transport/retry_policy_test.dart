import 'package:client/core/transport/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExponentialBackoff', () {
    test('delays double each attempt: 1s, 2s, 4s, 8s, 16s', () {
      final p = ExponentialBackoff();
      expect(p.nextDelay(0), const Duration(seconds: 1));
      expect(p.nextDelay(1), const Duration(seconds: 2));
      expect(p.nextDelay(2), const Duration(seconds: 4));
      expect(p.nextDelay(3), const Duration(seconds: 8));
      expect(p.nextDelay(4), const Duration(seconds: 16));
    });

    test('caps at maxDelay (30s default)', () {
      final p = ExponentialBackoff();
      expect(p.nextDelay(5), const Duration(seconds: 30));
      expect(p.nextDelay(10), const Duration(seconds: 30));
    });

    test('honors custom maxDelay and baseDelay', () {
      final p = ExponentialBackoff(
        baseDelay: const Duration(milliseconds: 500),
        maxDelay: const Duration(seconds: 4),
      );
      expect(p.nextDelay(0), const Duration(milliseconds: 500));
      expect(p.nextDelay(1), const Duration(seconds: 1));
      expect(p.nextDelay(3), const Duration(seconds: 4));
      expect(p.nextDelay(10), const Duration(seconds: 4));
    });

    test('always retries', () {
      expect(ExponentialBackoff().shouldRetry(0, Exception('x')), isTrue);
    });
  });

  group('FixedDelay', () {
    test('returns the same delay every attempt', () {
      final p = FixedDelay(const Duration(seconds: 3));
      expect(p.nextDelay(0), const Duration(seconds: 3));
      expect(p.nextDelay(5), const Duration(seconds: 3));
    });
  });
}
