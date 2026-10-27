import 'dart:convert';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/lt_http.dart';

/// LambdaTest's org concurrency endpoint for real devices (App Automation API): the org's
/// `max_concurrency`, `running` and `queued` sessions.
const ltConcurrencyUrl = 'https://mobile-api.lambdatest.com/mobile-automation/api/v1/org/concurrency';

/// A reading of [ltConcurrencyUrl], or why there is none.
typedef LtCapacityReading = ({LtOrgCapacity? capacity, String? error});

/// Reads how busy the org's LambdaTest real devices are, with `LT_USERNAME` / `LT_ACCESS_KEY`.
class LtCapacityService {
  LtHttp get _http => getDep<LtHttp>();

  /// The org's sessions now, or the reason they could not be read.
  Future<LtCapacityReading> read(Map<String, String> environment) async {
    final user = environment['LT_USERNAME'] ?? '';
    final key = environment['LT_ACCESS_KEY'] ?? '';
    if (user.isEmpty || key.isEmpty) {
      return (capacity: null, error: 'LT_USERNAME / LT_ACCESS_KEY are not set');
    }
    try {
      final response =
          await _http.get(ltConcurrencyUrl, headers: _http.basicAuth(user, key), timeout: const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return (capacity: null, error: 'HTTP ${response.statusCode} from $ltConcurrencyUrl');
      }
      final data = (jsonDecode(response.body) as Map)['data'] as Map;
      return (
        capacity: LtOrgCapacity(
          max: (data['max_concurrency'] as num).toInt(),
          running: (data['running'] as num).toInt(),
          queued: (data['queued'] as num).toInt(),
        ),
        error: null,
      );
    } on Object {
      return (capacity: null, error: 'unexpected answer from $ltConcurrencyUrl');
    }
  }

  /// One line for `mplatrol doctor`: the org's LambdaTest usage, or why it is unknown.
  Future<String> summary(Map<String, String> environment) async {
    final (:capacity, :error) = await read(environment);
    if (capacity == null) {
      return 'LambdaTest org usage unknown: $error';
    }
    return 'LambdaTest org usage: ${capacity.running} of ${capacity.max} sessions running, ${capacity.queued} queued';
  }
}

/// The org's real-device sessions as LambdaTest reports them.
class LtOrgCapacity {
  /// Creates a reading.
  const LtOrgCapacity({required this.max, required this.running, required this.queued});

  /// The org's concurrency limit.
  final int max;

  /// Sessions running now, ours included.
  final int running;

  /// Sessions queued now.
  final int queued;

  /// Sessions nobody runs or waits for.
  int get free => max - running - queued < 0 ? 0 : max - running - queued;

  /// As JSON for reports.
  Map<String, Object?> toJson() => {'max': max, 'running': running, 'queued': queued};
}
