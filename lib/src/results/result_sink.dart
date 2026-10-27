import 'dart:io';

import 'package:mplatrol/src/ci_report/ci_summary.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/ci_report/junit_report.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';

/// Everything a run reports once it finished.
class RunReport {
  /// The report of a run that started at [startedAt] and took [duration].
  const RunReport({
    required this.results,
    required this.startedAt,
    required this.duration,
    required this.toolVersion,
    this.runUrl,
    this.appVersion = '',
  });

  /// Every selected test's result, with its category and the lesson that explained it.
  final List<ItTestResult> results;

  /// When the run started.
  final DateTime startedAt;

  /// How long the run took.
  final Duration duration;

  /// The CI job page of the run, when it ran in CI.
  final String? runUrl;

  /// The version of the app under test, when known.
  final String appVersion;

  /// The `mplatrol` version that ran.
  final String toolVersion;

  /// The run summary JSON (`summary.json`).
  String renderSummary() => renderCiSummary(
        results,
        (duration: duration, testResultsUrl: runUrl, mplatrolVersion: toolVersion, appVersion: appVersion),
      );

  /// The JUnit XML of every result.
  String renderJUnit() => renderJUnitReport(results, timestamp: startedAt);
}

/// Somewhere a finished run's results go: a file, a dashboard, a test-management tool.
///
/// Implement this to publish results to your own systems and register it with [ResultSinks.add] (or register a
/// whole [ResultSinks] in GetIt) before the command runs. A sink that throws only logs a warning: reporting never
/// changes a run's verdict or exit code.
abstract interface class ResultSink {
  /// A short name for log lines, e.g. `junit`.
  String get name;

  /// Publishes [report]; returns where it went (a path or URL) for the log, or null.
  Future<String?> publish(RunReport report);
}

/// Writes the JUnit XML of a run to [path].
class JUnitResultSink implements ResultSink {
  /// A sink writing to [path].
  const JUnitResultSink(this.path);

  /// The file to write.
  final String path;

  @override
  String get name => 'junit';

  @override
  Future<String?> publish(RunReport report) async {
    await _writeFile(path, report.renderJUnit());
    return path;
  }
}

/// Writes the run summary JSON of a run to [path].
class JsonResultSink implements ResultSink {
  /// A sink writing to [path].
  const JsonResultSink(this.path);

  /// The file to write.
  final String path;

  @override
  String get name => 'json';

  @override
  Future<String?> publish(RunReport report) async {
    await _writeFile(path, report.renderSummary());
    return path;
  }
}

Future<void> _writeFile(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

/// The outcome of one sink: where the results went, or why they did not.
typedef SinkOutcome = ({String sink, String? location, Object? error});

/// The sinks a run publishes to, from `reporting.sinks` in `mplatrol.yaml` plus any added in code.
class ResultSinks {
  /// The given [sinks].
  ResultSinks([List<ResultSink> sinks = const []]) : _sinks = [...sinks];

  /// The sinks `reporting.sinks` configures: `{type: junit, path: ...}` and `{type: json, path: ...}`.
  ///
  /// Throws:
  ///   ArgumentError: a sink has an unknown `type` or no `path`.
  factory ResultSinks.fromConfig(ReportingOptions options) => ResultSinks([
        for (final sink in options.sinks) _configured(sink),
      ]);

  static ResultSink _configured(Map<String, String> sink) {
    final path = sink['path'] ?? '';
    if (path.isEmpty) {
      throw ArgumentError.value(sink, 'reporting.sinks', 'every sink needs a path');
    }
    return switch (sink['type']) {
      'junit' => JUnitResultSink(path),
      'json' => JsonResultSink(path),
      final type => throw ArgumentError.value(type, 'reporting.sinks.type', 'expected "junit" or "json"'),
    };
  }

  final List<ResultSink> _sinks;

  /// The registered sinks, in publishing order.
  List<ResultSink> get sinks => List.unmodifiable(_sinks);

  /// Adds [sink] after the configured ones.
  void add(ResultSink sink) => _sinks.add(sink);

  /// Publishes [report] to every sink in order; a sink that throws is reported in its outcome, not rethrown.
  Future<List<SinkOutcome>> publishAll(RunReport report) async {
    final outcomes = <SinkOutcome>[];
    for (final sink in _sinks) {
      try {
        outcomes.add((sink: sink.name, location: await sink.publish(report), error: null));
      } on Object catch (error) {
        outcomes.add((sink: sink.name, location: null, error: error));
      }
    }
    return outcomes;
  }
}
