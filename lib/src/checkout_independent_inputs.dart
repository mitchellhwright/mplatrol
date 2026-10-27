import 'dart:convert';

import 'package:path/path.dart' as p;

/// Generated build inputs that name the checkout's own absolute path (path
/// dependency overrides inside it, Flutter's generated iOS settings), so the
/// same sources in another checkout would hash differently.
const _pathNamingInputs = {
  'pubspec_overrides.yaml',
  'pubspec.lock',
  '.dart_tool/package_config.json',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  'ios/Flutter/Generated.xcconfig',
  'ios/Flutter/flutter_export_environment.sh',
};

/// The `pub get` timestamp Flutter writes into `.flutter-plugins-dependencies`.
final _pluginsDateCreated = RegExp('"date_created":"[^"]*",?');

/// The checkout path in [bytes] of the app input [relative] (`/`-separated)
/// under [repo] written as `<app>`, and `.flutter-plugins-dependencies`
/// without its `date_created` stamp, so a build identity names the sources,
/// not the checkout that built them or the time it resolved dependencies.
/// Other inputs are returned unchanged.
List<int> checkoutIndependentBytes(String repo, String relative, List<int> bytes) {
  if (!_pathNamingInputs.contains(relative)) {
    return bytes;
  }
  final root = p.normalize(p.absolute(repo));
  var text = utf8
      .decode(bytes, allowMalformed: true)
      .replaceAll(Uri.directory(root).toString(), 'file://<app>/')
      .replaceAll(root, '<app>');
  if (relative == '.flutter-plugins-dependencies') {
    text = text.replaceAll(_pluginsDateCreated, '');
  }
  return utf8.encode(text);
}
