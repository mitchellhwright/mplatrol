import 'dart:convert';

import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:test/test.dart';

final _files = [
  PatrolTestFile(basename: 'patrol_login_test', tests: [
    PatrolTest(method: 'reaches', description: 'reaches accounts after credentials MFA'),
  ]),
  PatrolTestFile(basename: 'login_faults_test', tests: [
    PatrolTest(method: 'fast', description: 'fast-fails on a bad credential'),
    PatrolTest(method: 'other', description: 'shows the error screen'),
  ]),
  PatrolTestFile(basename: 'spanish_device_locale_test', tests: [
    PatrolTest(method: 'es', description: 'shows translated navigation'),
  ]),
];

void main() {
  test('selects every test under its Dart test name', () {
    expect(patrolSelectedTests(_files).map((test) => (test.id, test.file)), [
      ('patrol_login_test reaches accounts after credentials MFA', 'patrol_login_test'),
      ('login_faults_test fast-fails on a bad credential', 'login_faults_test'),
      ('login_faults_test shows the error screen', 'login_faults_test'),
      ('spanish_device_locale_test shows translated navigation', 'spanish_device_locale_test'),
    ]);
  });

  test('reads the pass, fail and skip lines Patrol printed, ANSI and all', () {
    const output = '''
🧪 patrol_login_test reaches accounts after credentials MFA
✅ reaches accounts after credentials MFA \x1B[90m(patrol_test/patrol_login_test.dart)\x1B[0m \x1B[90m(52s)\x1B[0m
❌ fast-fails on a bad credential (patrol_test/login_faults_test.dart) (12s)
TimeoutException: STEP pre_login_gates: neither a usable credential form nor completed onboarding appeared
⏩ spanish_device_locale_test shows translated navigation
❌ shows the error screen (patrol_test/login_faults_test.dart)

✅ unrelated test (patrol_test/other_test.dart) (1s)
✅ shows translated navigation (patrol_test/patrol_login_test.dart) (3s)
Test summary:
📝 Total: 4
''';
    expect(parsePatrolConsoleResults(output, _files), [
      (
        id: 'patrol_login_test reaches accounts after credentials MFA',
        outcome: ItTestOutcome.pass,
        duration: const Duration(seconds: 52),
        reason: null,
        details: null,
      ),
      (
        id: 'login_faults_test fast-fails on a bad credential',
        outcome: ItTestOutcome.fail,
        duration: const Duration(seconds: 12),
        reason: 'TimeoutException: STEP pre_login_gates: neither a usable credential form nor completed onboarding '
            'appeared',
        details: 'TimeoutException: STEP pre_login_gates: neither a usable credential form nor completed onboarding '
            'appeared',
      ),
      (
        id: 'spanish_device_locale_test shows translated navigation',
        outcome: ItTestOutcome.notRun,
        duration: null,
        reason: itRuntimeSkipReason,
        details: null,
      ),
      (
        id: 'login_faults_test shows the error screen',
        outcome: ItTestOutcome.fail,
        duration: null,
        reason: 'Patrol reported the test failed',
        details: null,
      ),
    ]);
  });

  test('a failure line followed by another verdict has no error text', () {
    const output = '❌ fast-fails on a bad credential\n✅ shows the error screen\n';
    expect(parsePatrolConsoleResults(output, _files).first.reason, 'Patrol reported the test failed');
  });

  test('shortens a long error line', () {
    final output = '❌ fast-fails on a bad credential\n${'x' * 400}\n';
    expect(parsePatrolConsoleResults(output, _files).single.reason, '${'x' * 300}...');
  });

  test('keeps the whole failure block and joins the wrapped exception message', () {
    const output = '''
❌ fast-fails on a bad credential (patrol_test/login_faults_test.dart) (33s)
\x1B[31m══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞═════════════════\x1B[0m
\x1B[31mThe following StateError was thrown running a test:\x1B[0m
\x1B[31mBad state: Push Notifications requires one current actionable\x1B[0m
\x1B[31msettings switch.\x1B[0m

When the exception was thrown, this was the stack:
#0      PushSdkPushSettingsPage._toggleFinder (package:app/e2e/pushsdk_push_settings_page.dart:198:7)
<asynchronous suspension>
The test description was:
  fast-fails on a bad credential
═════════════════════════════════════════════════════════════════
🧪 login_faults_test shows the error screen
❌ shows the error screen (patrol_test/login_faults_test.dart)

#0      main.<anonymous closure> (file:///login_faults_test.dart:51:5)

Test summary:
''';
    final results = parsePatrolConsoleResults(output, _files);
    expect(results.first.reason, 'Bad state: Push Notifications requires one current actionable settings switch.');
    expect(results.first.details, '''
The following StateError was thrown running a test:
Bad state: Push Notifications requires one current actionable
settings switch.

When the exception was thrown, this was the stack:
#0      PushSdkPushSettingsPage._toggleFinder (package:app/e2e/pushsdk_push_settings_page.dart:198:7)
<asynchronous suspension>
The test description was:
  fast-fails on a bad credential''');
    expect(results.last.reason, '#0      main.<anonymous closure> (file:///login_faults_test.dart:51:5)');
  });

  test('bounds a long failure block', () {
    final frames = List.generate(100, (i) => '#$i frame').join('\n');
    final output = '❌ fast-fails on a bad credential\nmessage\n$frames\n';
    final details = parsePatrolConsoleResults(output, _files).single.details!;
    expect(details.split('\n'), hasLength(81));
    expect(details, endsWith('… 21 more line(s) in the build log'));
    final wide = '❌ fast-fails on a bad credential\n${List.generate(70, (i) => 'y' * 200).join('\n')}\n';
    expect(parsePatrolConsoleResults(wide, _files).single.details, hasLength(8003));
  });

  test('finds nothing in output without verdict lines', () {
    expect(parsePatrolConsoleResults('BUILD FAILED\n', _files), isEmpty);
  });

  test('reads the reasons iOS gave for skipped tests from the xcresult action log line', () {
    final log = jsonEncode({
      'title': 'Test action',
      'messages': <Object>[],
      'subsections': [
        {
          'title': 'Run test case testBShowsTranslatedNavigation()',
          'messages': [
            {'title': 'Test skipped - DEVICE_LOCALE_MISMATCH SPANISH the device locale is not Spanish'},
          ],
        },
        {
          'title': 'Run test case testAFastFailsOnABadCredential()',
          'messages': [
            {'title': 'Some other message'},
          ],
          'subsections': 'not a list',
        },
        'not a section',
      ],
    });
    final output = '⏩ spanish_device_locale_test shows translated navigation\n$log\n{not json Test skipped - X}\n';
    expect(iosSkipReasons(output, _files), {
      'spanish_device_locale_test shows translated navigation':
          'DEVICE_LOCALE_MISMATCH SPANISH the device locale is not Spanish',
    });
    expect(iosSkipReasons('⏩ spanish_device_locale_test shows translated navigation', _files), isEmpty);
  });
}
