import 'dart:math';

import 'package:mplatrol/src/test_order.dart';
import 'package:test/test.dart';

List<int> _indices(int count) => [for (var index = 0; index < count; index++) index];

void main() {
  group('TestOrder.apply', () {
    test('the same seed always gives the same order', () {
      const order = TestOrder.random(123456);
      final tests = [for (var index = 0; index < 20; index++) 'test$index'];

      expect(order.apply(tests), order.apply(tests));
      expect(const TestOrder.random(123456).apply(tests), order.apply(tests));
    });

    // Pinned against an independent JavaScript mulberry32 + Fisher-Yates, so a
    // change to the algorithm (which would break every recorded --seed) fails.
    test('matches the reference mulberry32 shuffle', () {
      expect(const TestOrder.random(42).apply(_indices(10)), [0, 7, 3, 5, 2, 1, 8, 9, 4, 6]);
      expect(const TestOrder.random(43).apply(_indices(10)), [8, 1, 7, 5, 3, 6, 0, 4, 2, 9]);
      expect(const TestOrder.random(testOrderSeedLimit - 1).apply(_indices(10)), [3, 0, 9, 4, 2, 7, 6, 5, 1, 8]);
      expect(const TestOrder.random(0).apply(_indices(5)), [4, 2, 3, 0, 1]);
    });

    test('a different seed gives a different order for more than three tests', () {
      final orders = {for (var seed = 0; seed < 50; seed++) TestOrder.random(seed).apply(_indices(8)).join(',')};

      expect(orders.length, greaterThan(45));
      expect(const TestOrder.random(1).apply(_indices(4)), isNot(const TestOrder.random(2).apply(_indices(4))));
    });

    test('is a permutation and never changes the input list', () {
      final tests = _indices(30);

      final shuffled = const TestOrder.random(7).apply(tests);

      expect(shuffled, unorderedEquals(tests));
      expect(shuffled, isNot(tests));
      expect(tests, _indices(30));
    });

    test('declared keeps the order whatever the seed', () {
      expect(const TestOrder.declared(42).apply(_indices(10)), _indices(10));
    });

    test('handles empty and single-test selections', () {
      expect(const TestOrder.random(5).apply(<int>[]), isEmpty);
      expect(const TestOrder.random(5).apply([9]), [9]);
    });
  });

  group('TestOrder.parse', () {
    test('defaults to random with a fresh seed', () {
      final order = TestOrder.parse(random: Random(1));

      expect(order.declared, isFalse);
      expect(order.seed, Random(1).nextInt(testOrderSeedLimit));
      expect(TestOrder.parse().seed, inInclusiveRange(0, testOrderSeedLimit - 1));
    });

    test('reads --seed and --order', () {
      final seeded = TestOrder.parse(seed: ' 17 ');
      final declared = TestOrder.parse(order: testOrderDeclared, seed: '17');

      expect((seeded.declared, seeded.seed, seeded.mode), (false, 17, 'random'));
      expect((declared.declared, declared.seed, declared.mode), (true, 17, 'declared'));
    });

    test('rejects an unknown order or a seed outside 0..2^32-1', () {
      expect(() => TestOrder.parse(order: 'shuffled'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('random or declared'))));
      for (final seed in ['-1', '4294967296', 'x', '']) {
        expect(() => TestOrder.parse(seed: seed),
            throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('--seed must be'))));
      }
      expect(TestOrder.parse(seed: '4294967295').seed, 4294967295);
    });
  });

  test('banner and reproduce name the seed, or the declared order', () {
    expect(const TestOrder.random(99).banner, '[order] seed=99 (reproduce with --seed=99)');
    expect(const TestOrder.random(99).reproduce, '--seed=99');
    expect(const TestOrder.declared(99).banner, '[order] declared (--order=declared): tests run in discovery order');
    expect(const TestOrder.declared(99).reproduce, '--order=declared');
  });

  test('ItTestOrder is declared until a run sets its order', () {
    final holder = ItTestOrder();

    expect(holder.order.declared, isTrue);
    holder.order = const TestOrder.random(3);
    expect(holder.order.seed, 3);
  });

  group('summariseTestOrder', () {
    test('names every test when the list is short', () {
      expect(summariseTestOrder('iOS run order', ['a', 'b', 'c']), '[order] iOS run order: a, b, c');
    });

    test('names the first tests and counts the rest when the list is long', () {
      expect(
        summariseTestOrder('iOS run order', ['a', 'b', 'c', 'd', 'e']),
        '[order] iOS run order: a, b, c, and 2 more (5 tests; all with --verbose or in summary.json)',
      );
    });
  });
}
