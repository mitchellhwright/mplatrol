import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/results/result_sink.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const _leg = ItRunLeg(tenant: 'acme', environment: 'staging', variant: 'android');

RunReport _report() => RunReport(
      results: [
        ItTestResult(leg: _leg, file: 'login_test', description: 'signs in', outcome: ItTestOutcome.pass),
        ItTestResult(
            leg: _leg, file: 'login_test', description: 'signs out', outcome: ItTestOutcome.fail, reason: 'boom'),
      ],
      startedAt: DateTime.utc(2026, 10, 1, 12),
      duration: const Duration(minutes: 3),
      toolVersion: '0.1.0',
      runUrl: 'https://ci.example.test/run/1',
    );

void main() {
  late Directory out;
  setUp(() => out = Directory.systemTemp.createTempSync('result_sinks'));
  tearDown(() => out.deleteSync(recursive: true));

  test('the JUnit sink writes one testcase per result', () async {
    final path = p.join(out.path, 'nested', 'junit.xml');

    expect(await JUnitResultSink(path).publish(_report()), path);

    final junit = XmlDocument.parse(File(path).readAsStringSync());
    expect(junit.findAllElements('testcase'), hasLength(2));
    expect(junit.findAllElements('failure'), hasLength(1));
  });

  test('the JSON sink writes the run summary', () async {
    final path = p.join(out.path, 'summary.json');

    await JsonResultSink(path).publish(_report());

    final summary = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    expect([summary['Total'], summary['Passed'], summary['Failed'], summary['mplatrol_version']], [2, 1, 1, '0.1.0']);
    expect(summary['TestResultsUrl'], 'https://ci.example.test/run/1');
  });

  test('ResultSinks.fromConfig builds the configured sinks and rejects unknown ones', () {
    final sinks = ResultSinks.fromConfig(ReportingOptions({
      'sinks': [
        {'type': 'junit', 'path': 'a.xml'},
        {'type': 'json', 'path': 'b.json'},
      ],
    })).sinks;
    expect([for (final sink in sinks) sink.name], ['junit', 'json']);
    expect(ResultSinks.fromConfig(ReportingOptions(null)).sinks, isEmpty);
    expect(
        () => ResultSinks.fromConfig(ReportingOptions({
              'sinks': [
                {'type': 'xml', 'path': 'x'}
              ]
            })),
        throwsArgumentError);
    expect(
        () => ResultSinks.fromConfig(ReportingOptions({
              'sinks': [
                {'type': 'json'}
              ]
            })),
        throwsArgumentError);
  });

  test('publishAll reports every sink, a failing one included, without throwing', () async {
    final sinks = ResultSinks([_ThrowingSink()])..add(JsonResultSink(p.join(out.path, 's.json')));

    final outcomes = await sinks.publishAll(_report());

    expect(outcomes.first.sink, 'throwing');
    expect(outcomes.first.error, isA<StateError>());
    expect(outcomes.last.location, p.join(out.path, 's.json'));
    expect(outcomes.last.error, isNull);
  });
}

class _ThrowingSink implements ResultSink {
  @override
  String get name => 'throwing';

  @override
  Future<String?> publish(RunReport report) => throw StateError('down');
}
