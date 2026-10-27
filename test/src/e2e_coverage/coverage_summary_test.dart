import 'package:mplatrol/src/e2e_coverage/coverage_summary.dart';
import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:test/test.dart';

Map<int, int> _lines(int hit, int missed) => {
      for (var i = 0; i < hit; i++) i + 1: 1,
      for (var i = 0; i < missed; i++) hit + i + 1: 0,
    };

void main() {
  test('LineCount is 0 percent with nothing instrumented and rounds to two decimals', () {
    expect(const LineCount(0, 0).percent, 0);
    expect(const LineCount(1, 3).percent, 33.33);
    expect(const LineCount(1, 3).toJson(), {'hit': 1, 'total': 3, 'percent': 33.33});
  });

  group('CoverageSummary.of', () {
    final summary = CoverageSummary.of(
      Lcov({
        '/w/app/lib/a.dart': _lines(50, 150),
        '/w/app/lib/b.dart': _lines(90, 10),
        '/w/shared_platform/lib/c.dart': _lines(5, 5),
        '/w/shared_platform/lib/d.dart': _lines(0, 200),
      }),
      const PackageNames(),
    );

    test('counts lines overall and per package, sorted by package', () {
      expect((summary.overall.hit, summary.overall.total), (145, 510));
      expect(summary.packages.keys, ['app', 'shared_platform']);
      expect(summary.packages['app']!.toJson(), {'hit': 140, 'total': 300, 'percent': 46.67});
      expect(summary.packages['shared_platform']!.total, 210);
    });

    test('lists only large files, least covered first', () {
      expect([
        for (final file in summary.leastCovered) file.path
      ], [
        '/w/shared_platform/lib/d.dart',
        '/w/app/lib/a.dart',
        '/w/app/lib/b.dart',
      ]);
    });

    test('is JSON with overall, packages and the least-covered files', () {
      final json = summary.toJson();

      expect((json['overall']! as Map)['percent'], 28.43);
      expect((json['leastCoveredLargeFiles']! as List).first, containsPair('package', 'shared_platform'));
    });

    test('renders the console block', () {
      final lines = summary.renderConsole();

      expect(lines.first, '[coverage] E2E (journey) line coverage: 145/510 lines, 28.43%');
      expect(lines, contains('[coverage]   app: 140/300 (46.67%)'));
      expect(lines, contains(startsWith('[coverage]   0.0% 0/200 shared_platform: ')));
    });
  });

  test('keeps the ten least-covered large files, ties by size', () {
    final summary = CoverageSummary.of(
      Lcov({
        for (var i = 0; i < 12; i++) '/w/pkg/lib/f$i.dart': _lines(0, 100 + i),
      }),
      const PackageNames(),
    );

    expect(summary.leastCovered, hasLength(leastCoveredCount));
    expect(summary.leastCovered.first.path, '/w/pkg/lib/f11.dart');
  });

  test('an empty report summarises to zero without a file list', () {
    final summary = CoverageSummary.of(Lcov({}), const PackageNames());

    expect(summary.overall.percent, 0);
    expect(summary.renderConsole(), hasLength(1));
  });
}
