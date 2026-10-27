import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:path/path.dart' as p;

/// File access behind an injectable seam, so commands and runners can be tested without a real app checkout.
class FileSystem {
  /// Only [Dependencies] creates the single instance.
  FileSystem.constructGlobalInstance();

  String readAsStringSync(String filePath) => File(filePath).readAsStringSync();

  List<String> readAsLinesSync(String filePath) => File(filePath).readAsLinesSync();

  void writeAsStringSync({required String filePath, required String newContent, bool flush = false}) =>
      File(filePath).writeAsStringSync(newContent, flush: flush);

  void createSync({required String filePath, bool recursive = false, bool exclusive = false}) =>
      File(filePath).createSync(recursive: recursive, exclusive: exclusive);

  void deleteSync({required String filePath, bool recursive = false}) =>
      File(filePath).deleteSync(recursive: recursive);

  bool fileExistsSync(String filePath) => File(filePath).existsSync();

  /// Whether [filePath] is a file anyone may execute.
  bool isExecutableFileSync(String filePath) {
    final stat = File(filePath).statSync();
    return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
  }

  Directory get currentDir => Directory.current;

  /// The Flutter app under test: `app.path` from `mplatrol.yaml`, else the nearest folder at or above
  /// [workingDir] (default: the current directory) holding a `pubspec.yaml` and a `patrol_test/` folder.
  ///
  /// Throws:
  ///   Exception: no app is found and [throwIfNotFound] is true.
  Directory getAppDirectory({bool throwIfNotFound = true, Directory? workingDir}) {
    final configured = getDep<MplatrolConfig>().resolvedAppPath();
    if (configured != null) {
      return Directory(configured);
    }
    final start = p.normalize((workingDir ?? Directory.current).absolute.path);
    for (var dir = start;; dir = p.dirname(dir)) {
      if (isAppCheckout(dir)) {
        return Directory(dir);
      }
      if (dir == p.dirname(dir)) {
        break;
      }
    }
    if (!throwIfNotFound) {
      return Directory(start);
    }
    throw Exception('Could not find the app under test from $start: no folder there or above it has a '
        'pubspec.yaml and a patrol_test/ folder.\n\n'
        '  cd into the Flutter app, or set app.path in $mplatrolConfigFileName.');
  }

  /// Whether [dir] is the root of a Flutter app with Patrol tests.
  static bool isAppCheckout(String dir) =>
      File(p.join(dir, 'pubspec.yaml')).existsSync() && Directory(p.join(dir, 'patrol_test')).existsSync();

  /// The app's `ios/` folder.
  Directory getIosDirectory({bool throwIfNotFound = true, Directory? workingDir}) =>
      Directory(p.join(getAppDirectory(throwIfNotFound: throwIfNotFound, workingDir: workingDir).path, 'ios'));

  /// The app's `android/` folder.
  Directory getAndroidDirectory({bool throwIfNotFound = true, Directory? workingDir}) =>
      Directory(p.join(getAppDirectory(throwIfNotFound: throwIfNotFound, workingDir: workingDir).path, 'android'));
}
