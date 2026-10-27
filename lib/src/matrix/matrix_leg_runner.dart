import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/disk/disk_janitor.dart';
import 'package:mplatrol/src/e2e_credentials_server.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/local_device_leases.dart';
import 'package:mplatrol/src/lt_hyperexecute_runner.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:mplatrol/src/matrix/matrix_local_devices.dart';
import 'package:path/path.dart' as p;

/// A started leg: [exitCode] completes when its `mplatrol run` exits,
/// [released] when that run freed its checkout (see [ItLegDir.release]), or
/// with false when it exited without freeing it; [stop] terminates it.
typedef MatrixLegHandle = ({Future<int> exitCode, Future<bool> released, void Function() stop});

/// Starts a process with [environment] in [workingDirectory] and hands every
/// line it prints (stdout and stderr) to [onLine]; completes with its exit
/// code. The process is terminated once [stop] completes.
typedef MatrixProcessStarter = Future<int> Function(String executable, List<String> arguments,
    {required String workingDirectory,
    required Map<String, String> environment,
    required void Function(String line) onLine,
    required Future<void> stop});

/// Per-leg fixed endpoint ports, shared by every matrix run on the machine
/// (`<directory>/ports`, lines `<tenant>_<variant> <port>`): the credential server
/// listens on the port and the iOS shard coordinator on the next one, so a
/// leg's build is identical in every lane and the artifact cache can reuse it,
/// while a tenant's iOS and Android legs run at once on their own ports.
class MatrixPorts {
  /// Creates the registry in [directory].
  MatrixPorts(this.directory);

  /// Where the registry and the per-tenant endpoint files live.
  final String directory;

  static const _first = 47200;

  /// The credential-server port of the leg [key], registering the next free
  /// pair for a new leg.
  int portFor(String key) {
    final file = File(p.join(directory, 'ports'))..parent.createSync(recursive: true);
    final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
    var last = _first - 2;
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      final port = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (port == null) {
        continue;
      }
      if (parts[0] == key) {
        return port;
      }
      last = port > last ? port : last;
    }
    file.writeAsStringSync('$key ${last + 2}\n', mode: FileMode.append);
    return last + 2;
  }

  /// The file holding the leg [key]'s credential endpoint (token and port).
  String endpointFile(String key) => p.join(directory, '$key.json');
}

/// The exit code of a leg stopped before its `mplatrol run` started (while it waited for its local
/// device), as if it had been stopped with SIGTERM.
const matrixStoppedExitCode = 143;

/// Runs one matrix leg: `mplatrol run <variant> --tenant=<tenant> --environment=<env>` in a lane checkout (with the
/// leg's `--target-regex` and [e2eUserTypeEnv] when it names tests or a user type),
/// with the leg directory, fixed endpoints, run id and per-leg JUnit, its
/// console in `<key>.log` and timestamped in `<key>.log.times`. A local leg
/// first leases its emulator or simulator from [localDevices] and holds it
/// until its run exits; a local run never frees its checkout early.
class MatrixLegRunner {
  /// Creates a runner that starts `mplatrol` as [command] (executable first).
  MatrixLegRunner({
    required this.command,
    required this.ports,
    required MatrixProcessStarter start,
    this.environment = 'staging',
    this.localDevices,
    DateTime Function()? clock,
  })  : _start = start,
        _clock = clock ?? DateTime.now;

  /// The `mplatrol` command line before `run` (e.g. `[dart, run, bin/mplatrol.dart]`).
  final List<String> command;

  /// The per-tenant endpoint registry.
  final MatrixPorts ports;

  /// The `--environment` of the legs that name none ([MatrixLeg.environment]).
  final String environment;

  /// The local device leases, or null to start local legs without one (no `HOME`).
  final MatrixLocalDevices? localDevices;

  final MatrixProcessStarter _start;
  final DateTime Function() _clock;

  /// Starts [leg] in the checkout [lane] of the run [run], with [base] as the process environment.
  MatrixLegHandle start(MatrixLeg leg,
      {required String lane, required MatrixRunDir run, required Map<String, String> base}) {
    final port = ports.portFor(leg.key);
    final legDir = run.legDir(leg);
    Directory(p.join(legDir, 'reports')).createSync(recursive: true);
    final log = File(run.log(leg))..writeAsStringSync('${_clock()} lane=$lane leg=$leg port=$port\n');
    final times = File(run.times(leg))..writeAsStringSync('');
    final stopper = Completer<void>();
    Future<int> launch(LtSlotLease? lease) => _start(
        command.first,
        [
          ...command.skip(1),
          'run',
          leg.variant,
          '--tenant=${leg.tenant}',
          '--environment=${leg.environment ?? environment}',
          if (leg.device != null) '--device=${leg.device}',
          if (leg.tests != null) '--target-regex=${leg.tests}',
          '--junit=${run.junit(leg, _clock())}',
        ],
        workingDirectory: lane,
        environment: {
          ...base,
          if (leg.userType != null) e2eUserTypeEnv: leg.userType!,
          itLegDirEnv: legDir,
          e2eCredentialsPortEnv: '$port',
          e2eCredentialsEndpointFileEnv: ports.endpointFile(leg.key),
          iosShardCoordinatorPortEnv: '${port + 1}',
          itAutoCleanEnv: 'off',
          'MPLATROL_RUN_ID': run.id,
          if (lease != null) localDeviceLeaseEnv: LocalDeviceLeases.envValue(leg.platform, lease),
        },
        onLine: (line) => _record(log, times, line),
        stop: stopper.future);
    Future<int> launchOrReport(LtSlotLease? lease) async {
      try {
        return await launch(lease);
      } on ProcessException catch (error) {
        // e.g. the lane checkout was removed under the round: fail this leg, not the whole matrix.
        _record(log, times, '[matrix] could not start $leg in $lane: ${error.message}');
        return matrixStartFailedExitCode;
      }
    }

    final exitCode =
        _onLocalDevice(leg, (line) => _record(log, times, line), stopper.future, launchOrReport).then((code) {
      log.writeAsStringSync('EXIT $code ${_clock()}\n', mode: FileMode.append);
      return code;
    });
    return (
      exitCode: exitCode,
      // A local leg uses the checkout and its device until it exits, so its lane is freed only then.
      released: leg.isLocal
          ? exitCode.then((_) => false)
          : _released(File(p.join(legDir, itCheckoutReleasedMarker)), exitCode),
      stop: () => stopper.isCompleted ? null : stopper.complete(),
    );
  }

  /// Runs [launch] holding [leg]'s local device when it is a local leg, handing it the lease so the
  /// leg's `mplatrol run` uses the device without waiting for it ([localDeviceLeaseEnv]); a leg stopped while
  /// waiting for the device never starts and exits [matrixStoppedExitCode].
  Future<int> _onLocalDevice(MatrixLeg leg, void Function(String line) report, Future<void> stop,
      Future<int> Function(LtSlotLease? lease) launch) async {
    final devices = localDevices;
    if (!leg.isLocal || devices == null) {
      return launch(null);
    }
    final LtSlotLease lease;
    try {
      lease = await devices.acquire(leg, report: report, cancel: stop);
    } on LtSlotWaitCancelled {
      report('[local-device] $leg: stopped while waiting for the local ${leg.platform} device');
      return matrixStoppedExitCode;
    }
    try {
      return await launch(lease);
    } finally {
      await lease.release();
    }
  }

  void _record(File log, File times, String line) {
    final now = _clock();
    String two(int value) => value.toString().padLeft(2, '0');
    log.writeAsStringSync('$line\n', mode: FileMode.append);
    times.writeAsStringSync('${two(now.hour)}:${two(now.minute)}:${two(now.second)} $line\n', mode: FileMode.append);
  }

  /// Completes with true once [marker] exists, or with whether it exists once [exitCode] completes. Waits on
  /// file-system events in the marker's folder, not a timer.
  Future<bool> _released(File marker, Future<int> exitCode) async {
    if (marker.existsSync()) {
      return true;
    }
    final done = Completer<bool>();
    final events = marker.parent.watch(events: FileSystemEvent.create | FileSystemEvent.move).listen((event) {
      if (!done.isCompleted && marker.existsSync()) {
        done.complete(true);
      }
    });
    unawaited(exitCode.whenComplete(() {
      if (!done.isCompleted) {
        done.complete(marker.existsSync());
      }
    }));
    // The marker may have appeared between the first check and the watch starting.
    if (!done.isCompleted && marker.existsSync()) {
      done.complete(true);
    }
    try {
      return await done.future;
    } finally {
      await events.cancel();
    }
  }
}

/// The exit code of a leg whose process could not be started (e.g. its lane checkout is missing).
const matrixStartFailedExitCode = 127;

/// How long a stopped leg gets to clean up after SIGTERM before it is killed.
const matrixStopGrace = Duration(seconds: 60);

/// How long the output of an exited leg is read on after its process exited.
const matrixOutputGrace = Duration(seconds: 5);

/// Starts processes with `dart:io`, streaming their output line by line; once
/// [stop] completes it sends SIGTERM, then SIGKILL after [matrixStopGrace].
Future<int> startMatrixProcess(String executable, List<String> arguments,
    {required String workingDirectory,
    required Map<String, String> environment,
    required void Function(String line) onLine,
    required Future<void> stop}) async {
  final process =
      await Process.start(executable, arguments, workingDirectory: workingDirectory, environment: environment);
  var exited = false;
  Timer? hardKill;
  unawaited(stop.then((_) {
    if (!exited) {
      process.kill();
      hardKill = Timer(matrixStopGrace, () => process.kill(ProcessSignal.sigkill));
    }
  }));
  final output = Future.wait([
    for (final stream in [process.stdout, process.stderr])
      stream.transform(utf8.decoder).transform(const LineSplitter()).forEach(onLine),
  ]);
  final code = await process.exitCode;
  exited = true;
  hardKill?.cancel();
  // A grandchild that outlives a killed leg keeps the pipes open; do not wait for it.
  await output.timeout(matrixOutputGrace, onTimeout: () => const []);
  return code;
}

/// The command line that started this `mplatrol`: the Dart VM and the script for
/// `dart bin/mplatrol.dart` or a snapshot, else the compiled executable alone.
List<String> currentMplatrolCommand({Uri? script, String? executable}) {
  final path = (script ?? Platform.script).toFilePath();
  final viaVm = path.endsWith('.dart') || path.endsWith('.snapshot') || path.endsWith('.dill');
  return [executable ?? Platform.resolvedExecutable, if (viaVm) path];
}
