import 'dart:math';

/// The `--order` value that shuffles the selected tests (the default).
const testOrderRandom = 'random';

/// The `--order` value that keeps the order the tests are declared in.
const testOrderDeclared = 'declared';

/// Largest `--seed` plus one: seeds are unsigned 32-bit integers.
const testOrderSeedLimit = 1 << 32;

/// Environment variable carrying a local run's shuffled test list to the
/// native runner: `TEST_RUNNER_`-prefixed for xcodebuild (which strips the
/// prefix into the XCTest process), and read by the Android `build.gradle`
/// into the [androidTestOrderArgument] instrumentation argument.
const testOrderEnv = 'MPLATROL_TEST_ORDER';

/// Android instrumentation argument the generated `MplatrolTestOrder` JUnit
/// ordering reads (see android_patrol_runner.dart).
const androidTestOrderArgument = 'mplatrolTestOrder';

/// The order one `mplatrol run` runs its tests in: shuffled by [seed], or
/// [declared] as discovered.
///
/// Tests share test users and server-side state, so a fixed order makes the
/// same tests collide on every run and hides passes that depend on an earlier
/// test. The shuffle uses its own 32-bit PRNG (mulberry32) and Fisher-Yates,
/// not `dart:math` `Random`, whose sequence for a seed is not guaranteed
/// across Dart SDK versions: the same seed gives the same order on every
/// machine and every mplatrol release that keeps this algorithm.
class TestOrder {
  /// Shuffles by [seed] (0 ≤ seed < [testOrderSeedLimit]).
  const TestOrder.random(this.seed) : declared = false;

  /// Keeps the declared order; [seed] is still reported for the record.
  const TestOrder.declared(this.seed) : declared = true;

  /// Resolves `--order` and `--seed`: [order] defaults to random, [seed] to a
  /// fresh seed from [random]. Throws [FormatException] for an unknown order
  /// or a seed outside 0..2^32-1.
  factory TestOrder.parse({String? order, String? seed, Random? random}) {
    final mode = (order ?? testOrderRandom).trim();
    if (mode != testOrderRandom && mode != testOrderDeclared) {
      throw FormatException('--order must be $testOrderRandom or $testOrderDeclared (got "$mode").');
    }
    final value = seed == null ? (random ?? Random.secure()).nextInt(testOrderSeedLimit) : int.tryParse(seed.trim());
    if (value == null || value < 0 || value >= testOrderSeedLimit) {
      throw FormatException('--seed must be a whole number from 0 to ${testOrderSeedLimit - 1} (got "$seed").');
    }
    return mode == testOrderDeclared ? TestOrder.declared(value) : TestOrder.random(value);
  }

  /// The seed the run's order is derived from.
  final int seed;

  /// Whether the run keeps the declared order (`--order=declared`).
  final bool declared;

  /// The `--order` value of this order.
  String get mode => declared ? testOrderDeclared : testOrderRandom;

  /// The line `mplatrol run` prints before it runs anything.
  String get banner => declared
      ? '[order] declared (--order=declared): tests run in discovery order'
      : '[order] seed=$seed (reproduce with --seed=$seed)';

  /// How to rerun this order, for failure summaries.
  String get reproduce => declared ? '--order=declared' : '--seed=$seed';

  /// [items] in this order: a copy shuffled by [seed], or unchanged when
  /// [declared]. The same seed and item count always give the same order.
  List<T> apply<T>(List<T> items) {
    final ordered = List<T>.of(items);
    if (declared) {
      return ordered;
    }
    final next = _mulberry32(seed);
    for (var index = ordered.length - 1; index > 0; index--) {
      final other = (next() * (index + 1)) >> 32;
      final swap = ordered[index];
      ordered[index] = ordered[other];
      ordered[other] = swap;
    }
    return ordered;
  }
}

/// mulberry32: a 32-bit PRNG defined entirely by integer arithmetic masked
/// to 32 bits, so it is identical on every Dart VM. Returns 0..2^32-1.
int Function() _mulberry32(int seed) {
  const mask = 0xFFFFFFFF;
  var state = seed & mask;
  int imul(int a, int b) => (a * b) & mask;
  return () {
    state = (state + 0x6D2B79F5) & mask;
    var t = imul(state ^ (state >> 15), state | 1);
    t = (t ^ (t + imul(t ^ (t >> 7), t | 61))) & mask;
    return (t ^ (t >> 14)) & mask;
  };
}

/// The [TestOrder] of the current `mplatrol run`, set once by the command
/// before any runner starts. Commands that only build or prepare never set
/// it, so their runners keep the declared order.
class ItTestOrder {
  /// The order runners apply.
  TestOrder order = const TestOrder.declared(0);
}

/// How many tests the default `[order]` line names before it summarises the rest.
const orderPreviewCount = 3;

/// The one-line `[order]` view: the first [orderPreviewCount] tests and a count. The full list is
/// printed with `--verbose` and recorded in `summary.json`.
String summariseTestOrder(String label, List<String> ordered) {
  if (ordered.length <= orderPreviewCount) {
    return '[order] $label: ${ordered.join(', ')}';
  }
  final preview = ordered.take(orderPreviewCount).join(', ');
  return '[order] $label: $preview, and ${ordered.length - orderPreviewCount} more '
      '(${ordered.length} tests; all with --verbose or in summary.json)';
}
