import 'dart:async';
import 'dart:convert';

import 'package:mplatrol/src/android_instrumentation_verdict.dart';
import 'package:mplatrol/src/lt_http.dart';

const _nativeBase = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1';
const _operationBudget = Duration(seconds: 25);

/// Annotates an identified native nonpass without changing the local verdict.
///
/// Args:
///   http: Existing provider transport; errors are never printed verbatim.
///   headers: Protected authentication headers.
///   job: Verified current HyperExecute job, including its task inventory.
///   sessions: Complete current-job session inventory.
///   session: The current session whose instrumentation was classified.
///   selected: Generated native identities for the current artifact selection.
///   outcome: Matching native skip, or missing instrumentation only.
///
/// Returns:
///   A controlled diagnostic reporting verified annotation or refusal.
Future<String> annotateNativeNonpass({
  required LtHttp http,
  required Map<String, String> headers,
  required Map job,
  required List sessions,
  required Map session,
  required Set<String> selected,
  required AndroidInstrumentationOutcome outcome,
  bool android = true,
}) async {
  if (!_eligibleOutcome(outcome, android: android) ||
      !_currentOwnership(job, sessions, session, selected, android: android)) {
    return 'Native nonpass annotation refused: ambiguous identity or unsupported outcome.';
  }
  try {
    return await _annotate(http, headers, job, sessions, session, outcome: outcome, android: android);
  } on Exception catch (error) {
    return 'Native nonpass annotation unverified: ${error.runtimeType}; local nonpass retained.';
  }
}

bool _eligibleOutcome(AndroidInstrumentationOutcome outcome, {required bool android}) =>
    android && outcome == AndroidInstrumentationOutcome.skipped || outcome == AndroidInstrumentationOutcome.unavailable;

bool _currentOwnership(Map job, List sessions, Map session, Set<String> selected, {required bool android}) {
  if (!_ownershipInput(job, sessions, selected)) {
    return false;
  }
  final tasks = (job['tasks'] as List).cast<Map>().map((task) => task['id']).toSet();
  final ids = <String>{};
  final identities = <String>{};
  for (final item in sessions) {
    if (!_ownedSession(item, tasks, selected, android: android) || !ids.add(item['sessionID'] as String)) {
      return false;
    }
    identities.add(item['scenario_name'] as String);
  }
  return sessions.where((item) => identical(item, session)).length == 1 &&
      identities.length == selected.length &&
      identities.containsAll(selected);
}

bool _ownershipInput(Map job, List sessions, Set<String> selected) =>
    _jobIdentity(job) && sessions.isNotEmpty && selected.isNotEmpty;

bool _jobIdentity(Map job) {
  if (job['id'] is! String || job['tasks'] is! List) {
    return false;
  }
  if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(job['id'] as String)) {
    return false;
  }
  final tasks = job['tasks'] as List;
  return tasks.isNotEmpty &&
      tasks.every((task) => task is Map && task['id'] is String && (task['id'] as String).isNotEmpty);
}

bool _ownedSession(dynamic session, Set<dynamic> tasks, Set<String> selected, {required bool android}) {
  if (session is! Map || session['sessionID'] is! String) {
    return false;
  }
  final prefix = android ? 'AND' : 'IOS';
  return RegExp('^RMAA-$prefix-[A-Za-z0-9-]+\$').hasMatch(session['sessionID'] as String) &&
      tasks.contains(session['taskID']) &&
      selected.contains(session['scenario_name']) &&
      session['status'] == 'passed';
}

Future<String> _annotate(LtHttp http, Map<String, String> headers, Map job, List sessions, Map session,
    {required AndroidInstrumentationOutcome outcome, required bool android}) async {
  final url = '$_nativeBase/sessions/${session['sessionID']}';
  final native = await _nativeGet(http, headers, url);
  final build = _numericBuild(_sessionData(native)?['build_id']);
  if (!_nativeRecord(native, session, android: android) || build == null) {
    return 'Native nonpass annotation refused: native identity/build mismatch.';
  }
  final inventory = await _nativeGet(http, headers, '$_nativeBase/sessions?build_id=$build');
  if (!_buildInventory(inventory, sessions, build, android: android)) {
    return 'Native nonpass annotation refused: incomplete or foreign build inventory.';
  }
  final metadata = _customData(native);
  if (metadata == null) {
    return 'Native nonpass annotation refused: unsupported metadata shape.';
  }
  final label = outcome == AndroidInstrumentationOutcome.skipped ? 'SKIPPED' : 'UNVERIFIED';
  final annotation = _annotation(job, session, build, label);
  final body = {
    'status_ind': 'failed',
    'name': '[$label] native test',
    'custom_data': {...metadata, ...annotation}
  };
  final response = await http.patchJson(url, headers: headers, body: body).timeout(_operationBudget);
  if (response.statusCode != 200) {
    return 'Native $label annotation unverified: PATCH HTTP ${response.statusCode}.';
  }
  final readback = await _nativeGet(http, headers, url);
  if (!_annotationReadback(readback, native, session, annotation, body, android: android)) {
    return 'Native $label annotation unverified: same-session readback mismatch.';
  }
  return 'Native $label annotation verified; provider uses failed (no skipped enum). '
      'Local nonpass retained; HyperExecute aggregate status is not certified.';
}

Map<String, String> _annotation(Map job, Map session, String build, String label) => {
      'mplatrol_native_outcome': label,
      'mplatrol_native_reason':
          label == 'SKIPPED' ? 'matching_junit_assumption_or_status_minus_4' : 'instrumentation_unavailable',
      'mplatrol_native_job': job['id'] as String,
      'mplatrol_native_task': session['taskID'] as String,
      'mplatrol_native_session': session['sessionID'] as String,
      'mplatrol_native_build': build,
      'mplatrol_native_identity': session['scenario_name'] as String,
    };

Future<Map> _nativeGet(LtHttp http, Map<String, String> headers, String url) async {
  final response = await http.get(url, headers: headers);
  if (response.statusCode != 200) {
    throw const FormatException('Native metadata unavailable');
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map) {
    throw const FormatException('Native metadata malformed');
  }
  return decoded;
}

Map? _sessionData(Map response) => response['data'] is Map ? response['data'] as Map : null;

bool _nativeIdentity(Map response, Map session, {required bool android}) {
  final native = _sessionData(response);
  if (native == null) {
    return false;
  }
  return native['session_id'] == session['sessionID'] &&
      _optionalScenario(native, session) &&
      native['platform'].toString().toLowerCase() == (android ? 'android' : 'ios');
}

bool _optionalScenario(Map native, Map session) =>
    !native.containsKey('scenario_name') || native['scenario_name'] == session['scenario_name'];

bool _nativeRecord(Map response, Map session, {required bool android}) {
  if (!_nativeIdentity(response, session, android: android)) {
    return false;
  }
  final testId = _sessionData(response)!['test_id'];
  return testId is String && testId.isNotEmpty;
}

String? _numericBuild(Object? value) {
  final text = value.toString();
  return RegExp(r'^[1-9][0-9]*$').hasMatch(text) ? text : null;
}

bool _buildInventory(Map response, List sessions, String build, {required bool android}) {
  final data = response['data'];
  final metadata = response['metadata'];
  if (data is! List || metadata is! Map) {
    return false;
  }
  if (metadata['hasmore'] != false || metadata['total'] != sessions.length) {
    return false;
  }
  final ids = <String>{};
  for (final native in data) {
    if (!_inventoryEntry(native, sessions, build, android: android) || !ids.add(native['session_id'] as String)) {
      return false;
    }
  }
  return ids.length == sessions.length;
}

bool _inventoryEntry(dynamic native, List sessions, String build, {required bool android}) {
  if (native is! Map || _numericBuild(native['build_id']) != build) {
    return false;
  }
  final matching = sessions.where((session) => session['sessionID'] == native['session_id']);
  return matching.length == 1 && _nativeIdentity({'data': native}, matching.single as Map, android: android);
}

Map<String, dynamic>? _customData(Map response) {
  final native = _sessionData(response)!;
  final metadata = native['customdata'];
  if (metadata is Map && metadata['customData'] is Map) {
    return _stringKeyedData(metadata['customData'] as Map);
  }
  if (native['customData'] is Map) {
    return _stringKeyedData(native['customData'] as Map);
  }
  return null;
}

Map<String, dynamic>? _stringKeyedData(Map metadata) =>
    metadata.keys.every((key) => key is String) ? Map<String, dynamic>.from(metadata) : null;

bool _annotationReadback(
    Map response, Map original, Map session, Map<String, String> annotation, Map<String, dynamic> body,
    {required bool android}) {
  if (!_nativeIdentity(response, session, android: android)) {
    return false;
  }
  final native = _sessionData(response)!;
  final originalNative = _sessionData(original)!;
  if (!_readbackIdentity(native, originalNative) ||
      native['status_ind'] != 'failed' ||
      native['name'] != body['name']) {
    return false;
  }
  final metadata = _customData(response);
  return metadata != null && annotation.entries.every((entry) => metadata[entry.key] == entry.value);
}

bool _readbackIdentity(Map native, Map original) =>
    native['build_id'] == original['build_id'] && native['test_id'] == original['test_id'];
