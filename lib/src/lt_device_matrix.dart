import 'dart:io';
import 'dart:math';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:path/path.dart' as p;

/// One device's HyperExecute job: the LambdaTest device spec, the LT build
/// name its sessions are filed under, and the directory the HyperExecute CLI
/// runs in (where it writes its yaml, `LT` binary and `hyperexecute-cli.log`).
typedef LtDeviceJobSpec = ({String device, String buildName, String workDir});

/// Runs one HyperExecute job for [spec], returning the job's exit code.
typedef LtDeviceJob = Future<int> Function(LtDeviceJobSpec spec);

/// Runs [runJob] once per device in [devices], so every device gets its own
/// HyperExecute job, LT build and verdict, with up to [maxConcurrent] jobs in
/// flight at once (default: all devices). Job `i` starts no earlier than
/// `i * startSpacing` after the first: LambdaTest rate-limits its API per
/// account (HTTP 429 "40 GET calls per minute"), and nine HyperExecute CLIs
/// starting in the same second all failed framework setup with that 429.
///
/// HyperExecute's `deviceSelectionStrategy: any` runs a job on only one of the
/// listed devices, and `all` would mix every device's sessions into one
/// verdict. A job per device keeps the per-job verdict logic unchanged and
/// the results attributable to a device.
///
/// A single device keeps [buildName] and runs in [repo], exactly as before.
/// With several devices each job gets a device-suffixed build name (see
/// [ltDeviceBuildName]) so LT build/session lookups never see another device's
/// sessions, and its own work directory under `<repo>/.mplatrol/he-jobs/` so
/// concurrent HyperExecute CLIs never share a yaml, tunnel binary or CLI log
/// (the stall watchdog reads that log). Every device runs even after a
/// failure; a per-device summary is logged in [devices] order and the first
/// non-success exit code in that order is returned.
Future<int> runOnEachLtDevice({
  required String platform,
  required String repo,
  required List<String> devices,
  required String buildName,
  required LtDeviceJob runJob,
  required MplatrolLogger logger,
  int? maxConcurrent,
  Duration startSpacing = Duration.zero,
}) async {
  if (devices.length == 1) {
    return runJob((device: devices.single, buildName: buildName, workDir: repo));
  }
  final specs = [
    for (final device in devices)
      (
        device: device,
        buildName: ltDeviceBuildName(buildName, device),
        workDir: p.join(repo, '.mplatrol', 'he-jobs', ltDeviceBuildName(platform, device)),
      ),
  ];
  final workers = min(maxConcurrent ?? specs.length, specs.length);
  logger.info('[device-matrix] $platform: ${specs.length} devices, '
      '$workers HyperExecute job(s) at a time, starts '
      '${startSpacing.inSeconds}s apart');
  final codes = List<int>.filled(specs.length, ExitCode.success.code);
  final clock = Stopwatch()..start();
  var next = 0;
  Future<void> worker() async {
    while (next < specs.length) {
      final index = next++;
      final spec = specs[index];
      Directory(spec.workDir).createSync(recursive: true);
      final wait = startSpacing * index - clock.elapsed;
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      logger.info('[device-matrix] $platform start ${index + 1}/${specs.length}: '
          '${spec.device} (LT build "${spec.buildName}")');
      codes[index] = await runJob(spec);
      logger.info('[device-matrix] $platform done: ${spec.device} -> '
          '${ltDeviceVerdict(codes[index])}');
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  logger.info('[device-matrix] $platform verdicts per device:');
  for (final (index, spec) in specs.indexed) {
    logger.info('  ${ltDeviceVerdict(codes[index])}  ${spec.device}  '
        '(exit ${codes[index]}, LT build "${spec.buildName}")');
  }
  return ltFirstNonSuccess(codes);
}

/// The combined exit code of several HyperExecute jobs: the first non-success
/// code in [codes] order, else success.
int ltFirstNonSuccess(Iterable<int> codes) => codes.firstWhere(
      (code) => code != ExitCode.success.code,
      orElse: () => ExitCode.success.code,
    );

/// The LT build name for [device] in a multi-device run: [buildName] plus the
/// device spec reduced to letters, digits and dots, e.g.
/// `LoginE2EiOS-iPhone_SE_2020_17`.
String ltDeviceBuildName(String buildName, String device) {
  final pool = ltDevicePool(device);
  final first = pool.isEmpty ? device : pool.first;
  final slug = first.replaceAll(RegExp('[^A-Za-z0-9.]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return pool.length > 1 ? '$buildName-${slug}_pool${pool.length}' : '$buildName-$slug';
}

/// The LambdaTest device specs one HyperExecute job may run on.
///
/// A spec lists alternatives separated by `|` (a pool); the job's YAML lists
/// them all with `deviceSelectionStrategy: any`, so each run takes whichever
/// qualifying device is free instead of queueing for one model. A spec without
/// `|` pins exactly that device, for evidence that needs a specific model.
List<String> ltDevicePool(String spec) => [
      for (final device in spec.split('|'))
        if (device.trim().isNotEmpty) device.trim()
    ];

/// The summary word for a HyperExecute job exit code: the runners return
/// `unavailable` when the provider result could not be verified as a pass
/// (including an iOS skip), which is not the same as a failed test.
String ltDeviceVerdict(int code) {
  if (code == ExitCode.success.code) {
    return 'PASS';
  }
  return code == ExitCode.unavailable.code ? 'NOT VERIFIED' : 'FAIL';
}
