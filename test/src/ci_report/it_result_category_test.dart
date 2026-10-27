import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:test/test.dart';

void main() {
  test('names are short kebab-case, unique, and only app-defect and test-failure count as failed', () {
    final names = [for (final category in ItResultCategory.values) category.label];
    expect(names.toSet(), hasLength(names.length));
    for (final name in names) {
      expect(name, matches(RegExp(r'^[a-z]+(-[a-z]+)*$')));
      expect(name.length, lessThanOrEqualTo(20), reason: name);
    }
    expect([
      for (final category in ItResultCategory.values)
        if (category.failed) category
    ], [
      ItResultCategory.appDefect,
      ItResultCategory.testFailure
    ]);
    expect(ItResultCategory.values.every((category) => category.description.isNotEmpty), isTrue);
  });

  test('blockers are the known non-failure causes, never a pass, a failure or a bare verdict', () {
    expect([
      for (final category in ItResultCategory.values)
        if (category.blocker) category.label
    ], [
      'cred-failure',
      'env-failure',
      'lt-tunnel-err',
      'lt-failure',
      'build-failure',
      'test-data-failure',
      'device-failure',
      'framework-failure',
    ]);
  });

  test('an environment failure is named for the environment, in at most 20 characters', () {
    String name(String environment) => ItResultCategory.envFailure.nameFor(environment);
    expect([
      for (final environment in ['QA', 'Perf', 'Dev', 'Staging', 'sandbox', 'UAT']) name(environment)
    ], [
      'qa-env-failure',
      'perf-env-failure',
      'dev-env-failure',
      'staging-env-failure',
      'sandbox-env-failure',
      'uat-env-failure',
    ]);
    expect(name('Production'), 'prod-env-failure');
    expect(name('QA Slot 12'), 'qaslot12-env-failure');
    expect(name('conversion-environment'), 'conversi-env-failure');
    expect(name('  '), 'unknown-env-failure');
    expect(ItResultCategory.credFailure.nameFor('QA'), 'cred-failure');
  });

  test('named reads a report name back, environment failures included', () {
    expect(ItResultCategory.named('lt-tunnel-err'), ItResultCategory.ltTunnelErr);
    expect(ItResultCategory.named('qa-env-failure'), ItResultCategory.envFailure);
    expect(ItResultCategory.named('FAIL'), isNull);
  });

  test('docName shows the environment failure pattern', () {
    expect(ItResultCategory.envFailure.docName, '<env>-env-failure');
    expect(ItResultCategory.buildFailure.docName, 'build-failure');
  });

  test('shortEnvironmentName trims and lower-cases the environment', () {
    expect([
      for (final environment in ['QA', ' Perf ', 'Staging']) shortEnvironmentName(environment)
    ], [
      'qa',
      'perf',
      'staging'
    ]);
  });
}
