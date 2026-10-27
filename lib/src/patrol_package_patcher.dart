import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/patrol_android_native_views_patch.dart';
import 'package:mplatrol/src/patrol_ios_native_views_patch.dart';
import 'package:mplatrol/src/patrol_ios_text_input_patch.dart';
import 'package:mplatrol/src/patrol_runtime_skip_patch.dart';
import 'package:mplatrol/src/patrol_safe_failure_report_patch.dart';
import 'package:mplatrol/src/pub_cache.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// Makes the app resolve `patrol` to a patched private copy under `.mplatrol/patched_packages/patrol`, with the
/// fixes the runners rely on: JSON-body native routes on Android, the IPv4 loopback handshake on LambdaTest,
/// full iOS failure details, native views, iOS text input, typed runtime skips and safe failure reports.
///
/// The shared pub cache is never edited; `pubspec_overrides.yaml` points `patrol` at the copy. A copy that
/// matches the resolved Patrol version and carries every patch is reused.
class PatrolPackagePatcher {
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  MplatrolShell get _shell => getDep<MplatrolShell>();
  PlatformWrapper get _platformWrapper => getDep<PlatformWrapper>();

  /// Patrol's Android http4k server (on its ktor-cio backend) returns null
  /// request bodies for JSON-body native routes on the API levels used by the
  /// E2E matrix; seen on 4.6.1, and the server is unchanged through 4.10.0.
  /// Bodyless routes work, but configure/openApp/tap/etc. all NPE before
  /// reaching the automator. Keep the upstream package untouched by creating a generated
  /// working-tree copy and resolving `patrol` to it for E2E builds only.
  Future<void> patch(String repo) async {
    final overrides = File(p.join(repo, 'pubspec_overrides.yaml'));
    if (!overrides.existsSync()) {
      overrides.writeAsStringSync('dependency_overrides: {}\n');
      await _resolveE2eDependencies(repo);
    }
    final doc = loadYaml(overrides.readAsStringSync());
    if (doc is! YamlMap || doc['dependency_overrides'] is! YamlMap) {
      _logger.warn('[patrol-patch] ${overrides.path} has no dependency_overrides map; not patching Patrol');
      return;
    }

    final patchedRoot = Directory(p.join(repo, '.mplatrol', 'patched_packages', 'patrol'));
    var sourceRoot = _patrolPackageRoot(repo);
    if (sourceRoot != null && !_satisfiesDeclaredPatrolConstraint(repo, sourceRoot)) {
      sourceRoot = await _resolvePatrolConstraintMismatch(repo, sourceRoot, overrides, patchedRoot);
    }
    if (sourceRoot == null) {
      _logger.info(
        '[patrol-patch] package_config has no patrol package; '
        'skipping Android JSON body patch',
      );
      return;
    }

    _repairSelfResolvedPatrolCopy(patchedRoot, sourceRoot);
    if (!_isReusablePatrolPatchCopy(patchedRoot, sourceRoot)) {
      if (patchedRoot.existsSync()) {
        patchedRoot.deleteSync(recursive: true);
      }
      _copyDirectory(Directory(sourceRoot), patchedRoot);
    }

    _patchPatrolDartClient(
      File(p.join(patchedRoot.path, 'lib', 'src', 'platform', 'contracts', 'mobile_automator_client.dart')),
    );
    _patchPatrolDartClient(
      File(p.join(patchedRoot.path, 'lib', 'src', 'platform', 'contracts', 'android_automator_client.dart')),
    );
    _patchPatrolAndroidServer(
      File(
        p.join(
          patchedRoot.path,
          'android',
          'src',
          'main',
          'kotlin',
          'pl',
          'leancode',
          'patrol',
          'contracts',
          'MobileAutomatorServer.kt',
        ),
      ),
    );
    _patchPatrolAndroidServer(
      File(
        p.join(
          patchedRoot.path,
          'android',
          'src',
          'main',
          'kotlin',
          'pl',
          'leancode',
          'patrol',
          'contracts',
          'AndroidAutomatorServer.kt',
        ),
      ),
    );
    _patchPatrolAppServiceLoopback(patchedRoot);
    _patchPatrolIosFailureDetails(patchedRoot);
    patchPatrolAndroidNativeViews(patchedRoot);
    patchPatrolIosTextInput(patchedRoot);
    patchPatrolIosNativeViews(patchedRoot);
    patchPatrolRuntimeSkip(patchedRoot);
    patchPatrolSafeFailureReport(patchedRoot);

    overrides.writeAsStringSync(
        _upsertPathOverride(overrides.readAsStringSync(), packageName: 'patrol', path: patchedRoot.path));
    _logger.info('[patrol-patch] patrol override -> ${patchedRoot.path}');
    await _resolveE2eDependencies(repo);
  }

  void _repairSelfResolvedPatrolCopy(Directory root, String sourceRoot) {
    if (!p.equals(sourceRoot, root.path)) {
      return;
    }
    try {
      _patchSelfResolvedPatrolCopy(root);
      // The patch functions report an unpatchable copy as StateError; only a pristine source can recover it.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      final pristine = _pristinePatrolSource(root);
      if (pristine == null) {
        rethrow;
      }
      // A copy patched by an older mplatrol cannot take the current patches in place; the same Patrol version
      // in the pub cache is the pristine source to patch again.
      _logger.info('[patrol-patch] the generated Patrol copy carries an older mplatrol patch (${error.message}); '
          'regenerating it from ${pristine.path}');
      root.deleteSync(recursive: true);
      _copyDirectory(pristine, root);
      _patchSelfResolvedPatrolCopy(root);
    }
  }

  /// The hosted Patrol package of [copy]'s version in the shared pub cache, or null when it is not there.
  Directory? _pristinePatrolSource(Directory copy) {
    final pubspec = File(p.join(copy.path, 'pubspec.yaml'));
    final cache = pubCacheRoot(_platformWrapper.environment);
    if (!pubspec.existsSync() || cache == null) {
      return null;
    }
    final version = (loadYaml(pubspec.readAsStringSync()) as Map?)?['version'];
    final source = Directory(p.join(cache, 'hosted', 'pub.dev', 'patrol-$version'));
    return version is String && source.existsSync() ? source : null;
  }

  void _patchSelfResolvedPatrolCopy(Directory root) {
    if (!hasPatrolAndroidNativeViewsPatch(root)) {
      patchPatrolAndroidNativeViews(root);
    }
    if (!hasPatrolIosTextInputPatch(root)) {
      patchPatrolIosTextInput(root);
    }
    if (!hasPatrolIosNativeViewsPatch(root)) {
      patchPatrolIosNativeViews(root);
    }
    if (!hasPatrolRuntimeSkipPatch(root)) {
      patchPatrolRuntimeSkip(root);
    }
    if (!hasPatrolSafeFailureReportPatch(root)) {
      patchPatrolSafeFailureReport(root);
    }
    if (!_hasCompletePatrolPatchSource(root)) {
      throw StateError('Self-resolved Patrol copy is incomplete; restore pristine source');
    }
  }

  /// False when the resolved `patrol` is outside the app's declared constraint,
  /// e.g. after a `patrol` bump while `pubspec_overrides.yaml` still points at
  /// an older patched copy (in this repo or a stale worktree).
  bool _satisfiesDeclaredPatrolConstraint(String repo, String sourceRoot) {
    final version = _pubspecVersion(sourceRoot);
    final constraint = _declaredPatrolConstraint(repo);
    return version == null || constraint == null || constraint.allows(version);
  }

  /// Drops the stale `patrol` override and patched copy, then re-resolves so
  /// `package_config` points at the pristine `patrol` the pubspec asks for.
  Future<String?> _resolvePristinePatrol(
    String repo,
    File overrides,
    Directory patchedRoot,
  ) async {
    _logger.info(
      '[patrol-patch] resolved patrol does not satisfy the pubspec.yaml '
      'constraint; re-resolving without the patched override',
    );
    final content = overrides.readAsStringSync();
    final dependencyOverrides = (loadYaml(content) as YamlMap)['dependency_overrides'] as YamlMap;
    if (dependencyOverrides.containsKey('patrol')) {
      overrides.writeAsStringSync((YamlEditor(content)..remove(['dependency_overrides', 'patrol'])).toString());
    }
    if (patchedRoot.existsSync()) {
      patchedRoot.deleteSync(recursive: true);
    }
    await _resolveE2eDependencies(repo);
    return _patrolPackageRoot(repo);
  }

  Future<String?> _resolvePatrolConstraintMismatch(
    String repo,
    String sourceRoot,
    File overrides,
    Directory patchedRoot,
  ) async {
    final constraint = _declaredPatrolConstraint(repo);
    final resolved = _pubspecIdentity(sourceRoot);
    final generated = _pubspecIdentity(patchedRoot.path);
    final complete = _hasCompletePatrolPatchSource(patchedRoot);
    _logger.info(
      '[patrol-patch] constraint mismatch: declared=$constraint; '
      'resolved name=${resolved.$1 ?? "missing"} version=${resolved.$2 ?? "missing"}; '
      'generated name=${generated.$1 ?? "missing"} version=${generated.$2 ?? "missing"} '
      'complete=$complete',
    );
    if (generated.$1 == 'patrol' &&
        generated.$2 != null &&
        constraint != null &&
        constraint.allows(generated.$2!) &&
        complete) {
      _logger.info('[patrol-patch] retaining compatible generated Patrol copy; '
          'final dependency resolution will apply its override');
      return patchedRoot.path;
    }
    return _resolvePristinePatrol(repo, overrides, patchedRoot);
  }

  /// A complete patched copy is reused only while it matches the resolved
  /// source version, so a `patrol` bump rebuilds it. A copy that
  /// `package_config` already resolves to is its own source.
  bool _isReusablePatrolPatchCopy(Directory patchedRoot, String sourceRoot) {
    if (!_hasCompletePatrolPatchSource(patchedRoot)) {
      return false;
    }
    return p.equals(sourceRoot, patchedRoot.path) || _pubspecVersion(patchedRoot.path) == _pubspecVersion(sourceRoot);
  }

  Version? _pubspecVersion(String packageRoot) => _pubspecIdentity(packageRoot).$2;

  (String?, Version?) _pubspecIdentity(String packageRoot) {
    final pubspec = File(p.join(packageRoot, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      return (null, null);
    }
    final doc = loadYaml(pubspec.readAsStringSync());
    final name = doc is YamlMap ? doc['name'] : null;
    final version = doc is YamlMap ? doc['version'] : null;
    return (name is String ? name : null, version is String ? Version.parse(version) : null);
  }

  VersionConstraint? _declaredPatrolConstraint(String repo) {
    final pubspec = loadYaml(
      File(p.join(repo, 'pubspec.yaml')).readAsStringSync(),
    );
    for (final section in const ['dev_dependencies', 'dependencies']) {
      final dependencies = pubspec is YamlMap ? pubspec[section] : null;
      final constraint = dependencies is YamlMap ? dependencies['patrol'] : null;
      if (constraint is String) {
        return VersionConstraint.parse(constraint);
      }
    }
    return null;
  }

  bool _hasCompletePatrolPatchSource(Directory root) {
    if (!root.existsSync()) {
      return false;
    }
    for (final relativePath in const [
      ['lib', 'src', 'binding.dart'],
      ['lib', 'src', 'platform', 'contracts', 'mobile_automator_client.dart'],
      ['lib', 'src', 'platform', 'contracts', 'android_automator_client.dart'],
      ['android', 'src', 'main', 'kotlin', 'pl', 'leancode', 'patrol', 'contracts', 'MobileAutomatorServer.kt'],
      ['android', 'src', 'main', 'kotlin', 'pl', 'leancode', 'patrol', 'contracts', 'AndroidAutomatorServer.kt'],
    ]) {
      if (!File(p.joinAll([root.path, ...relativePath])).existsSync()) {
        return false;
      }
    }
    return hasPatrolAndroidNativeViewsPatch(root) &&
        hasPatrolIosTextInputPatch(root) &&
        hasPatrolIosNativeViewsPatch(root) &&
        hasPatrolRuntimeSkipPatch(root) &&
        hasPatrolSafeFailureReportPatch(root);
  }

  String _upsertPathOverride(String content, {required String packageName, required String path}) {
    final doc = loadYaml(content);
    final dependencyOverrides = doc is YamlMap ? doc['dependency_overrides'] : null;
    if (dependencyOverrides is! YamlMap) {
      throw StateError(
        '[patrol-patch] dependency_overrides must be a YAML map in pubspec_overrides.yaml',
      );
    }

    final editor = YamlEditor(content);
    final existingOverride = dependencyOverrides[packageName];
    if (existingOverride is YamlMap && existingOverride.containsKey('path')) {
      editor.update(['dependency_overrides', packageName, 'path'], path);
    } else {
      editor.update(['dependency_overrides', packageName], {'path': path});
    }
    return editor.toString();
  }

  String? _patrolPackageRoot(String repo) {
    final packageConfig = File(p.join(repo, '.dart_tool', 'package_config.json'));
    if (!packageConfig.existsSync()) {
      return null;
    }
    final data = jsonDecode(packageConfig.readAsStringSync());
    if (data is! Map<String, dynamic>) {
      return null;
    }
    final packages = data['packages'];
    if (packages is! List) {
      return null;
    }
    final patrol = packages
        .whereType<Map>()
        .cast<Map<Object?, Object?>>()
        .where((package) => package['name'] == 'patrol')
        .firstOrNull;
    final rootUri = patrol?['rootUri'];
    if (rootUri is! String || rootUri.isEmpty) {
      return null;
    }
    final uri = Uri.parse(rootUri);
    if (uri.scheme == 'file') {
      return p.fromUri(uri);
    }
    return p.normalize(p.join(p.dirname(packageConfig.path), uri.path));
  }

  void _copyDirectory(Directory source, Directory target) {
    target.createSync(recursive: true);
    for (final entry in source.listSync(followLinks: false)) {
      final targetPath = p.join(target.path, p.basename(entry.path));
      if (entry is Directory) {
        _copyDirectory(entry, Directory(targetPath));
      } else if (entry is File) {
        entry.copySync(targetPath);
        // coverage:ignore-start
      } else if (entry is Link) {
        Link(targetPath).createSync(entry.targetSync(), recursive: true);
      }
      // coverage:ignore-end
    }
  }

  void _patchPatrolDartClient(File file) {
    final content = file.readAsStringSync();
    if (content.contains('patrolRequest')) {
      return;
    }
    const original = '''
    final response = await _client
        .post(
          _apiUri.resolve(requestName),
          body: jsonEncode(request),
          headers: _headers,
        )
        .timeout(_timeout);
''';
    const patched = '''
    final encodedRequest = request == null ? null : jsonEncode(request);
    final requestUri = encodedRequest == null
        ? _apiUri.resolve(requestName)
        : _apiUri
            .resolve(requestName)
            .replace(queryParameters: {'patrolRequest': encodedRequest});
    final response = await _client
        .post(
          requestUri,
          body: encodedRequest ?? jsonEncode(request),
          headers: _headers,
        )
        .timeout(_timeout);
''';
    file.writeAsStringSync(content.replaceFirst(original, patched));
  }

  /// Pins the on-device Patrol handshake (test app → PatrolAppService on
  /// loopback:8082) to the IPv4 loopback address. On LambdaTest a "localhost"
  /// request that reaches the device's global HTTP proxy (the tunnel) is
  /// forwarded to the tunnel HOST, which dials [::1]:8082 there — nothing
  /// listens, and every test fails in seconds with "Invalid response 503,
  /// dial tcp [::1]:8082". The contracts client no longer needs the old
  /// OkHttp NO_PROXY pin: since Patrol 4.7.0 it uses Ktor's CIO engine, and
  /// Patrol 4.10.0 pins `ktor-bom` 3.2.2, whose CIO engine never consults the
  /// system proxy. Ktor 3.3.0+ CIO falls back to `ProxySelector`, so revisit
  /// this if the resolved Ktor is bumped.
  void _patchPatrolAppServiceLoopback(Directory patchedRoot) {
    final outerClient = File(p.join(
        patchedRoot.path, 'android', 'src', 'main', 'kotlin', 'pl', 'leancode', 'patrol', 'PatrolAppServiceClient.kt'));
    if (outerClient.existsSync()) {
      outerClient.writeAsStringSync(
        outerClient.readAsStringSync().replaceAll('address = "localhost"', 'address = "127.0.0.1"'),
      );
    }
  }

  void _patchPatrolIosFailureDetails(Directory patchedRoot) {
    final binding = File(p.join(patchedRoot.path, 'lib', 'src', 'binding.dart'));
    if (!binding.existsSync()) {
      return;
    }
    final content = binding.readAsStringSync();
    final original = RegExp(
      r'^([ \t]*)final detailsAsString = \(kReleaseMode && current_platform\.isIOS\)\n'
      r"\1    \? '\$\{details\.exceptionAsString\(\)\}\\n\$\{details\.stack\}'\n"
      r'\1    : details\.toString\(\);',
      multiLine: true,
    );
    final patched = content.replaceFirstMapped(original, (match) {
      final indent = match[1] ?? '';
      return '$indent'
          'final detailsAsString = current_platform.isIOS\n'
          "$indent    ? '\${details.exceptionAsString()}\\n\${details.stack}'\n"
          '$indent    : details.toString();';
    });
    if (patched == content) {
      return;
    }
    binding.writeAsStringSync(patched);
  }

  void _patchPatrolAndroidServer(File file) {
    var content = file.readAsStringSync();
    if (!content.contains('private fun requestJson(request: Request)')) {
      content = content.replaceFirst(
        'import org.http4k.core.Response\n',
        'import org.http4k.core.Request\n'
            'import org.http4k.core.Response\n',
      );
      content = content.replaceFirst('private val json = Gson()\n', '''
private val json = Gson()

private fun requestJson(request: Request): String {
    val body = request.bodyString()
    return if (body.isNotBlank() && body != "null") {
        body
    } else {
        request.query("patrolRequest") ?: "null"
    }
}
''');
    }
    final patched = content.replaceAll('it.bodyString()', 'requestJson(it)');
    if (patched.contains('it.bodyString()') ||
        !patched.contains('private fun requestJson(request: Request)') ||
        !patched.contains('import org.http4k.core.Request')) {
      throw Exception(
        '[patrol-patch] ${file.path} layout changed for the resolved patrol '
        'version; _patchPatrolAndroidServer applied only partially. Update its '
        'literals for the new patrol revision.',
      );
    }
    file.writeAsStringSync(patched);
  }

  Future<void> _resolveE2eDependencies(String repo) => _withProgress(
        'Resolving E2E dependencies',
        () => _shell.run('flutter pub get', workingDirectory: repo),
        completeMessage: 'Resolved E2E dependencies',
      );

  Future<T> _withProgress<T>(String message, Future<T> Function() action, {String? completeMessage}) async {
    final progress = _logger.progress(message);
    try {
      final result = await action();
      progress.complete(completeMessage ?? message);
      return result;
    } catch (_) {
      progress.fail('$message failed');
      rethrow;
    }
  }
}
