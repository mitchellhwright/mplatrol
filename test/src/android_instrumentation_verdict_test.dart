import 'dart:io';

import 'package:mplatrol/src/android_instrumentation_verdict.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _identity = 'mplatrol.e2e.SampleTest/selected_test';

String _log(int code, {String stack = '', String identity = _identity}) {
  final parts = identity.split('/');
  return 'INSTRUMENTATION_STATUS: class=${parts[0]}\n'
      'INSTRUMENTATION_STATUS: test=${parts[1]}\n'
      '${stack.isEmpty ? '' : 'INSTRUMENTATION_STATUS: stack=$stack\n'}'
      'INSTRUMENTATION_STATUS_CODE: $code\n'
      'INSTRUMENTATION_CODE: -1\n';
}

AndroidInstrumentationOutcome _outcome(String log) =>
    androidInstrumentationVerdict(log, nativeIdentity: _identity).outcome;

void _registerTerminalCases() {
  group('matching terminal instrumentation', () {
    test('actual controlled CardHub native skip remains skipped', () {
      final log = File(p.join('test', 'fixtures', 'integration_test', 'android_runtime_assumption_skip.log'))
          .readAsStringSync();
      final verdict = androidInstrumentationVerdict(log,
          nativeIdentity: 'mplatrol.e2e.CardhubUserJourneyTest/'
              'opens_a_card_and_its_Alerts_and_Controls_through_CardHub');
      expect(verdict.outcome, AndroidInstrumentationOutcome.skipped);
    });
    test('a native skip names the markTestSkipped reason the assumption carries', () {
      final verdict = androidInstrumentationVerdict(
          _log(-4, stack: 'org.junit.AssumptionViolatedException: MOCK_TENANT_MISMATCH PROJ-TC-23589 needs soylent'),
          nativeIdentity: _identity);
      expect(verdict.outcome, AndroidInstrumentationOutcome.skipped);
      expect(verdict.detail, 'native test $_identity skipped: MOCK_TENANT_MISMATCH PROJ-TC-23589 needs soylent');
    });
    test('a native skip with only the generic Patrol message keeps the generic detail', () {
      final log = File(p.join('test', 'fixtures', 'integration_test', 'android_runtime_assumption_skip.log'))
          .readAsStringSync();
      final verdict = androidInstrumentationVerdict(log,
          nativeIdentity: 'mplatrol.e2e.CardhubUserJourneyTest/'
              'opens_a_card_and_its_Alerts_and_Controls_through_CardHub');
      expect(verdict.detail, contains('skipped (JUnit assumption/status -4)'));
    });
    test('status zero and completed runner prove a pass', () {
      expect(_outcome(_log(0)), AndroidInstrumentationOutcome.passed);
    });
    test('status -4 alone proves a native skip', () {
      expect(_outcome(_log(-4)), AndroidInstrumentationOutcome.skipped);
    });
    test('matching assumption exception cannot become status-zero pass', () {
      expect(_outcome(_log(0, stack: 'org.junit.AssumptionViolatedException: Dart test skipped')),
          AndroidInstrumentationOutcome.skipped);
    });
    for (final code in [-1, -2]) {
      test('terminal status $code is not passed', () {
        expect(_outcome(_log(code)), AndroidInstrumentationOutcome.failed);
      });
    }
    test('non-assumption stack contradicts status-zero pass', () {
      expect(_outcome(_log(0, stack: 'java.lang.AssertionError: SDK failed')), AndroidInstrumentationOutcome.failed);
    });
    test('skip remains non-pass alongside a passing block', () {
      expect(_outcome(_log(-4) + _log(0)), AndroidInstrumentationOutcome.skipped);
    });
    test('failure remains non-pass alongside a passing block', () {
      expect(_outcome(_log(-2) + _log(0)), AndroidInstrumentationOutcome.failed);
    });
  });
}

void _registerIdentityAndAvailabilityCases() {
  group('instrumentation provenance', () {
    for (final code in [-3, 2, 99]) {
      test('unclassified status $code is unavailable, not an invented failure', () {
        expect(_outcome(_log(code)), AndroidInstrumentationOutcome.unavailable);
      });
    }
    for (final text in [
      '',
      'OK (1 test)',
      'AssumptionViolatedException',
      'Documentation: INSTRUMENTATION_STATUS_CODE: -4'
    ]) {
      test('unidentified text cannot prove execution: $text', () {
        expect(_outcome(text), AndroidInstrumentationOutcome.unavailable);
      });
    }
    test('unselected assumption cannot skip the selected passing test', () {
      final other = _log(-4, identity: 'com.example.OtherTest/not_selected');
      expect(
          _outcome(other.replaceAll('INSTRUMENTATION_CODE: -1\n', '') + _log(0)), AndroidInstrumentationOutcome.passed);
    });
    test('unselected status cannot supply selected execution evidence', () {
      expect(_outcome(_log(-4, identity: 'com.example.OtherTest/not_selected')),
          AndroidInstrumentationOutcome.unavailable);
    });
    test('anonymous status -4 is not attributed to a selected test', () {
      expect(_outcome('INSTRUMENTATION_STATUS_CODE: -4\n'), AndroidInstrumentationOutcome.unavailable);
    });
    test('start without terminal outcome fails closed', () {
      expect(_outcome(_log(1)), AndroidInstrumentationOutcome.unavailable);
    });
    test('terminal block without runner completion fails closed', () {
      expect(_outcome(_log(0).replaceAll('INSTRUMENTATION_CODE: -1\n', '')), AndroidInstrumentationOutcome.unavailable);
    });
    test('malformed terminal status cannot be ignored beside a pass', () {
      final invalid = _log(0).replaceAll('STATUS_CODE: 0', 'STATUS_CODE: invalid');
      expect(_outcome(invalid + _log(0)), AndroidInstrumentationOutcome.unavailable);
    });
    test('stream prose mentioning an assumption is not a skip', () {
      final log = _log(0).replaceAll(
          'INSTRUMENTATION_STATUS_CODE: 0',
          'INSTRUMENTATION_STATUS: stream=org.junit.AssumptionViolatedException\n'
              'INSTRUMENTATION_STATUS_CODE: 0');
      expect(_outcome(log), AndroidInstrumentationOutcome.passed);
    });
    test('similarly named exception is not a JUnit assumption skip', () {
      expect(_outcome(_log(0, stack: 'org.junit.AssumptionViolatedExceptionExample: incidental')),
          AndroidInstrumentationOutcome.failed);
    });
  });
}

void main() {
  _registerTerminalCases();
  _registerIdentityAndAvailabilityCases();
  _registerCompletionConsistencyCases();
}

void _registerCompletionConsistencyCases() {
  group('single current native instrumentation run', () {
    for (final code in ['-1', '0', 'invalid']) {
      test('later completion $code cannot follow an earlier successful code', () {
        expect(_outcome('${_log(0)}INSTRUMENTATION_CODE: $code\n'), AndroidInstrumentationOutcome.unavailable);
      });
    }
    test('earlier contradictory completion cannot be hidden by final -1', () {
      expect(_outcome('INSTRUMENTATION_CODE: 0\n${_log(0)}'), AndroidInstrumentationOutcome.unavailable);
    });
    final pending = 'INSTRUMENTATION_STATUS: class=${_identity.split('/')[0]}\n'
        'INSTRUMENTATION_STATUS: test=${_identity.split('/')[1]}\n';
    for (final suffix in ['', 'INSTRUMENTATION_STATUS_CODE: 1\n', 'INSTRUMENTATION_STATUS_CODE: 0\n']) {
      test('selected status after runner completion is incomplete: $suffix', () {
        expect(_outcome('${_log(0)}$pending$suffix'), AndroidInstrumentationOutcome.unavailable);
      });
    }
    test('selected pending status before final runner completion is incomplete', () {
      final pass = _log(0).replaceAll('INSTRUMENTATION_CODE: -1\n', '');
      expect(_outcome('$pass${pending}INSTRUMENTATION_CODE: -1\n'), AndroidInstrumentationOutcome.unavailable);
    });
    test('selected restart before final runner completion is incomplete', () {
      final pass = _log(0).replaceAll('INSTRUMENTATION_CODE: -1\n', '');
      expect(
          _outcome('$pass$pending'
              'INSTRUMENTATION_STATUS_CODE: 1\nINSTRUMENTATION_CODE: -1\n'),
          AndroidInstrumentationOutcome.unavailable);
    });
    test('completion-code prose cannot contradict an actual completion', () {
      expect(_outcome('${_log(0)}Documentation: INSTRUMENTATION_CODE: 0\n'), AndroidInstrumentationOutcome.passed);
    });
    test('unselected pending block cannot impersonate the selected identity', () {
      expect(
          _outcome('${_log(0)}INSTRUMENTATION_STATUS: class=OtherTest\n'
              'INSTRUMENTATION_STATUS: test=other_test\n'),
          AndroidInstrumentationOutcome.passed);
    });
  });
}
