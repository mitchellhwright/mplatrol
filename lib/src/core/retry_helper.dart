import 'dart:math' as math;

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';

/// A function that sleeps for the given [Duration].
///
/// Registered as a GetIt singleton so tests can inject a no-op.
typedef SleepFunction = Future<void> Function(Duration);

/// Calls [fn] up to [maxAttempts] times with exponential backoff between
/// failures.
///
/// - Attempt 1 fails → waits [initialDelay] × 2⁰ → attempt 2
/// - Attempt 2 fails → waits [initialDelay] × 2¹ → attempt 3
/// - Final attempt fails → rethrows the last exception
///
/// "Already exists" cases should be handled inside [fn] before throwing so
/// they are never retried. Retry applies to all exceptions.
///
/// [sleep] is injectable for testing; defaults to [getDep<SleepFunction>()].
Future<T> withRetry<T>({
  required Future<T> Function() fn,
  required MplatrolLogger logger,
  String context = '',
  int maxAttempts = 3,
  Duration initialDelay = const Duration(seconds: 2),
  SleepFunction? sleep,
}) async {
  final sleepFn = sleep ?? getDep<SleepFunction>();
  final tag = context.isNotEmpty ? ' for $context' : '';
  Object? lastError;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (e) {
      lastError = e;
      if (attempt < maxAttempts) {
        final delay = initialDelay * math.pow(2, attempt - 1).toInt();
        logger.warn(
          'Attempt $attempt/$maxAttempts failed$tag: $e. Retrying in ${delay.inSeconds}s...',
        );
        await sleepFn(delay);
      } else {
        logger.err('All $maxAttempts attempts failed$tag: $e');
      }
    }
  }

  throw lastError!;
}
