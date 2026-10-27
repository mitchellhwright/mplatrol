import 'dart:async';

import 'package:patrol/patrol.dart' show PatrolActionException;

/// A controlled cleanup failure without transport response contents.
class NativeCleanupUnresolved implements Exception {
  /// Creates the failure with a controlled [reason] code.
  const NativeCleanupUnresolved(this.reason);

  /// `transport_unusable`, `operation_pending` or `cleanup_budget_expired`.
  final String reason;

  @override
  String toString() => 'Native cleanup unresolved: $reason';
}

// Journey and zone changes do not create a new native service or settle its RPCs.
final _operations = _NativeOperations();

/// Enters a journey only while the process's native service is known usable.
///
/// Scope entry never resets pending or failed transport state. There is no
/// recovery/reset API: a failed service requires a new native execution process.
Future<T> withNativeOperationScope<T>(Future<T> Function() body) async {
  _operations.requireUsable();
  return body();
}

/// Starts one underlying native operation only while transport is known usable.
///
/// The original future is returned unchanged; timeout wrappers do not cancel or
/// prematurely settle the tracked operation. Native errors remain caller-visible.
Future<T> trackNativeOperation<T>(Future<T> Function() query) => _operations.start(query);

/// Reports whether a caught native failure permits further native operations.
bool get nativeOperationsUsable => _operations.usable;

/// Waits only for local completion signals before permitting cleanup RPCs.
///
/// Args:
///   deadline: Absolute budget shared by all cleanup phases.
///
/// Throws:
///   NativeCleanupUnresolved: Budget expired, an operation remains pending, or
///     an underlying native operation failed. No probe RPC is sent.
Future<void> awaitNativeCleanupReadiness({required DateTime deadline}) => _operations.settle(deadline);

class _NativeOperations {
  final _pending = <Completer<void>>{};
  bool _failed = false;

  bool get usable => !_failed && _pending.isEmpty;

  void requireUsable() {
    if (!usable) {
      throw NativeCleanupUnresolved(_failed ? 'transport_unusable' : 'operation_pending');
    }
  }

  Future<T> start<T>(Future<T> Function() query) {
    requireUsable();
    final completion = Completer<void>();
    _pending.add(completion);
    final underlying = Future<T>.sync(query);
    underlying.then<void>((_) => _complete(completion, failed: false),
        onError: (Object error, StackTrace stack) => _complete(completion, failed: !_isNativeServerAnswer(error)));
    return underlying;
  }

  /// Patrol raises [PatrolActionException] only when its native server answered
  /// with an error (for example XCTest 10008 when SpringBoard's windows change
  /// mid-snapshot), so the transport still works and later probes may run. A
  /// transport failure surfaces as a raw timeout, socket or HTTP client error.
  static bool _isNativeServerAnswer(Object error) => error is PatrolActionException;

  void _complete(Completer<void> completion, {required bool failed}) {
    _failed = _failed || failed;
    _pending.remove(completion);
    completion.complete();
  }

  Future<void> settle(DateTime deadline) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw const NativeCleanupUnresolved('cleanup_budget_expired');
    }
    if (_pending.isNotEmpty) {
      try {
        await Future.wait(_pending.map((entry) => entry.future).toList()).timeout(remaining);
      } on TimeoutException {
        throw const NativeCleanupUnresolved('operation_pending');
      }
    }
    if (deadline.difference(DateTime.now()) <= Duration.zero) {
      throw const NativeCleanupUnresolved('cleanup_budget_expired');
    }
    if (!usable) {
      throw NativeCleanupUnresolved(_failed ? 'transport_unusable' : 'operation_pending');
    }
  }
}
