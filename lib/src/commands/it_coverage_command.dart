import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/e2e_coverage/e2e_coverage_reports.dart';
import 'package:mplatrol/src/e2e_coverage/lcov.dart';
import 'package:path/path.dart' as p;

/// DEV NOTE* When you create a new command, make sure you add it to the [MplatrolCommandRunner]
///
/// `mplatrol coverage` works with the E2E (journey) coverage that `mplatrol run --coverage` writes.
class ItCoverageCommand extends Command<int> {
  ItCoverageCommand() {
    addSubcommand(ItCoverageMergeCommand());
  }

  @override
  String get name => 'coverage';

  @override
  String get description => 'Merge E2E (journey) coverage reports from `mplatrol run --coverage`.';
}

/// `mplatrol coverage merge <lcov files...>` merges E2E LCOV reports by file and line (hit counts add up) and prints
/// the merged summary.
class ItCoverageMergeCommand extends BaseCommand {
  ItCoverageMergeCommand() {
    argParser.addOption('output',
        abbr: 'o',
        valueHelp: 'file',
        help: 'Write the merged LCOV here (default: '
            '<app>/.mplatrol/reports/coverage/lcov-merged-<timestamp>.info). A JSON summary and, when '
            'genhtml is installed, an HTML report are written beside it.');
  }

  @override
  String get name => 'merge';

  @override
  String get description => 'Merge E2E LCOV reports (union by file and line) and print lines hit/total overall, per '
      'package and the least-covered large files.';

  @override
  String get invocation => 'mplatrol coverage merge <lcov files...>';

  @override
  void validateInput() {
    if (argResults.rest.isEmpty) {
      usageException('Pass at least one LCOV file, for example the lcov-<tenant>-<variant>-<timestamp>.info files '
          'under .mplatrol/reports/coverage.');
    }
    final missing = argResults.rest.where((path) => !File(path).existsSync());
    if (missing.isNotEmpty) {
      usageException('LCOV file not found: ${missing.first}.');
    }
  }

  @override
  Future<int> runCommand() async {
    final reports = getDep<E2eCoverageReports>();
    final inputs = <Lcov>[];
    for (final path in argResults.rest) {
      try {
        inputs.add(Lcov.parse(File(path).readAsStringSync()));
      } on FormatException catch (error) {
        logger.err('Cannot merge $path: ${error.message}');
        return ExitCode.data.code;
      }
    }
    final repo = fileSystem.getAppDirectory(throwIfNotFound: false).path;
    final now = DateTime.now();
    final output = (argResults['output'] as String?) ??
        p.join(reports.reportsDirectory(repo), 'lcov-merged-${reports.timestamp(now)}.info');
    final summary = await reports.write(Lcov.merge(inputs), path: output, names: reports.packageNames(repo), meta: {
      'kind': 'merged',
      'sources': [for (final path in argResults.rest) p.basename(path)],
    });
    summary.renderConsole().forEach(logger.info);
    return ExitCode.success.code;
  }
}
