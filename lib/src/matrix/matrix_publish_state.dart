import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:path/path.dart' as p;

/// Where `mplatrol matrix` tells external publishers (the `--publish` hooks, a scheduled job) which run is the
/// newest: `~/.mplatrol/matrix-publish/latest-run.json` with `run`, `dir` and `updated_at`, written when a round
/// starts and after every leg.
class MatrixPublishState {
  /// Creates the state under [home]; with no home writes are skipped.
  MatrixPublishState(String? home)
      : directory = home == null || home.isEmpty ? null : p.join(home, '.mplatrol', 'matrix-publish');

  /// The state directory, or null without a home directory.
  final String? directory;

  /// Notes that [run] was active at [at].
  void recordRun(MatrixRunDir run, DateTime at) {
    final dir = directory;
    if (dir == null) {
      return;
    }
    File(p.join(dir, 'latest-run.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'run': run.id, 'dir': run.path, 'updated_at': at.toUtc().toIso8601String()}));
  }
}
