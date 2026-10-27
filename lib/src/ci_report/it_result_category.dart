/// What one test result counts as in every report: the console summary,
/// `summary.json`, JUnit, TeamCity and every result sink. Only the
/// [failed] categories, [appDefect] and [testFailure], count as failed; every
/// other category is counted on its own, so management sees where the
/// blockers are, and none of them is ever a pass.
enum ItResultCategory {
  pass('pass', 'The test ran and passed (a MOCKED pass included).'),
  appDefect('app-defect', 'The app under test failed with a known defect (a lesson with a ticket or a bug draft).',
      failed: true),
  testFailure('test-failure', 'The test failed with no known infrastructure cause; it needs triage.', failed: true),
  credFailure(
      'cred-failure',
      'No or invalid login for the tenant and environment: no verified credentials, a rejected login, an empty '
          'credential provider with no login. Not the app login screen failing, which is a FAIL.'),
  envFailure(
      'env-failure',
      'The app environment (the backend) was down, misbehaving or refused the run for a non-credential reason, '
          'reported with its name, e.g. staging-env-failure or qa-env-failure.'),
  ltTunnelErr('lt-tunnel-err', 'The LambdaTest tunnel failed, so the devices could not reach this machine.'),
  ltFailure('lt-failure',
      'Other LambdaTest infrastructure: capacity, framework setup, test discovery, device drops or a stalled job.'),
  buildFailure(
      'build-failure',
      'A build or tooling problem stopped the tests: CocoaPods specs, an interrupted xcodebuild, Gradle, signing '
          'or packaging.'),
  testDataFailure('test-data-failure',
      'The tenant or account data the test needs is missing or shared, e.g. one user signed in by parallel sessions.'),
  deviceFailure('device-failure', 'A local emulator, simulator or phone failed: storage, memory or network.'),
  frameworkFailure('framework-failure',
      'mplatrol itself or the Patrol setup it builds failed, e.g. the driver binding replaced Patrol.'),
  notRun('not-run', 'Selected but no result arrived for an unknown reason, or the test skipped itself at runtime.'),
  notVerified('not-verified', 'A pass mplatrol could not verify, e.g. only LambdaTest reported it.'),
  noDetail(
      'no-detail',
      'A FAIL with no per-test failure detail: no test log reached mplatrol, or it holds only the generic '
          '"Dart test failed" line. The cause is unknown, so it is not counted as failed; fetch the test log '
          'and triage it.'),
  notSelected('not-selected', 'N/A: the run did not select the test, e.g. its SDK is not built for the tenant.');

  const ItResultCategory(this.label, this.description, {this.failed = false});

  /// The kebab-case name reports use; [envFailure] is named per environment by [nameFor].
  final String label;

  /// What the category means, for the docs and report legends.
  final String description;

  /// Whether the category counts as failed (FAIL); every other is counted on its own.
  final bool failed;

  /// Whether the category kept a selected test from a pass or fail verdict for a known reason
  /// outside the app and the test: credentials, environment, LambdaTest, build, test data,
  /// device or framework.
  bool get blocker => !failed && !const {pass, notRun, notVerified, noDetail, notSelected}.contains(this);

  /// The name the docs list the category by: `<env>-env-failure` for [envFailure], else [label].
  String get docName => this == envFailure ? '<env>-env-failure' : label;

  /// The category a report name from [nameFor] stands for, e.g. [envFailure] for
  /// `staging-env-failure`; null for a name no category reports.
  static ItResultCategory? named(String name) {
    for (final category in values) {
      if (category.label == name) {
        return category;
      }
    }
    return name.endsWith('-env-failure') ? envFailure : null;
  }

  /// The name reports use for a result of a run against [environment]: `<env>-env-failure`
  /// for [envFailure], e.g. `staging-env-failure`, else [label].
  String nameFor(String environment) => this == envFailure ? '${_environmentPrefix(environment)}-env-failure' : label;
}

/// The short environment name the category names use: trimmed and lower case.
String shortEnvironmentName(String environment) => environment.trim().toLowerCase();

/// The environment part of an environment failure name: at most 8 characters,
/// so the whole name stays within 20.
String _environmentPrefix(String environment) {
  final short = shortEnvironmentName(environment).replaceAll(RegExp('[^a-z0-9]+'), '');
  final named = const {'production': 'prod'}[short] ?? short;
  if (named.isEmpty) {
    return 'unknown';
  }
  return named.length > 8 ? named.substring(0, 8) : named;
}
