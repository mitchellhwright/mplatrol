import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_test_result.dart';
import 'package:xml/xml.dart';

/// Renders [results] as one JUnit XML document that GitLab
/// (`artifacts:reports:junit`), GitHub test reporters, TeamCity and test-management importers read: one
/// `<testsuite>` per leg, one `<testcase>` per test and device.
///
/// Only a failed category (`app-defect`, `test-failure`) is a `<failure>`,
/// typed with its category. Every other non-pass, from `cred-failure` and
/// `qa-env-failure` to `lt-tunnel-err`, `build-failure`, `not-run` and
/// `not-selected`, is a `<skipped>` whose `type` and message name its category:
/// GitLab and TeamCity count both `<failure>` and `<error>` as failed tests, and
/// only `<skipped>` keeps a blocker out of their failed counts. Such a leg is
/// still never green: the exit code, the TeamCity build problem and
/// summary.json say so. Every test carries the `mplatrol.category` property. A
/// MOCKED pass carries a ` [MOCKED]` name suffix and the `mplatrol.mocked`
/// property. With no results at all the report is one `<error>`, so an empty
/// run never reads green. [timestamp] is the run start.
String renderJUnitReport(List<ItTestResult> results, {required DateTime timestamp}) {
  final legs = <ItRunLeg, List<ItTestResult>>{};
  for (final result in results) {
    legs.putIfAbsent(result.leg, () => []).add(result);
  }
  final builder = XmlBuilder()..processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.element('testsuites', nest: () {
    _counts(builder, results);
    builder.attribute('name', 'mplatrol');
    for (final MapEntry(key: leg, value: tests) in legs.entries) {
      _suite(builder, leg, tests, timestamp);
    }
    if (results.isEmpty) {
      _noResults(builder, timestamp);
    }
  });
  return builder.buildDocument().toXmlString(
        pretty: true,
        preserveWhitespace: (node) =>
            node is XmlElement && const {'system-out', 'failure', 'error'}.contains(node.localName),
      );
}

void _noResults(XmlBuilder builder, DateTime timestamp) {
  const message = 'NOT VERIFIED: mplatrol run reported no Patrol test result';
  builder.element('testsuite', nest: () {
    builder
      ..attribute('name', 'mplatrol')
      ..attribute('tests', 1)
      ..attribute('failures', 0)
      ..attribute('errors', 1)
      ..attribute('skipped', 0)
      ..attribute('time', _seconds(Duration.zero))
      ..attribute('timestamp', timestamp.toUtc().toIso8601String())
      ..element('testcase', nest: () {
        builder
          ..attribute('classname', 'mplatrol.run')
          ..attribute('name', 'Patrol test results')
          ..attribute('time', _seconds(Duration.zero))
          ..element('error', nest: () {
            builder
              ..attribute('message', message)
              ..attribute('type', ItTestOutcome.notVerified.label)
              ..text(message);
          });
      });
  });
}

/// The JUnit element for [test]'s verdict, or null for a pass.
String? _verdictElement(ItTestResult test) {
  final category = test.category;
  if (category == ItResultCategory.pass) {
    return null;
  }
  return category.failed ? 'failure' : 'skipped';
}

void _counts(XmlBuilder builder, List<ItTestResult> results) {
  int count(String element) => results.where((result) => _verdictElement(result) == element).length;
  builder
    ..attribute('tests', results.isEmpty ? 1 : results.length)
    ..attribute('failures', count('failure'))
    ..attribute('errors', results.isEmpty ? 1 : count('error'))
    ..attribute('skipped', count('skipped'))
    ..attribute(
        'time', _seconds(results.fold(Duration.zero, (sum, result) => sum + (result.duration ?? Duration.zero))));
}

void _suite(XmlBuilder builder, ItRunLeg leg, List<ItTestResult> tests, DateTime timestamp) {
  builder.element('testsuite', nest: () {
    builder.attribute('name', leg.suiteName);
    _counts(builder, tests);
    builder.attribute('timestamp', timestamp.toUtc().toIso8601String());
    _properties(builder, [
      ('mplatrol.tenant', leg.tenant),
      ('mplatrol.environment', leg.environment),
      ('mplatrol.variant', leg.variant),
      ('mplatrol.buildLabel', leg.buildLabel),
      ('mplatrol.order', leg.order?.mode),
      ('mplatrol.seed', leg.order?.seed.toString()),
      ('mplatrol.ltBuildUrl', tests.first.ltBuildUrl),
      ('mplatrol.hyperexecuteJobUrl', tests.first.hyperexecuteJobUrl),
    ]);
    for (final test in tests) {
      _testCase(builder, test);
    }
  });
}

void _testCase(XmlBuilder builder, ItTestResult test) {
  final mocked = test.outcome == ItTestOutcome.mocked;
  builder.element('testcase', nest: () {
    builder
      ..attribute('classname', _xmlSafe('mplatrol.${test.leg.variant}.${test.leg.tenant}.${test.file}'))
      ..attribute('name', _xmlSafe(mocked ? '${test.name} [MOCKED]' : test.name))
      ..attribute('file', 'patrol_test/${test.file}.dart')
      ..attribute('time', _seconds(test.duration ?? Duration.zero));
    _verdict(builder, test);
    _properties(builder, [
      for (final entry in test.metadata) ('mplatrol.${_propertyKey(entry.name)}', entry.value),
      ('mplatrol.ltTestUrl', test.sessionUrl),
      if (mocked) ('mplatrol.mocked', 'true'),
    ]);
    final links = [
      if (test.retriedAfter != null) 'Retried: ${_xmlSafe(test.retriedAfter!)}',
      for (final entry in test.metadata)
        if (entry.link) '${entry.name}: ${entry.value}',
    ];
    if (links.isNotEmpty) {
      builder.element('system-out', nest: links.join('\n'));
    }
  });
}

void _verdict(XmlBuilder builder, ItTestResult test) {
  final reason = _xmlSafe(test.reason ?? test.outcome.label);
  final element = _verdictElement(test);
  if (element == null) {
    return;
  }
  builder.element(element, nest: () {
    builder
      ..attribute('message', '${test.categoryName}: $reason')
      ..attribute('type', test.categoryName);
    if (element != 'skipped') {
      builder.text(test.details == null ? reason : _xmlSafe(test.details!));
    }
  });
}

void _properties(XmlBuilder builder, List<(String, String?)> properties) {
  final present = properties.where((property) => (property.$2 ?? '').isNotEmpty).toList();
  if (present.isEmpty) {
    return;
  }
  builder.element('properties', nest: () {
    for (final (name, value) in present) {
      builder.element('property', nest: () {
        builder
          ..attribute('name', name)
          ..attribute('value', _xmlSafe(value!));
      });
    }
  });
}

String _propertyKey(String label) {
  final words = label.split(' ');
  return [
    words.first.toLowerCase(),
    for (final word in words.skip(1)) '${word[0].toUpperCase()}${word.substring(1)}',
  ].join();
}

String _seconds(Duration duration) => (duration.inMilliseconds / 1000).toStringAsFixed(3);

/// [value] without the control characters XML 1.0 cannot carry at all.
String _xmlSafe(String value) => value.replaceAll(RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
