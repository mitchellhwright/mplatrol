import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/lt_instrumentation_log.dart';
import 'package:test/test.dart';

String _record(String chunk) => jsonEncode({
      'fields.msg': chunk,
      'fields.time': 715441375048,
      'level': 'info',
      'msg': 'outputReceived:fromProcess:atTime:',
      'pid': 9645,
      'time': '2026-10-02T15:32:28Z',
    });

void main() {
  group('plainLtInstrumentationLog', () {
    test('returns a plain log unchanged', () {
      const log = "Test Case '-[RunnerUITests.LoginE2ETests testShard01]' started.\r\n{not json}";
      expect(plainLtInstrumentationLog(log), log);
    });

    test('joins the runner output of JSON-lines records', () {
      final log = [
        _record("Test Case '-[RunnerUITests.LoginE2ETests testShard16]' started.\n"),
        _record('2026-10-02 RunnerUITests-Runner[9645:320982] MPLATROL_TEST_SKIPPED reason=x\n'),
      ].join('\n');
      expect(
          plainLtInstrumentationLog(log),
          "Test Case '-[RunnerUITests.LoginE2ETests testShard16]' started.\n"
          '2026-10-02 RunnerUITests-Runner[9645:320982] MPLATROL_TEST_SKIPPED reason=x\n');
    });

    test('rejoins a line split across records and decodes escapes', () {
      final log = [_record('PATROL_RESULT name=a '), _record(''), _record('details=<false>\n')].join('\n');
      expect(plainLtInstrumentationLog(log), 'PATROL_RESULT name=a details=<false>\n');
    });

    test('keeps other lines on their own line', () {
      final log = [
        _record('partial chunk'),
        '{"level":"debug","msg":"session started"}',
        '{broken json',
        _record('next\n'),
      ].join('\n');
      expect(plainLtInstrumentationLog(log),
          'partial chunk\n{"level":"debug","msg":"session started"}\n{broken json\nnext\n');
    });
  });

  group('UTF-8 repair', () {
    final fixture = File('test/fixtures/lt_scenario_logs/timeout_banner.txt').readAsStringSync();
    final doubleEncoded = latin1.decode(utf8.encode(fixture));

    test('repairs a log whose UTF-8 bytes were decoded as Latin-1', () {
      expect(doubleEncoded, contains('â'));
      expect(repairMojibake(doubleEncoded), fixture);
      expect(plainLtInstrumentationLog(doubleEncoded), fixture);
    });

    test('leaves correct text, plain ASCII and text that is not wholly Latin-1 unchanged', () {
      expect(repairMojibake(fixture), fixture);
      expect(repairMojibake('plain ascii'), 'plain ascii');
      const mixed = 'â\u0095\u0090 and ╡';
      expect(repairMojibake(mixed), mixed);
      const notUtf8 = 'â\u0080A \u00c3A';
      expect(repairMojibake(notUtf8), notUtf8);
    });
  });

  group('flutterTestFailureMessage', () {
    final fixture = File('test/fixtures/lt_scenario_logs/timeout_banner.txt').readAsStringSync();

    test('joins the wrapped message and drops the screen dump', () {
      expect(flutterTestFailureMessage(fixture),
          'TimeoutException: STEP account_detail_fields: not reached within 0:00:30.000000;');
    });

    test('keeps a multi-line expectation failure whole and caps its length', () {
      const log = 'The following TestFailure was thrown running a test:\nExpected: true\nActual: <false>\n'
          'login page chain: authenticated accounts not reached within 150s\n\nWhen the exception was thrown';
      expect(flutterTestFailureMessage(log),
          'TestFailure: Expected: true Actual: <false> login page chain: authenticated accounts not reached within 150s');
      final long = 'The following StateError was thrown running a test:\n${'x' * 500}\n';
      expect(flutterTestFailureMessage(long), '${'StateError: ${'x' * 500}'.substring(0, 400)}...');
    });

    test('is null when the log has no Flutter test exception', () {
      expect(flutterTestFailureMessage('INSTRUMENTATION_STATUS: stack=java.lang.AssertionError'), isNull);
    });
  });
}
