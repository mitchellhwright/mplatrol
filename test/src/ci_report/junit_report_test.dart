import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/test_lessons.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const _ios = ItRunLeg(
    tenant: 'acme',
    environment: 'Staging',
    variant: 'lt-ios',
    buildLabel: 'mplatrol 1.0 · app 1a2b3c4d',
    order: TestOrder.random(77));
const _android = ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-android');
final _start = DateTime.utc(2026, 10, 2, 17, 57, 32);

ItTestResult _result(ItRunLeg leg, String description, ItTestOutcome outcome,
        {String? reason, bool selected = true, String? sessionId, TestLesson? lesson}) =>
    ItTestResult(
      leg: leg,
      file: 'patrol_login_test',
      description: description,
      outcome: outcome,
      reason: reason,
      selected: selected,
      ltSessionId: sessionId,
      lesson: lesson,
      duration: const Duration(milliseconds: 1500),
    );

XmlElement _case(XmlDocument document, String name) =>
    document.findAllElements('testcase').singleWhere((element) => element.getAttribute('name') == name);

void main() {
  test('one suite per leg with counts, leg properties and the run start', () {
    final document = XmlDocument.parse(renderJUnitReport([
      _result(_ios, 'pass', ItTestOutcome.pass),
      _result(_ios, 'fail', ItTestOutcome.fail, reason: 'assert'),
      _result(_android, 'unverified', ItTestOutcome.notVerified),
    ], timestamp: _start));
    final root = document.rootElement;
    expect(root.name.local, 'testsuites');
    expect([
      for (final key in ['tests', 'failures', 'errors', 'skipped', 'time']) root.getAttribute(key)
    ], [
      '3',
      '1',
      '0',
      '1',
      '4.500'
    ]);
    final suites = root.findElements('testsuite').toList();
    expect(suites.map((suite) => suite.getAttribute('name')),
        ['mplatrol acme Staging lt-ios', 'mplatrol globex Staging lt-android']);
    expect(suites.first.getAttribute('timestamp'), '2026-10-02T17:57:32.000Z');
    expect(suites.first.getAttribute('tests'), '2');
    final properties = {
      for (final property in suites.first.findElements('properties').single.findElements('property'))
        property.getAttribute('name'): property.getAttribute('value'),
    };
    expect(properties['mplatrol.buildLabel'], 'mplatrol 1.0 · app 1a2b3c4d');
    expect(properties['mplatrol.variant'], 'lt-ios');
    expect(properties['mplatrol.order'], 'random');
    expect(properties['mplatrol.seed'], '77');
  });

  test('testcase identity: classname by variant, tenant and file; name, file and time', () {
    final document =
        XmlDocument.parse(renderJUnitReport([_result(_ios, 'pass', ItTestOutcome.pass)], timestamp: _start));
    final testCase = _case(document, 'pass');
    expect(testCase.getAttribute('classname'), 'mplatrol.lt-ios.acme.patrol_login_test');
    expect(testCase.getAttribute('file'), 'patrol_test/patrol_login_test.dart');
    expect(testCase.getAttribute('time'), '1.500');
    expect(testCase.childElements.map((element) => element.name.local), ['properties']);
  });

  test('maps categories: only app-defect and test-failure fail, every other non-pass is skipped with its category', () {
    final document = XmlDocument.parse(renderJUnitReport([
      _result(_ios, 'fail', ItTestOutcome.fail, reason: 'Failed to resolve query'),
      _result(_ios, 'defect', ItTestOutcome.fail, reason: 'NPE', lesson: TestLesson.appProcessCrashed),
      _result(_ios, 'tunnel', ItTestOutcome.fail, reason: 'ERR::TUN::1', lesson: TestLesson.lambdaTestTunnel),
      _result(_ios, 'sync', ItTestOutcome.fail, reason: 'SyncError', lesson: TestLesson.loginErrorPage),
      _result(_ios, 'runtime skip', ItTestOutcome.notRun, reason: itRuntimeSkipReason),
      _result(_ios, 'unverified', ItTestOutcome.notVerified, reason: '8/16 Dart results verified'),
      _result(_ios, 'never assigned', ItTestOutcome.notRun, reason: 'infrastructure: never assigned'),
      _result(_ios, 'excluded', ItTestOutcome.notRun, reason: 'not selected: SDK not built: chatsdk', selected: false),
    ], timestamp: _start));
    String verdict(String name) => _case(document, name).childElements.first.name.local;
    String type(String name) => _case(document, name).childElements.first.getAttribute('type')!;
    expect([
      for (final name in ['fail', 'defect']) verdict(name)
    ], [
      'failure',
      'failure'
    ]);
    const blocked = ['tunnel', 'sync', 'runtime skip', 'unverified', 'never assigned', 'excluded'];
    expect([for (final name in blocked) verdict(name)], everyElement('skipped'));
    expect([
      for (final name in ['fail', 'defect', ...blocked]) type(name)
    ], [
      'test-failure',
      'app-defect',
      'lt-tunnel-err',
      'staging-env-failure',
      'not-run',
      'not-verified',
      'not-run',
      'not-selected',
    ]);
    final failure = _case(document, 'fail').getElement('failure')!;
    expect(failure.getAttribute('message'), 'test-failure: Failed to resolve query');
    expect(failure.innerText, 'Failed to resolve query');
    final skipped = _case(document, 'tunnel').getElement('skipped')!;
    expect([skipped.getAttribute('message'), skipped.innerText], ['lt-tunnel-err: ERR::TUN::1', '']);
    final properties = {
      for (final property in _case(document, 'sync').findAllElements('property'))
        property.getAttribute('name'): property.getAttribute('value'),
    };
    expect([properties['mplatrol.outcome'], properties['mplatrol.category'], properties['mplatrol.testlesson']],
        ['FAIL', 'staging-env-failure', 'loginErrorPage']);
    final suite = document.findAllElements('testsuite').single;
    expect([
      for (final key in ['failures', 'errors', 'skipped']) suite.getAttribute(key)
    ], [
      '2',
      '0',
      '6'
    ]);
  });

  test('a MOCKED pass has a name suffix and the mocked property', () {
    final document = XmlDocument.parse(renderJUnitReport(
        [_result(_ios, 'PROJ-TC-23586 MOCKED Delete Account', ItTestOutcome.mocked)],
        timestamp: _start));
    final testCase = _case(document, 'PROJ-TC-23586 MOCKED Delete Account [MOCKED]');
    final properties = {
      for (final property in testCase.findAllElements('property'))
        property.getAttribute('name'): property.getAttribute('value'),
    };
    expect(properties['mplatrol.mocked'], 'true');
    expect(properties['mplatrol.outcome'], 'MOCKED');
    expect(properties['mplatrol.ticket'], 'PROJ-TC-23586');
    expect(properties['mplatrol.testFile'], 'patrol_test/patrol_login_test.dart');
  });

  test('puts LambdaTest links in properties and system-out, without signatures', () {
    final document = XmlDocument.parse(renderJUnitReport([
      const ItTestResult(
        leg: _ios,
        file: 'f',
        description: 'with session',
        outcome: ItTestOutcome.fail,
        ltSessionId: 'RMAA-IOS-1',
        videoUrl: 'https://r2/video.mp4?verify=secret',
      ),
    ], timestamp: _start));
    final testCase = _case(document, 'with session');
    expect(
        testCase.getElement('system-out')!.innerText,
        'LambdaTest session: https://appautomation.lambdatest.com/test?testID=RMAA-IOS-1\n'
        'Video: https://r2/video.mp4');
    expect(document.toXmlString(), isNot(contains('secret')));
  });

  test('drops control characters XML cannot carry', () {
    final xml = renderJUnitReport([_result(_ios, 'ctrl', ItTestOutcome.fail, reason: 'bad\x07 \x1b[31mred')],
        timestamp: _start);
    expect(XmlDocument.parse(xml).findAllElements('failure').single.innerText, 'bad [31mred');
  });

  test('a run without results is one error, never green', () {
    final document = XmlDocument.parse(renderJUnitReport(const [], timestamp: _start));
    final root = document.rootElement;
    expect([
      for (final key in ['tests', 'failures', 'errors']) root.getAttribute(key)
    ], [
      '1',
      '0',
      '1'
    ]);
    final error = document.findAllElements('error').single;
    expect(error.getAttribute('type'), 'NOT VERIFIED');
    expect(error.innerText, 'NOT VERIFIED: mplatrol run reported no Patrol test result');
    expect(document.findAllElements('testcase').single.getAttribute('classname'), 'mplatrol.run');
  });
}
