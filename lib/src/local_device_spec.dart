/// The local emulator and simulator the mplatrol suite is verified on.
///
/// Every part of the framework that creates, checks or picks a local device (`mplatrol devices --setup`,
/// `mplatrol doctor`, `mplatrol run`) reads this one spec.
abstract final class LocalDeviceSpec {
  /// The AVD name; `mplatrol devices --setup` creates it.
  static const androidAvdName = 'mplatrol_e2e_pixel9';

  /// The `avdmanager --device` hardware profile.
  static const androidDeviceProfile = 'pixel_9';

  /// The `sdkmanager` package of the AVD's system image.
  static const androidSystemImage = 'system-images;android-36;google_apis_playstore;arm64-v8a';

  /// The `image.sysdir.1` value of an AVD that uses [androidSystemImage].
  static const androidSystemDir = 'system-images/android-36/google_apis_playstore/arm64-v8a';

  /// Minimum `hw.ramSize`. With less, local Android runs 0 tests or native calls time out.
  static const androidMinRamMegabytes = 6144;

  /// `disk.dataPartition.size` the AVD is created with; smaller partitions fill up during a full suite.
  static const androidDataPartition = '16G';

  /// `vm.heapSize` the AVD is created with.
  static const androidHeap = '228M';

  /// The simulator's name.
  static const iosDeviceName = 'iPhone 17 Pro';

  /// The `simctl` device type of [iosDeviceName].
  static const iosDeviceType = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro';

  /// The simulator's iOS major version.
  static const iosRuntimeMajor = 26;

  /// The command that creates missing spec devices and repairs drifted ones.
  static const setupCommand = 'mplatrol devices --setup';

  /// The command that boots the spec AVD.
  static const androidBootCommand = 'emulator -avd $androidAvdName';

  /// The spec as one sentence, for docs and fix texts.
  static const summary = 'Android AVD $androidAvdName (device $androidDeviceProfile, Android 36 google_apis_playstore '
      'arm64-v8a, at least $androidMinRamMegabytes MB RAM, $androidDataPartition data, $androidHeap heap) and iOS '
      'simulator $iosDeviceName on iOS $iosRuntimeMajor';

  /// Whether a simulator list label (`<name>` or `<name> (Booted)`) is the spec simulator.
  static bool isSpecSimulatorLabel(String label) => label == iosDeviceName || label == '$iosDeviceName (Booted)';
}

/// One `config.ini` setting of an AVD that differs from [LocalDeviceSpec].
class AvdDrift {
  /// Creates a drift.
  const AvdDrift({required this.key, required this.expected, required this.actual, required this.repairable});

  /// The `config.ini` key.
  final String key;

  /// The spec's value.
  final String expected;

  /// The AVD's value, or null when the key is missing.
  final String? actual;

  /// Whether `--setup` can fix this by editing `config.ini`; otherwise the AVD must be recreated.
  final bool repairable;

  @override
  String toString() => '$key is ${actual ?? 'unset'}, spec is $expected';
}

/// An AVD's `config.ini`, parsed and compared with [LocalDeviceSpec].
class AvdConfig {
  /// Parses `key=value` lines; blank lines and lines without `=` are kept in [repaired] but have no key.
  AvdConfig.parse(this._text) {
    for (final line in _text.split('\n')) {
      final separator = line.indexOf('=');
      if (separator > 0) {
        values[line.substring(0, separator).trim()] = line.substring(separator + 1).trim();
      }
    }
  }

  final String _text;

  /// Every `key=value` of the file.
  final Map<String, String> values = {};

  /// The settings that differ from the spec, repairable ones first.
  List<AvdDrift> drift() {
    final found = <AvdDrift>[];
    void minimum(String key, String expected, int Function(String) toMegabytes) {
      final actual = values[key];
      if (actual == null || toMegabytes(actual) < toMegabytes(expected)) {
        found.add(AvdDrift(key: key, expected: expected, actual: actual, repairable: true));
      }
    }

    minimum('hw.ramSize', '${LocalDeviceSpec.androidMinRamMegabytes}', _megabytes);
    minimum('disk.dataPartition.size', LocalDeviceSpec.androidDataPartition, _megabytes);
    minimum('vm.heapSize', LocalDeviceSpec.androidHeap, _megabytes);
    void exact(String key, String expected, {String Function(String)? normalize}) {
      final actual = values[key];
      if (actual == null || (normalize?.call(actual) ?? actual) != expected) {
        found.add(AvdDrift(key: key, expected: expected, actual: actual, repairable: false));
      }
    }

    exact('hw.device.name', LocalDeviceSpec.androidDeviceProfile);
    exact(
      'image.sysdir.1',
      LocalDeviceSpec.androidSystemDir,
      normalize: (path) => path.endsWith('/') ? path.substring(0, path.length - 1) : path,
    );
    return found;
  }

  /// The file text with every repairable drift set to the spec value: existing lines are replaced and
  /// missing keys appended.
  String repaired() {
    final fixes = {for (final item in drift().where((item) => item.repairable)) item.key: item.expected};
    final seen = <String>{};
    final lines = <String>[];
    for (final line in _text.split('\n')) {
      final key = line.contains('=') ? line.substring(0, line.indexOf('=')).trim() : null;
      if (key != null && fixes.containsKey(key)) {
        seen.add(key);
        lines.add('$key=${fixes[key]}');
      } else {
        lines.add(line);
      }
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    for (final entry in fixes.entries.where((entry) => !seen.contains(entry.key))) {
      lines.add('${entry.key}=${entry.value}');
    }
    return '${lines.join('\n')}\n';
  }

  /// `512`, `2048M` or `16G` as megabytes; -1 when [size] has another shape.
  static int _megabytes(String size) {
    final match = RegExp(r'^(\d+)\s*([KMG]?)B?$', caseSensitive: false).firstMatch(size.trim());
    if (match == null) {
      return -1;
    }
    final number = int.parse(match.group(1)!);
    return switch (match.group(2)!.toUpperCase()) {
      'G' => number * 1024,
      'K' => number ~/ 1024,
      _ => number,
    };
  }
}

/// A simulator from `xcrun simctl list devices available`.
class SimulatorEntry {
  /// Creates an entry.
  const SimulatorEntry({required this.name, required this.udid, required this.booted, required this.iosMajor});

  /// The device name, such as `iPhone 17 Pro`.
  final String name;

  /// The simulator UDID.
  final String udid;

  /// Whether the simulator is booted.
  final bool booted;

  /// The iOS major version of the runtime the simulator belongs to.
  final int iosMajor;

  /// Whether this is the spec simulator.
  bool get conforms => name == LocalDeviceSpec.iosDeviceName && iosMajor == LocalDeviceSpec.iosRuntimeMajor;

  /// Parses `xcrun simctl list devices available` output; only iOS runtimes are read.
  static List<SimulatorEntry> parse(Iterable<String> lines) {
    final entries = <SimulatorEntry>[];
    int? iosMajor;
    for (final line in lines) {
      final header = RegExp(r'^\s*--\s*(.+?)\s*--\s*$').firstMatch(line);
      if (header != null) {
        iosMajor = int.tryParse(RegExp(r'^iOS (\d+)').firstMatch(header.group(1)!)?.group(1) ?? '');
        continue;
      }
      final device = RegExp(r'^\s*(.+?)\s+\(([0-9A-Fa-f]{8}-[0-9A-Fa-f-]+)\)\s+\((\w+)\)\s*$').firstMatch(line);
      if (iosMajor != null && device != null) {
        entries.add(
          SimulatorEntry(
            name: device.group(1)!,
            udid: device.group(2)!,
            booted: device.group(3) == 'Booted',
            iosMajor: iosMajor,
          ),
        );
      }
    }
    return entries;
  }

  /// The identifier of the newest installed iOS runtime of [LocalDeviceSpec.iosRuntimeMajor] in
  /// `xcrun simctl list runtimes available` output, or null when none is installed.
  static String? newestRuntime(Iterable<String> lines) {
    final pattern = RegExp('^iOS ${LocalDeviceSpec.iosRuntimeMajor}\\.(\\d+).* - (\\S+)\\s*\$');
    String? newest;
    var newestMinor = -1;
    for (final line in lines) {
      final match = pattern.firstMatch(line.trim());
      final minor = int.tryParse(match?.group(1) ?? '');
      if (minor != null && minor > newestMinor) {
        newestMinor = minor;
        newest = match!.group(2);
      }
    }
    return newest;
  }
}
