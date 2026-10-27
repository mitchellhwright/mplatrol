import 'dart:io';

/// Writes [content] to [file] only when it differs from what is on disk.
///
/// Generated build inputs (Gradle config, Xcode project, test runners) are
/// regenerated every run; rewriting identical content still bumps the file's
/// timestamp, which invalidates Gradle's and Xcode's incremental caches.
void writeIfChanged(File file, String content) {
  if (file.existsSync() && file.readAsStringSync() == content) {
    return;
  }
  file
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}
