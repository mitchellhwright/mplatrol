import 'dart:io';

import 'package:path/path.dart' as p;

/// The variants a matrix leg runs on: LambdaTest iOS and Android, and the local simulator and emulator.
const matrixVariants = ['lt-ios', 'lt-android', 'ios', 'android'];

/// The `--leg` syntax [MatrixLeg.parse] reads.
const matrixLegSpec = '<tenant>[@<environment>]:lt-ios|lt-android|ios|android[@<device>][;user=<type>][;tests=<regex>]';

/// One matrix leg: one `mplatrol run` of one tenant on one variant ([matrixVariants]); a LambdaTest leg
/// may be pinned to a device spec. A leg may name its own environment (else the matrix's `--environment`),
/// pin the user type its logins must have (`MPLATROL_E2E_USER_TYPE`) and select its tests
/// (`--target-regex`), so one round can run e.g. the same cases in QA once per user type.
class MatrixLeg {
  /// Creates a leg.
  const MatrixLeg(
      {required this.tenant, required this.variant, this.device, this.environment, this.userType, this.tests});

  /// Parses [matrixLegSpec]; null when malformed. Check [localWithDevice] before running it.
  static MatrixLeg? parse(String spec) {
    final parts = spec.trim().split(';');
    final match = _spec.firstMatch(parts.first.trim());
    if (match == null) {
      return null;
    }
    final options = <String, String>{};
    for (final part in parts.skip(1)) {
      final option = _option.firstMatch(part.trim());
      if (option == null || options.containsKey(option[1])) {
        return null;
      }
      options[option[1]!] = option[2]!;
    }
    final userType = options['user'];
    final tests = options['tests'];
    if ((userType != null && !_userType.hasMatch(userType)) || (tests != null && !_tests.hasMatch(tests))) {
      return null;
    }
    return MatrixLeg(
        tenant: match[1]!,
        environment: match[2],
        variant: match[3]!,
        device: match[4]?.trim(),
        userType: userType,
        tests: tests);
  }

  static final _spec = RegExp('^([a-z0-9]+)(?:@([A-Za-z][A-Za-z0-9]*))?:(lt-ios|lt-android|ios|android)'
      r'(?:@([^;]*[^;\s]))?$');
  static final _option = RegExp(r'^(user|tests)=(.+)$');
  static final _userType = RegExp(r'^[A-Za-z0-9_]+$');
  static final _tests = RegExp(r'^\S+$');

  /// The tenant id.
  final String tenant;

  /// One of [matrixVariants].
  final String variant;

  /// LambdaTest device spec, or null for the configured devices.
  final String? device;

  /// The environment this leg runs against, or null for the matrix's `--environment`.
  final String? environment;

  /// The user type (`MPLATROL_E2E_USER_TYPE`) of the leg's logins, or null for any.
  final String? userType;

  /// The `--target-regex` selecting the leg's tests, or null for the whole suite.
  final String? tests;

  /// Whether this is an iOS leg (LambdaTest or the local simulator).
  bool get isIos => variant.endsWith('ios');

  /// Whether this leg runs on the local emulator or simulator rather than LambdaTest.
  bool get isLocal => !variant.startsWith('lt-');

  /// `android` or `ios`: the platform, whichever the device.
  String get platform => isIos ? 'ios' : 'android';

  /// Whether this is a local leg pinned to a device: `@device` names a LambdaTest device, so a local
  /// leg (which runs on the spec emulator or simulator) cannot take one.
  bool get localWithDevice => isLocal && device != null;

  /// `<tenant>[@<environment>][+<user type>]_<variant>`: the leg's lock, directory, log and endpoint name, so legs
  /// of one tenant and variant in other environments or with other users get their own.
  String get key =>
      '$tenant${environment == null ? '' : '@$environment'}${userType == null ? '' : '+$userType'}_$variant';

  @override
  String toString() =>
      '$tenant${environment == null ? '' : '@$environment'}:$variant${device == null ? '' : '@$device'}'
      '${userType == null ? '' : ';user=$userType'}${tests == null ? '' : ';tests=$tests'}';
}

/// [legs] with the platforms interleaved (iOS, Android, iOS, ...; each
/// platform in the given order), so both platforms always have legs building.
List<MatrixLeg> interleaveByPlatform(List<MatrixLeg> legs) {
  final ios = legs.where((leg) => leg.isIos).toList();
  final android = legs.where((leg) => !leg.isIos).toList();
  return [
    for (var i = 0; i < ios.length || i < android.length; i++) ...[
      if (i < ios.length) ios[i],
      if (i < android.length) android[i],
    ],
  ];
}

/// The files of one matrix run under [path]: `queue.log`, and per leg
/// `<key>.log`, `<key>.log.times` and the leg directory `legs/<key>` (with its
/// JUnit and summary in `reports/`).
class MatrixRunDir {
  /// Creates the layout of the run directory [path].
  MatrixRunDir(this.path);

  /// The run directory.
  final String path;

  /// The run's id: the directory's name.
  String get id => p.basename(p.normalize(path));

  /// `queue.log`: one timestamped line per leg start, release and finish.
  String get queueLog => p.join(path, 'queue.log');

  /// The leg's console log.
  String log(MatrixLeg leg) => p.join(path, '${leg.key}.log');

  /// The leg's console log with each line's time.
  String times(MatrixLeg leg) => '${log(leg)}.times';

  /// The leg's own directory (`MPLATROL_IT_LEG_DIR`).
  String legDir(MatrixLeg leg) => p.join(path, 'legs', leg.key);

  /// The leg's JUnit report for a leg started at [startedAt].
  String junit(MatrixLeg leg, DateTime startedAt) {
    final utc = startedAt.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${utc.year}${two(utc.month)}${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
    return p.join(legDir(leg), 'reports', 'junit-${leg.tenant}-${leg.variant}-$stamp.xml');
  }

  /// Written in the leg directory when the scheduler stopped the leg for exceeding its time cap; holds why.
  String stalledMarker(MatrixLeg leg) => p.join(legDir(leg), 'stalled');

  /// `round-state`: `running`, `partial` (interrupted or failed) or `complete`, as of the last publish.
  String get roundStateFile => p.join(path, 'round-state');

  /// Whether the directory already holds a run.
  bool get started => File(queueLog).existsSync();

  /// Writes the run's timings report to `timings.md`.
  void writeTimings(String report) => File(p.join(path, 'timings.md')).writeAsStringSync(report);

  /// Records the round's [state] for the `--publish` hooks.
  void writeRoundState(String state) => File(roundStateFile).writeAsStringSync('$state\n');

  /// Appends `<YYYY-MM-DD HH:MM:SS> <line>` to [queueLog], the format
  /// matrix_from_junit.py and the timings report read.
  void append(String line, DateTime at) {
    File(queueLog)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${matrixStamp(at)} $line\n', mode: FileMode.append);
  }
}

/// `YYYY-MM-DD HH:MM:SS` in local time.
String matrixStamp(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Whether [lane] is an app checkout (has a `pubspec.yaml`).
bool isAppCheckout(String lane) => File(p.join(lane, 'pubspec.yaml')).existsSync();
