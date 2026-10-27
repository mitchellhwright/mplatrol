import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/base_command.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/disk/disk.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_leg_runner.dart';
import 'package:mplatrol/src/matrix/matrix_local_devices.dart';
import 'package:mplatrol/src/matrix/matrix_publish_state.dart';
import 'package:mplatrol/src/matrix/matrix_publisher.dart';
import 'package:mplatrol/src/matrix/matrix_scheduler.dart';
import 'package:mplatrol/src/matrix/matrix_timings.dart';
import 'package:path/path.dart' as p;

/// `mplatrol matrix` runs a tenant × variant matrix on a pool of lane checkouts:
/// LambdaTest legs and local emulator/simulator legs (one per platform at a
/// time machine-wide), iOS and Android legs interleaved, each lane free again
/// once its LambdaTest leg uploaded (a local leg holds it until it exits), a
/// disk guard, per-leg reports and logs in the run directory,
/// a run id, a timings report and publish hooks. The hooks run as legs finish (at most
/// every 10 minutes) and when the round ends however it ends: after the last leg, on SIGINT, SIGTERM
/// or SIGHUP (the legs are stopped and the round is marked partial) or on a fatal error. A leg that
/// runs longer than its variant's cap is stopped as `lt-failure` (`device-failure` when local) and the
/// round continues.
class ItMatrixCommand extends BaseCommand {
  /// Creates the command; [start] and [mplatrolCommand] are injectable for tests.
  ItMatrixCommand({
    MatrixProcessStarter? start,
    List<String>? mplatrolCommand,
    List<Stream<ProcessSignal>> Function()? signals,
  })  : _start = start ?? startMatrixProcess,
        _mplatrolCommand = mplatrolCommand,
        _signals = signals ?? _processSignals {
    argParser
      ..addOption('run-dir', valueHelp: 'dir', help: 'New directory for the run: queue.log, leg logs, legs/<leg>/.')
      ..addMultiOption('lane',
          valueHelp: 'app checkout', splitCommas: false, help: 'A prepared lane checkout; one per lane.')
      ..addMultiOption('leg',
          valueHelp: 'leg',
          splitCommas: false,
          help: 'A leg to run: $matrixLegSpec. @<environment> runs it there instead of --environment, @device pins '
              'a LambdaTest leg to a device, user= pins the user type of its logins '
              '(MPLATROL_E2E_USER_TYPE) and tests= selects its tests (--target-regex), e.g. '
              '"acme@qa:lt-android;user=business;tests=PROJ-TC-(101|102)".')
      ..addMultiOption('tenant',
          valueHelp: 'tenant', help: 'Run these tenants on every --variant (with or instead of --leg).')
      ..addMultiOption('variant',
          allowed: matrixVariants,
          defaultsTo: const ['lt-ios', 'lt-android'],
          help: 'The variants of each --tenant. ios and android run on the local simulator and emulator, one leg per '
              'platform at a time on the machine.')
      ..addOption('environment', defaultsTo: 'staging', help: 'The environment of every leg that names none.')
      ..addOption('min-free-gb', defaultsTo: '25', help: 'A lane starts a leg only with this much free disk.')
      ..addOption('after-release',
          valueHelp: 'shell command',
          help: 'Runs (via sh, {lane} = the lane checkout) when a lane is freed, before its next leg.')
      ..addMultiOption('publish',
          valueHelp: 'shell command',
          splitCommas: false,
          help: 'Runs (via sh, {run} = the run directory) as legs finish (at most every 10 minutes) and when the round '
              'ends, even when interrupted (then marked partial), e.g. a results publisher.');
  }

  final MatrixProcessStarter _start;
  final List<String>? _mplatrolCommand;
  final List<Stream<ProcessSignal>> Function() _signals;

  static List<Stream<ProcessSignal>> _processSignals() =>
      [ProcessSignal.sigint.watch(), ProcessSignal.sigterm.watch(), ProcessSignal.sighup.watch()];

  @override
  String get name => 'matrix';

  @override
  String get description =>
      'Run tenants × LambdaTest and local variants on a pool of lane checkouts, iOS and Android in parallel.';

  /// Inputs are checked in [runCommand], where a usage problem names the
  /// offending value and the run directory's state can be read.
  @override
  void validateInput() {}

  @override
  Future<int> runCommand() async {
    final runDir = _required('run-dir') ?? '';
    final run = MatrixRunDir(runDir.isEmpty ? '' : p.absolute(runDir));
    final legs = _legs();
    final lanes = [for (final lane in argResults['lane'] as List<String>) p.absolute(lane)];
    final failure = await _preflight(run, legs, lanes);
    if (failure != null) {
      return failure;
    }
    final environment = platformWrapper.environment;
    final publishState = MatrixPublishState(platformWrapper.environment['HOME']);
    final publisher = _publisher(run);
    final scheduler = MatrixScheduler(
      runner: _runner(),
      run: run,
      minFreeGb: int.parse(argResults['min-free-gb'] as String),
      freeGb: getDep<DiskSpace>().freeGb,
      afterRelease: _hook('after-release', '{lane}'),
      onLegFinished: () {
        publishState.recordRun(run, DateTime.now());
        publisher.legFinished();
      },
    );
    publishState.recordRun(run, DateTime.now());
    final interruption = _Interruption(_signals(), (signal) {
      logger.warn('[matrix] received $signal: stopping the running legs and publishing the partial round.');
      scheduler.abort('received $signal');
    });
    var state = MatrixRoundState.partial;
    var failedHooks = 0;
    var exits = <String, int>{};
    try {
      exits = await scheduler.runAll(interleaveByPlatform(legs!), lanes, environment: environment);
      final home = environment['HOME'];
      final usageLog = home == null || home.isEmpty ? null : p.join(home, '.mplatrol', 'lt-slots', 'usage.log');
      final timings = '${MatrixTimings(usageLog: usageLog).report(run)}\n';
      run.writeTimings(timings);
      logger.info(timings);
      if (interruption.received == null) {
        state = MatrixRoundState.complete;
      }
    } finally {
      await interruption.cancel();
      publishState.recordRun(run, DateTime.now());
      failedHooks = await publisher.finish(state);
    }
    logger.info('[matrix] ${exits.length} legs ran; ${exits.values.where((code) => code == 0).length} passed '
        'every selected test. Logs and reports: ${run.path}');
    if (interruption.received != null) {
      return interruption.exitCode;
    }
    return failedHooks == 0 ? ExitCode.success.code : ExitCode.software.code;
  }

  /// The exit code when the inputs are unusable, else null.
  Future<int?> _preflight(MatrixRunDir run, List<MatrixLeg>? legs, List<String> lanes) async {
    final minFreeGb = int.tryParse(argResults['min-free-gb'] as String);
    final problem = _problem(run, legs, lanes, minFreeGb);
    if (problem != null) {
      logger.err(problem);
      return ExitCode.usage.code;
    }
    return null;
  }

  MatrixPublisher _publisher(MatrixRunDir run) => MatrixPublisher(
        commands: argResults['publish'] as List<String>,
        run: run,
        runHook: (command, {required silent}) async {
          final result = await _runShell(command, silent: silent);
          return result.exitCode;
        },
        report: (message, {required fatal}) => fatal ? logger.err(message) : logger.warn(message),
      );

  Future<ProcessResultX> _runShell(String command, {required bool silent}) => silent
      ? getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', command], throwOnError: false, silent: true)
      : getDep<MplatrolShell>().runArgs('/bin/sh', ['-c', command], throwOnError: false);

  String? _required(String option) => (argResults[option] as String?)?.trim();

  /// The legs of --leg and --tenant × --variant, or null when a --leg is malformed.
  List<MatrixLeg>? _legs() {
    final legs = <MatrixLeg>[];
    for (final spec in argResults['leg'] as List<String>) {
      final leg = MatrixLeg.parse(spec);
      if (leg == null) {
        logger.err('--leg $spec: want $matrixLegSpec.');
        return null;
      }
      if (leg.localWithDevice) {
        logger.err('--leg $spec: @device picks a LambdaTest device; a local ${leg.variant} leg runs on the '
            '${leg.isIos ? LocalDeviceSpec.iosDeviceName : LocalDeviceSpec.androidAvdName} '
            '${leg.isIos ? 'simulator' : 'emulator'}. '
            'Drop @${leg.device}, or use lt-${leg.variant}.');
        return null;
      }
      legs.add(leg);
    }
    for (final tenant in argResults['tenant'] as List<String>) {
      for (final variant in argResults['variant'] as List<String>) {
        legs.add(MatrixLeg(tenant: tenant.trim().toLowerCase(), variant: variant));
      }
    }
    return legs;
  }

  String? _problem(MatrixRunDir run, List<MatrixLeg>? legs, List<String> lanes, int? minFreeGb) {
    if (legs == null) {
      return 'Fix the --leg values above.';
    }
    if (run.path.isEmpty || legs.isEmpty || lanes.isEmpty) {
      return 'Pass --run-dir, at least one --lane and at least one --leg or --tenant.';
    }
    if (run.started) {
      return '${run.path} already holds a run; use a new --run-dir.';
    }
    final missing = lanes.where((lane) => !FileSystem.isAppCheckout(lane));
    if (missing.isNotEmpty) {
      return 'Not an app checkout: ${missing.join(', ')}.';
    }
    final seen = <String>{};
    final twice = legs.where((leg) => !seen.add(leg.key)).map((leg) => leg.key).toSet();
    if (twice.isNotEmpty) {
      return 'A leg is listed twice: ${twice.join(', ')}. Legs of one tenant and variant need their own '
          'environment (<tenant>@<environment>) or user type (;user=).';
    }
    return minFreeGb == null || minFreeGb < 0 ? '--min-free-gb must be a whole number of GB.' : null;
  }

  MatrixLegRunner _runner() => MatrixLegRunner(
        command: _mplatrolCommand ?? currentMplatrolCommand(),
        ports: MatrixPorts(p.join(platformWrapper.environment['HOME'] ?? '', '.mplatrol', 'matrix-endpoints')),
        start: _start,
        environment: argResults['environment'] as String,
        localDevices: MatrixLocalDevices.fromHome(platformWrapper.environment['HOME'], logger),
      );

  /// The --[option] shell command as a lane hook with [placeholder] replaced.
  MatrixLaneHook? _hook(String option, String placeholder) {
    final command = _required(option);
    if (command == null || command.isEmpty) {
      return null;
    }
    return (lane) async {
      final result = await getDep<MplatrolShell>()
          .runArgs('/bin/sh', ['-c', command.replaceAll(placeholder, lane)], throwOnError: false, silent: true);
      logger.detail('[matrix] --$option for $lane: exit ${result.exitCode}');
    };
  }
}

/// The first SIGINT, SIGTERM or SIGHUP the round receives.
class _Interruption {
  _Interruption(List<Stream<ProcessSignal>> streams, void Function(ProcessSignal signal) onSignal) {
    for (final stream in streams) {
      _subscriptions.add(stream.listen((signal) {
        if (received == null) {
          received = signal;
          onSignal(signal);
        }
      }));
    }
  }

  static const _numbers = {'SIGHUP': 1, 'SIGINT': 2, 'SIGTERM': 15};

  final _subscriptions = <StreamSubscription<ProcessSignal>>[];

  /// The signal that interrupted the round, or null.
  ProcessSignal? received;

  /// The shell convention for a process ended by [received]: 128 + the signal number.
  int get exitCode => 128 + (_numbers['$received'] ?? 0);

  Future<void> cancel() => Future.wait([for (final subscription in _subscriptions) subscription.cancel()]);
}
