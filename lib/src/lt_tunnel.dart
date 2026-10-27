import 'dart:convert';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/lt_http.dart';

/// Starts one fresh LambdaTest `--mitm` tunnel and reports the name LambdaTest
/// assigned it, shared by the Android and iOS LambdaTest runners.
///
/// The tunnel name is never constructed in code. Callers either pass one through
/// from config/env (some environments route staging traffic only through a
/// specific shared tunnel name, e.g. `alkstg`), or omit it — in which case LT
/// auto-generates a unique name that we read back from its own startup log. Both
/// paths guarantee the trigger's tunnel name matches the running tunnel so the
/// device-to-staging data path binds; a name built in code (e.g. from `$USER`)
/// can contain characters LT rejects (a dot) and silently drift from what LT
/// registered, leaving the device unable to reach staging.
class LtTunnel {
  LtTunnel({this.pollDelay = const Duration(seconds: 2)});

  /// Delay between readiness poll iterations.
  final Duration pollDelay;

  /// The tunnel log line that signals it is ready for tests.
  static const _readyLine = 'You can start testing now';

  /// Max readiness poll attempts (40 x [pollDelay]).
  static const _readyAttempts = 40;

  /// LT prints the auto-assigned name on this startup line when `--tunnelName`
  /// is omitted: `Tunnel Name was not specified, using: <name>`.
  static final _namePattern = RegExp(r'Tunnel Name was not specified, using:\s*(\S+)');

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Launches one fresh `--mitm` tunnel in the background, waits for it to
  /// report ready, and returns its process handle (so the caller kills it on
  /// every path), whether it became ready, and the name to pass to the run
  /// trigger.
  ///
  /// This starts only its own tunnel and never touches other processes; leaked
  /// tunnels from earlier runs are harmless here (each run uses a distinct
  /// tunnel name) and are cleared deliberately by `mplatrol clean`.
  ///
  /// When [tunnelName] is non-empty it is passed to LT verbatim (the value
  /// staging routing requires, supplied by config/env); otherwise LT
  /// auto-generates a unique name that is read back from its startup log.
  Future<({MplatrolProcess process, bool ready, String name})> start({
    required String ltBin,
    required String ltUser,
    required String ltKey,
    String? tunnelName,
  }) async {
    final requested = tunnelName ?? '';
    _logger.info(
      requested.isEmpty
          ? 'Starting a single fresh LambdaTest tunnel'
          : 'Starting a single fresh LambdaTest tunnel "$requested"',
    );
    final process = await _shell.start(ltBin, [
      '--user',
      ltUser,
      '--key',
      ltKey,
      if (requested.isNotEmpty) ...['--tunnelName', requested],
      '--mitm',
    ]);

    for (var attempt = 0; attempt < _readyAttempts; attempt++) {
      if (process.output.contains(_readyLine)) {
        final name = requested.isNotEmpty ? requested : _namePattern.firstMatch(process.output)?.group(1) ?? '';
        if (name.isEmpty) {
          _logger.err('Tunnel became ready but its name could not be read');
          return (process: process, ready: false, name: '');
        }
        _logger.info('Tunnel ready ($name)');
        final registered = await _waitForApiRegistration(name: name, ltUser: ltUser, ltKey: ltKey);
        return (process: process, ready: registered, name: name);
      }
      await Future<void>.delayed(pollDelay);
    }
    _logger.err('Tunnel did not become ready');
    return (process: process, ready: false, name: '');
  }

  /// Blocks until [name] shows up in the LT tunnels API.
  ///
  /// The tunnel's "You can start testing now" line is local readiness only —
  /// the record takes a few more seconds to propagate to the tunnels API.
  /// HyperExecute validates `tunnelNames` against that API once, immediately,
  /// with no retry, and aborts the whole job on a miss (ERR::TUN::RESP), so
  /// the handoff must not race the propagation. While the account has no
  /// tunnels LT serves `"data": {}` (a single map, not an array); both that
  /// shape and an empty array mean not-registered-yet.
  Future<bool> _waitForApiRegistration({required String name, required String ltUser, required String ltKey}) async {
    final http = getDep<LtHttp>();
    for (var attempt = 0; attempt < _readyAttempts; attempt++) {
      try {
        final response = await http.get(
          'https://api.lambdatest.com/automation/api/v1/tunnels',
          headers: http.basicAuth(ltUser, ltKey),
        );
        if (response.statusCode == 200 && _containsRunning(response.body, name)) {
          _logger.info('Tunnel "$name" registered with the LT tunnels API');
          return true;
        }
      } catch (_) {
        // Transient API failure — keep polling until the attempt budget ends.
      }
      await Future<void>.delayed(pollDelay);
    }
    _logger.err(
      'Tunnel "$name" never appeared in the LambdaTest tunnels API; '
      'HyperExecute would reject it (ERR::TUN::RESP). Check the tunnel '
      'process and LT credentials.',
    );
    return false;
  }

  static bool _containsRunning(String body, String name) {
    final decoded = jsonDecode(body);
    final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
    if (data is! List) {
      return false;
    }
    return data.any(
      (tunnel) => tunnel is Map<String, dynamic> && tunnel['tunnel_name'] == name && tunnel['status_ind'] == 'running',
    );
  }
}
