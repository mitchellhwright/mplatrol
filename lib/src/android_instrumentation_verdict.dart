import 'package:mplatrol/src/ci_report/it_test_result.dart';

/// Outcomes proved by a matching AndroidJUnitRunner status block.
enum AndroidInstrumentationOutcome { passed, skipped, failed, unavailable }

/// Classifies instrumentation for the selected generated native test identity.
///
/// Args:
///   output: Current-session instrumentation log, not provider summary prose.
///   nativeIdentity: Generated `class/method` identity verified for this session.
///
/// Returns:
///   A terminal outcome and diagnostic; missing identity/status fails closed.
({AndroidInstrumentationOutcome outcome, String detail}) androidInstrumentationVerdict(String output,
    {required String nativeIdentity}) {
  final outcomes = <AndroidInstrumentationOutcome>{};
  String? skipReason;
  for (final block in _instrumentationBlocks(output)) {
    final identity = '${block.fields['class']}/${block.fields['test']}';
    if (identity != nativeIdentity) {
      continue;
    }
    final outcome = _terminalOutcome(block.fields, block.code);
    if (outcome != null) {
      outcomes.add(outcome);
    }
    skipReason ??= _assumptionMessage(block.fields['stack']);
  }
  if (outcomes.contains(AndroidInstrumentationOutcome.skipped)) {
    return (
      outcome: AndroidInstrumentationOutcome.skipped,
      detail: itSkipHasReason(skipReason)
          ? 'native test $nativeIdentity skipped: $skipReason'
          : 'native test $nativeIdentity skipped (JUnit assumption/status -4); '
              'a native skip is not a pass'
    );
  }
  if (outcomes.contains(AndroidInstrumentationOutcome.failed)) {
    return (
      outcome: AndroidInstrumentationOutcome.failed,
      detail: 'native test $nativeIdentity reported a failed instrumentation status'
    );
  }
  if (_isCompletePass(outcomes, output, nativeIdentity)) {
    return (outcome: AndroidInstrumentationOutcome.passed, detail: 'native test $nativeIdentity passed');
  }
  return (
    outcome: AndroidInstrumentationOutcome.unavailable,
    detail: 'no unambiguous terminal instrumentation evidence for $nativeIdentity'
  );
}

bool _isCompletePass(Set<AndroidInstrumentationOutcome> outcomes, String output, String nativeIdentity) {
  if (outcomes.length != 1 || !outcomes.contains(AndroidInstrumentationOutcome.passed)) {
    return false;
  }
  final completions = <int?>[];
  int? lastSelectedStatus;
  for (final block in _instrumentationBlocks(output)) {
    if (block.completion) {
      completions.add(block.code);
    } else if ('${block.fields['class']}/${block.fields['test']}' == nativeIdentity) {
      if (completions.isNotEmpty) {
        return false;
      }
      lastSelectedStatus = block.code;
    }
  }
  return _hasSuccessfulCompletion(completions, lastSelectedStatus);
}

bool _hasSuccessfulCompletion(List<int?> completions, int? selectedStatus) =>
    completions.length == 1 && completions.single == -1 && selectedStatus == 0;

Iterable<({Map<String, String> fields, int? code, bool completion})> _instrumentationBlocks(String output) sync* {
  var fields = <String, String>{};
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    const status = 'INSTRUMENTATION_STATUS: ';
    const code = 'INSTRUMENTATION_STATUS_CODE: ';
    const completion = 'INSTRUMENTATION_CODE: ';
    if (line.startsWith(status)) {
      final value = line.substring(status.length);
      final equals = value.indexOf('=');
      if (equals > 0) {
        fields[value.substring(0, equals)] = value.substring(equals + 1);
      }
    } else if (line.startsWith(code)) {
      yield (fields: fields, code: int.tryParse(line.substring(code.length)), completion: false);
      fields = <String, String>{};
    } else if (line.startsWith(completion)) {
      if (fields.isNotEmpty) {
        yield (fields: fields, code: null, completion: false);
      }
      yield (fields: const <String, String>{}, code: int.tryParse(line.substring(completion.length)), completion: true);
      fields = <String, String>{};
    }
  }
  if (fields.isNotEmpty) {
    yield (fields: fields, code: null, completion: false);
  }
}

AndroidInstrumentationOutcome? _terminalOutcome(Map<String, String> fields, int? code) {
  if (code == 1) {
    return null;
  }
  final assumption = RegExp(r'^org\.junit\.AssumptionViolatedException(?::|\s|$)');
  if (code == -4 || assumption.hasMatch(fields['stack'] ?? '')) {
    return AndroidInstrumentationOutcome.skipped;
  }
  if ((fields['stack'] ?? '').isNotEmpty) {
    return AndroidInstrumentationOutcome.failed;
  }
  if (code == 0) {
    return AndroidInstrumentationOutcome.passed;
  }
  return code == -1 || code == -2 ? AndroidInstrumentationOutcome.failed : AndroidInstrumentationOutcome.unavailable;
}

/// The message of the `AssumptionViolatedException` a runtime skip throws: the
/// test's own `markTestSkipped` reason, which Patrol passes to `assumeTrue`.
String? _assumptionMessage(String? stack) =>
    RegExp(r'^org\.junit\.AssumptionViolatedException: (.+)$', multiLine: true).firstMatch(stack ?? '')?[1]?.trim();
