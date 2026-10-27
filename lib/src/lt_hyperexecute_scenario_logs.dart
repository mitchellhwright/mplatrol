import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_instrumentation_log.dart';
import 'package:path/path.dart' as p;

/// What the HyperExecute CLI saves as a scenario log when the log link it follows refuses it.
const hyperexecuteAccessDenied = 'HTTP Basic: Access denied.';

/// Re-fetches the per-test (scenario) logs `hyperexecute --download-logs` saved as [hyperexecuteAccessDenied].
///
/// For real-device Espresso jobs, a scenario stage's log link (`GET /v1.0/stage/<id>/logs`) is the
/// LambdaTest session's instrumentation log on `mobile-api.lambdatest.com`, which needs the account's Basic
/// auth; the CLI follows the link without it, so every scenario log holds only the refusal. This fetches each
/// refused log again, sending the credentials only to LambdaTest hosts (a signed storage link gets none).
class HyperexecuteScenarioLogs {
  static const _api = 'https://api.hyperexecute.cloud';
  static const _maxPages = 50;

  LtHttp get _http => getDep<LtHttp>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Replaces the refused scenario logs of job [jobId] under `<workDir>/logs/<jobId>/scenarios`, using the
  /// LambdaTest Basic-auth [headers]. Best effort: a failure is a warning, never a verdict.
  Future<void> refetch({required String workDir, required String jobId, required Map<String, String> headers}) async {
    final dir = Directory(p.join(workDir, 'logs', jobId, 'scenarios'));
    _repairDoubleEncoded(dir);
    final refused = _refusedLogs(dir);
    if (refused.isEmpty) {
      return;
    }
    final scenarios = await _scenarios(jobId, headers);
    if (scenarios == null) {
      _logger.warn('[hyperexecute] ${refused.length} scenario log(s) of job $jobId say "$hyperexecuteAccessDenied" '
          'and the scenario list could not be read to fetch them again.');
      return;
    }
    var fetched = 0;
    final failures = <String>[];
    for (final scenario in scenarios) {
      final file = refused[scenario.name.replaceAll('/', '-')];
      if (file == null) {
        continue;
      }
      final failure = await _fetch(scenario.id, file, headers);
      if (failure == null) {
        fetched++;
      } else {
        failures.add('${scenario.name}: $failure');
      }
    }
    _logger.info('[hyperexecute] re-fetched $fetched of ${refused.length} scenario log(s) the CLI saved as '
        '"$hyperexecuteAccessDenied" (it follows the LambdaTest log link without the account credentials).');
    if (failures.isNotEmpty) {
      _logger.warn('[hyperexecute] ${failures.length} scenario log(s) still missing: ${failures.take(5).join('; ')}');
    }
  }

  /// Rewrites the scenario logs in [dir] that an earlier mplatrol saved double-encoded (UTF-8 read as Latin-1),
  /// so their Flutter failure banners and messages match again.
  void _repairDoubleEncoded(Directory dir) {
    if (!dir.existsSync()) {
      return;
    }
    var repaired = 0;
    for (final file in dir.listSync().whereType<File>()) {
      final text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
      final fixed = repairMojibake(text);
      if (fixed != text) {
        file.writeAsStringSync(fixed);
        repaired++;
      }
    }
    if (repaired > 0) {
      _logger.info('[hyperexecute] repaired $repaired scenario log(s) saved double-encoded (UTF-8 read as Latin-1).');
    }
  }

  /// The scenario log files in [dir] that hold only the refusal, by file name.
  Map<String, File> _refusedLogs(Directory dir) {
    if (!dir.existsSync()) {
      return const {};
    }
    return {
      for (final file in dir.listSync().whereType<File>())
        if (file.lengthSync() < 256 && file.readAsStringSync().trim() == hyperexecuteAccessDenied)
          p.basename(file.path): file,
    };
  }

  /// Every scenario of job [jobId] across the provider's pages, or null when a page cannot be read.
  Future<List<({String id, String name})>?> _scenarios(String jobId, Map<String, String> headers) async {
    final scenarios = <({String id, String name})>[];
    String? cursor;
    for (var page = 0; page < _maxPages; page++) {
      final query = cursor == null ? '' : '&cursor=${Uri.encodeQueryComponent(cursor)}';
      final response = await _http.get('$_api/v2.0/job/$jobId/scenarios?limit=20$query', headers: headers);
      final body = response.statusCode == 200 ? _json(response.body) : null;
      final data = body?['data'];
      final metadata = body?['metadata'];
      if (data is! List || metadata is! Map) {
        return null;
      }
      for (final scenario in data.whereType<Map>()) {
        final id = scenario['id'];
        final name = scenario['name'];
        if (id is String && name is String) {
          scenarios.add((id: id, name: name));
        }
      }
      final next = metadata['cursor'];
      if (metadata['hasmore'] != true || next is! String || next.isEmpty || next == cursor) {
        return scenarios;
      }
      cursor = next;
    }
    return scenarios;
  }

  /// Fetches the log of scenario stage [stageId] into [file]; the failure, or null when it was saved.
  Future<String?> _fetch(String stageId, File file, Map<String, String> headers) async {
    final link = await _http.get('$_api/v1.0/stage/$stageId/logs', headers: headers);
    final url = link.statusCode == 200 ? (_json(link.body)?['data']) : null;
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || !uri.isScheme('https')) {
      return 'no log link (HTTP ${link.statusCode})';
    }
    final lambdaTest = uri.host == 'lambdatest.com' || uri.host.endsWith('.lambdatest.com');
    final log = await _http.get(uri.toString(), headers: lambdaTest ? headers : const {});
    if (log.statusCode != 200 || log.body.trim() == hyperexecuteAccessDenied) {
      return 'HTTP ${log.statusCode} from ${uri.host}';
    }
    file.writeAsBytesSync(log.bodyBytes);
    return null;
  }

  static Map<String, Object?>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
