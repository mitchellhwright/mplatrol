import 'package:mplatrol/src/e2e_coverage/lcov.dart';

/// Files with at least this many instrumented lines count as large in the least-covered list.
const largeFileLines = 100;

/// How many least-covered large files a summary lists.
const leastCoveredCount = 10;

/// Lines hit out of lines instrumented.
class LineCount {
  const LineCount(this.hit, this.total);

  final int hit;
  final int total;

  /// Percent of lines hit, to two decimals; 0 when nothing is instrumented.
  double get percent => total == 0 ? 0 : double.parse((hit / total * 100).toStringAsFixed(2));

  Map<String, Object?> toJson() => {'hit': hit, 'total': total, 'percent': percent};
}

/// One source file's line coverage.
class FileCoverage {
  const FileCoverage({required this.path, required this.package, required this.lines});

  final String path;
  final String package;
  final LineCount lines;
}

/// Line coverage of an E2E (journey) LCOV report: overall, per package and the least-covered large files.
class CoverageSummary {
  const CoverageSummary({required this.overall, required this.packages, required this.leastCovered});

  /// Summarises [lcov], naming each file's package with [names].
  factory CoverageSummary.of(Lcov lcov, PackageNames names) {
    final perPackage = <String, (int, int)>{};
    final files = <FileCoverage>[];
    var hit = 0;
    var total = 0;
    for (final MapEntry(key: path, value: lines) in lcov.files.entries) {
      final fileHit = lines.values.where((hits) => hits > 0).length;
      final package = names.of(path);
      final (packageHit, packageTotal) = perPackage[package] ?? (0, 0);
      perPackage[package] = (packageHit + fileHit, packageTotal + lines.length);
      files.add(FileCoverage(path: path, package: package, lines: LineCount(fileHit, lines.length)));
      hit += fileHit;
      total += lines.length;
    }
    final large = files.where((file) => file.lines.total >= largeFileLines).toList()
      ..sort((a, b) {
        final byPercent = a.lines.percent.compareTo(b.lines.percent);
        return byPercent != 0 ? byPercent : b.lines.total.compareTo(a.lines.total);
      });
    return CoverageSummary(
      overall: LineCount(hit, total),
      packages: {
        for (final name in perPackage.keys.toList()..sort())
          name: LineCount(perPackage[name]!.$1, perPackage[name]!.$2),
      },
      leastCovered: large.take(leastCoveredCount).toList(),
    );
  }

  final LineCount overall;
  final Map<String, LineCount> packages;
  final List<FileCoverage> leastCovered;

  Map<String, Object?> toJson() => {
        'overall': overall.toJson(),
        'packages': {for (final MapEntry(:key, :value) in packages.entries) key: value.toJson()},
        'leastCoveredLargeFiles': [
          for (final file in leastCovered) {'path': file.path, 'package': file.package, ...file.lines.toJson()},
        ],
      };

  /// The console block: overall line coverage, one line per package and the least-covered large files.
  List<String> renderConsole() => [
        '[coverage] E2E (journey) line coverage: ${overall.hit}/${overall.total} lines, ${overall.percent}%',
        for (final MapEntry(:key, :value) in packages.entries)
          '[coverage]   $key: ${value.hit}/${value.total} (${value.percent}%)',
        if (leastCovered.isNotEmpty) '[coverage] least covered files of $largeFileLines+ lines:',
        for (final file in leastCovered)
          '[coverage]   ${file.lines.percent}% ${file.lines.hit}/${file.lines.total} ${file.package}: ${file.path}',
      ];
}
