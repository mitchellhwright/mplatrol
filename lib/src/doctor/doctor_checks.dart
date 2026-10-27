import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/local_device_spec.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:path/path.dart' as p;

/// One `mplatrol doctor` check result: [ok], what was checked, and the fix to show when it is not ok.
class DoctorFinding {
  /// Creates a finding.
  const DoctorFinding({required this.ok, required this.label, required this.fix});

  /// Whether the check passed.
  final bool ok;

  /// What was checked, shown after the mark.
  final String label;

  /// How to fix it, shown when [ok] is false.
  final String fix;
}

/// A `mplatrol doctor` check whose fix is the same on every machine.
class DoctorCheckDoc {
  /// A check shown as [label].
  const DoctorCheckDoc(this.label, this.fix) : envVar = null;

  /// A check that environment variable [name] is set, shown as `$name`.
  const DoctorCheckDoc.env(String name, this.fix)
      : label = '\$$name',
        envVar = name;

  /// What is checked, shown after the mark.
  final String label;

  /// How to fix it, shown when the check fails.
  final String fix;

  /// The environment variable that must be set, for a [DoctorCheckDoc.env] check.
  final String? envVar;

  /// This check's result on this machine; [detail] (what this machine has) goes before the fix.
  DoctorFinding finding({required bool ok, String? detail}) =>
      DoctorFinding(ok: ok, label: label, fix: detail == null ? fix : '$detail $fix');
}

/// The doctor checks, in the order `mplatrol doctor` runs them.
abstract final class DoctorFixes {
  static const flutter = DoctorCheckDoc('flutter', 'Install Flutter and put `flutter` on PATH.');
  static const patrol =
      DoctorCheckDoc('patrol CLI', 'Run `dart pub global activate patrol_cli` and add ~/.pub-cache/bin to PATH.');
  static const adb = DoctorCheckDoc(
      'adb', 'Install the Android SDK platform tools and put `adb` on PATH. Needed for the android variant.');
  static const xcrun = DoctorCheckDoc('xcrun', 'Install Xcode and its command line tools. Needed for the ios variant.');
  static const ltUsername = DoctorCheckDoc.env(
      'LT_USERNAME', 'Export your LambdaTest user name (Account Settings > Password & Security). Needed for lt-*.');
  static const ltAccessKey = DoctorCheckDoc.env(
      'LT_ACCESS_KEY', 'Export your LambdaTest access key (Account Settings > Password & Security). Needed for lt-*.');
  static const ltTunnel = DoctorCheckDoc(
      'LambdaTest tunnel binary',
      'Run one lt-* leg (the HyperExecute CLI downloads LT and mplatrol keeps it), or download the tunnel binary '
          'for your OS from LambdaTest, unzip LT into ~/.mplatrol/hyperexecute/ and chmod +x it (or set LT_BIN). '
          'Needed for the lt-* variants.');
  static const hyperexecute = DoctorCheckDoc(
      'HyperExecute CLI',
      'Download the HyperExecute CLI for your OS from LambdaTest into ~/.hyperexecute/hyperexecute and chmod +x it '
          '(or set HYPEREXECUTE_BIN). Needed for the lt-* variants.');
  static const utf8Locale = DoctorCheckDoc(
      'UTF-8 locale (LANG)',
      'CocoaPods needs a UTF-8 locale and pod install fails with an encoding error without one. Add '
          '`export LANG=en_US.UTF-8` to your shell profile and open a new terminal.');
  static const emulatorMemory = DoctorCheckDoc(
      'Android emulator has at least 6 GB RAM',
      'With less, local Android runs 0 tests or native calls time out. Run `${LocalDeviceSpec.setupCommand}` to '
          'raise hw.ramSize in the spec AVD, then cold-boot it.');
  static const androidSpecAvd = DoctorCheckDoc(
      'Spec AVD ${LocalDeviceSpec.androidAvdName} exists and conforms',
      'The local Android variant runs only on the spec AVD (${LocalDeviceSpec.summary}). '
          'Run `${LocalDeviceSpec.setupCommand}` to create or repair it.');
  static const bootedEmulatorSpec = DoctorCheckDoc(
      'Booted Android emulators are the spec AVD',
      '`mplatrol run` ignores any other emulator and boots the spec AVD instead. Stop it, or run '
          '`${LocalDeviceSpec.setupCommand}` and boot `${LocalDeviceSpec.androidBootCommand}`.');
  static const iosSpecSimulator = DoctorCheckDoc(
      'Spec simulator ${LocalDeviceSpec.iosDeviceName} (iOS ${LocalDeviceSpec.iosRuntimeMajor}) exists',
      'The local iOS variant runs only on the spec simulator. Run `${LocalDeviceSpec.setupCommand}` to create it.');
  static const bootedSimulatorSpec = DoctorCheckDoc(
      'Booted iOS simulators are the spec simulator',
      '`mplatrol run` ignores any other simulator and boots the spec simulator instead. Shut it down with '
          '`xcrun simctl shutdown <udid>`.');

  /// Every check with fixed text.
  static const all = [
    flutter,
    patrol,
    adb,
    xcrun,
    ltUsername,
    ltAccessKey,
    ltTunnel,
    hyperexecute,
    utf8Locale,
    emulatorMemory,
    androidSpecAvd,
    bootedEmulatorSpec,
    iosSpecSimulator,
    bootedSimulatorSpec,
  ];
}

/// The machine checks behind `mplatrol doctor`.
class DoctorChecks {
  /// /proc/meminfo MemTotal of an emulator with hw.ramSize=6144 is about 5.8 GB; 4096 gives about 3.9 GB.
  static const _minEmulatorKilobytes = 5 * 1024 * 1024;

  FileSystem get _files => getDep<FileSystem>();
  MplatrolShell get _shell => getDep<MplatrolShell>();

  /// Whether `flutter`, `patrol`, `adb` and (on macOS) `xcrun` are on PATH.
  List<DoctorFinding> tools({required bool mac}) => [
        DoctorFixes.flutter.finding(ok: _shell.whichSync('flutter') != null),
        DoctorFixes.patrol.finding(ok: _shell.whichSync('patrol') != null),
        DoctorFixes.adb.finding(ok: _shell.whichSync('adb') != null),
        if (mac) DoctorFixes.xcrun.finding(ok: _shell.whichSync('xcrun') != null),
      ];

  /// Whether the LambdaTest credentials are in [env].
  List<DoctorFinding> lambdaTestCredentials(Map<String, String> env) => [
        for (final check in [DoctorFixes.ltUsername, DoctorFixes.ltAccessKey])
          check.finding(ok: (env[check.envVar!] ?? '').trim().isNotEmpty),
      ];

  /// The lt-* variants need the LambdaTest tunnel binary (LT_BIN, default [ltTunnelBinaryPath]), present and
  /// executable, and the HyperExecute CLI (HYPEREXECUTE_BIN, PATH or ~/.hyperexecute/hyperexecute), resolved the
  /// same way the runners do.
  List<DoctorFinding> lambdaTestBinaries(Map<String, String> env) {
    final home = env['HOME'] ?? '';
    final tunnel = env['LT_BIN'] ?? ltTunnelBinaryPath(home);
    final explicit = env['HYPEREXECUTE_BIN'] ?? '';
    final hyperexecuteOk = (explicit.isNotEmpty && _files.fileExistsSync(explicit)) ||
        _shell.whichSync('hyperexecute') != null ||
        _files.fileExistsSync(p.join(home, '.hyperexecute', 'hyperexecute'));
    return [
      DoctorFixes.ltTunnel.finding(
          ok: _files.fileExistsSync(tunnel) && _files.isExecutableFileSync(tunnel),
          detail: 'No executable LambdaTest tunnel binary at $tunnel.'),
      DoctorFixes.hyperexecute.finding(ok: hyperexecuteOk),
    ];
  }

  /// CocoaPods reads the locale's character set from LC_ALL, else LC_CTYPE, else LANG.
  DoctorFinding utf8Locale(Map<String, String> env) {
    final locale = env['LC_ALL'] ?? env['LC_CTYPE'] ?? env['LANG'];
    return DoctorFixes.utf8Locale.finding(ok: RegExp('utf-?8', caseSensitive: false).hasMatch(locale ?? ''));
  }

  /// The RAM of each booted Android emulator in [adbDevices] (`adb devices` output) whose /proc/meminfo is
  /// readable. Physical phones are not checked.
  Future<List<DoctorFinding>> emulatorMemory(Iterable<String> adbDevices) async {
    final findings = <DoctorFinding>[];
    for (final line in adbDevices) {
      final serial = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim())?.group(1);
      if (serial == null) {
        continue;
      }
      final meminfo = await _shell.runArgs('adb', ['-s', serial, 'shell', 'cat', '/proc/meminfo'],
          throwOnError: false, silent: true);
      final kilobytes = int.tryParse(RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(meminfo.outText)?.group(1) ?? '');
      if (kilobytes == null) {
        continue;
      }
      final gigabytes = (kilobytes / (1024 * 1024)).toStringAsFixed(1);
      findings.add(DoctorFixes.emulatorMemory
          .finding(ok: kilobytes >= _minEmulatorKilobytes, detail: '$serial has $gigabytes GB.'));
    }
    return findings;
  }
}
