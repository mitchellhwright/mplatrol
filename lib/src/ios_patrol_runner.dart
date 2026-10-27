import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:mplatrol/src/patrol_ios_native_views_patch.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:mplatrol/src/write_if_changed.dart';
import 'package:path/path.dart' as p;

/// Seconds an iOS shard keeps retrying the mplatrol shard coordinator (with
/// exponential backoff capped at 10s) before it reports itself NOT RUN.
const iosCoordinatorWindowSeconds = 120;

/// Seconds the iOS runner waits for one Dart test's result before failing that
/// test (and terminating the app) so the next test can still run.
const iosRunDartTestTimeoutSeconds = 180;

/// Extra seconds before the runner's hard phase deadline stops the whole
/// process; it must outlast [iosRunDartTestTimeoutSeconds] so a slow test is
/// reported as that test's failure instead of a runner crash.
const iosRunDartTestDeadlineGraceSeconds = 30;

/// Generates `ios/RunnerUITests/RunnerUITests.swift` — a SWIFT Patrol runner
/// whose `LoginE2ETests` class LambdaTest HyperExecute's `ios/xcui` discovery can
/// enumerate. That discovery (`Discovery Mode: local`) only lists a test class
/// when ALL of these hold, and stock Patrol's Obj-C runner violates every one
/// (empirically isolated, 2026-06-06):
///  * it is a **Swift** XCTestCase subclass (Obj-C classes are invisible);
///  * its name is **not** the test target name `RunnerUITests` (a class named
///    after the target is skipped) — hence `LoginE2ETests`;
///  * its test methods are **camelCase** `testXxx` (the snake_case `test_xxx`
///    form is skipped — discovery matches `test[A-Z]`);
///  * the class is **not `final`** (a `final` Swift class is skipped);
///  * it has **no `@objc(RunnerUITests)`** (that re-adds the skipped name to the
///    Obj-C class list).
///
/// Patrol's server/client + the one-time Dart-test list live in a separate
/// `enum PatrolBridge`, NOT as stored properties on the XCTestCase: a test class
/// whose Swift field metadata references cross-module Patrol types is also
/// skipped by discovery, so the test class stays metadata-clean.
///
/// [bundleId] is the app's `PRODUCT_BUNDLE_IDENTIFIER`; when present
/// the runner launches it by id because LambdaTest's `.xctestrun` carries no
/// `UITargetAppPath`. Local `patrol test` may provide the target app itself, so
/// an empty bundle id falls back to bare `XCUIApplication()`. [target] restricts
/// generation to one Patrol `*_test.dart` file. Returns the number of
/// test methods generated.
int generateIosPatrolRunner(
  String repo, {
  String bundleId = '',
  bool disableCodeSigning = true,
  bool keepGenericRunnerBundleId = false,
  String? onlyTest,
  String? target,
  String? targetRegex,
  String? sdk,
  String selectionCoordinatorUrl = '',
  Map<String, String>? env,
  PatrolSelectionPlan? selection,
}) {
  var tests = _iosTests(
    repo,
    target: target,
    targetRegex: targetRegex,
    sdk: sdk,
    env: env,
    selection: selection,
  );
  if (onlyTest != null) {
    tests = tests.where((test) => test.method == onlyTest).toList();
  }
  if (tests.isEmpty) {
    throw StateError(
      'No patrolTest()${onlyTest == null ? '' : ' named "$onlyTest"'} found '
      'in ${target ?? patrolTestDirectoryPath(repo)} '
      '${targetRegex == null ? '' : 'matching /$targetRegex/ '}'
      '${sdk == null ? '' : 'for SDK "$sdk" '}— nothing to generate. '
      'Patrol runner left unchanged.',
    );
  }
  ensureIosPatrolProject(
    repo,
    bundleId: bundleId,
    disableCodeSigning: disableCodeSigning,
    keepGenericRunnerBundleId: keepGenericRunnerBundleId,
  );
  writeIfChanged(File(p.join(repo, _runnerRelativePath)), _render(tests, bundleId, selectionCoordinatorUrl));
  return tests.length;
}

/// Restores the generated working-tree iOS UI-test target that a prepare step can
/// remove. This target is not committed from the app; `mplatrol`
/// recreates it before CocoaPods/Xcode need it.
void ensureIosPatrolProject(
  String repo, {
  String bundleId = '',
  bool disableCodeSigning = true,
  bool keepGenericRunnerBundleId = false,
}) {
  _ensureRunnerUiTestsFiles(repo);
  _ensureRunnerUiTestsPodfileTarget(repo);
  _ensureSwiftRunnerInXcodeProject(
    repo,
    bundleId: bundleId,
    disableCodeSigning: disableCodeSigning,
    keepGenericRunnerBundleId: keepGenericRunnerBundleId,
  );
  _ensureRunnerUiTestsScheme(repo);
}

/// One [IosTestShard] per Patrol test. Each becomes a HyperExecute `shards`
/// mapping whose `only-testing` value is [onlyTesting]; the HyperExecute task
/// name uses [method] so the dashboard parent row matches the XCTest child row.
List<IosTestShard> iosTestShards(
  String repo, {
  String? target,
  String? targetRegex,
  String? sdk,
  Map<String, String>? env,
  PatrolSelectionPlan? selection,
}) =>
    _iosTests(
      repo,
      target: target,
      targetRegex: targetRegex,
      sdk: sdk,
      env: env,
      selection: selection,
    ).map((test) => IosTestShard(method: test.method, description: test.description)).toList();

/// The Swift test class name. MUST differ from the test target name
/// `RunnerUITests` — LambdaTest discovery skips a class named after the target.
const _swiftClassName = 'LoginE2ETests';

/// Returns the identity of canonical compiled Swift generator output.
///
/// Fixed sample inputs cover normal and coordinator templatroles without hashing
/// runtime credentials, paths, or dynamically assigned coordinator ports.
String iosPatrolGeneratorIdentity() {
  final tests = [_IosTest('testIdentity', 'identity journey', 'identity_test')];
  return (FingerprintBuilder()
        ..addString(patrolIosNativeViewsPatchIdentity())
        ..addString(_render(tests, 'identity.app', ''))
        ..addString(_render(tests, 'identity.app', 'http://identity.invalid')))
      .finish();
}

const _runnerRelativePath = 'ios/RunnerUITests/RunnerUITests.swift';

const _xcodeProjectRelativePath = 'ios/Runner.xcodeproj/project.pbxproj';

const _xcodeSchemeRelativePath = 'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme';

const _podfileRelativePath = 'ios/Podfile';

const _swiftRunnerFileRefId = '5201F4411EAF4858888561A7';

const _swiftRunnerBuildFileId = '3EDA5D41A9364C4D95867227';

const _uiTestsTargetId = '08693F719B49CEB16EFFFD06';
const _uiTestsProductRefId = '0C7245C85FEBF256923A9D0D';
const _uiTestsGroupId = 'B99524184C8B45ECA36E73F8';
const _uiTestsSourcesPhaseId = 'DAE17DAA9EDB4BD781A8B8EB';
const _uiTestsFrameworksPhaseId = 'D6BFBD845419EF0D952D274F';
const _uiTestsResourcesPhaseId = 'AD72E5323D42A476C7646613';
const _uiTestsConfigListId = '57F2DDF80270D58774D558C3';
const _uiTestsDebugConfigId = 'B373B11E81418CC84610FC6F';
const _uiTestsReleaseConfigId = '3B222A8B6FAB79989253D438';
const _uiTestsProfileConfigId = '90FF57DECF6C79446EA5D183';
const _uiTestsDependencyId = 'EE415FC7218DEA78E3EBE7AC';
const _uiTestsProxyId = '6E8A3F19BA2C42B8A1D0D5AA';
const _uiTestsInfoPlistRefId = '0E1733DA0CA44FF880C3BF29';
const _uiTestsSpmBuildFileId = '4F1C2A7D8E9B0C1D2E3F4A5B';
const _uiTestsSpmProductRefId = '4F1C2A7D8E9B0C1D2E3F4A5C';
const _flutterSpmPackage = 'FlutterGeneratedPluginSwiftPackage';

/// A discovered XCTest shard for the LambdaTest iOS HyperExecute run.
class IosTestShard {
  IosTestShard({required this.method, required this.description});

  /// The generated XCTest method name, used by [generateIosPatrolRunner]'s
  /// `onlyTest` filter when building one uploaded `.xctest` per Patrol test.
  final String method;

  /// The human Patrol test description, used in the LambdaTest build name.
  final String description;

  /// The class/method value LambdaTest reports during HyperExecute discovery.
  ///
  /// LambdaTest iOS discovery emits `LoginE2ETests/<method>` for this generated
  /// Swift class. A target-qualified value (`RunnerUITests/LoginE2ETests/...`)
  /// is accepted by XCTest locally but is rejected by HyperExecute discovery.
  String get onlyTesting => '$_swiftClassName/$method';

  /// A readable legacy task label for [description].
  String get taskName => _taskName(description);
}

/// The generated XCTest method HyperExecute should launch for coordinator runs.
String iosCoordinatorShardOnlyTesting(int index, int count) =>
    '$_swiftClassName/${iosCoordinatorShardMethod(index, count)}';

/// A stable, discovery-safe XCTest method name for a coordinator shard.
String iosCoordinatorShardMethod(int index, int count) {
  if (index < 0 || index >= count) {
    throw RangeError.range(index, 0, count - 1, 'index');
  }
  final width = count >= 100 ? 3 : 2;
  return 'testShard${(index + 1).toString().padLeft(width, '0')}';
}

/// A Patrol test flattened for the single Swift class, with its method name made
/// unique ACROSS files (discovery only dedupes within a file).
class _IosTest {
  _IosTest(this.method, this.description, this.group);

  final String method;
  final String description;
  final String group;
}

List<_IosTest> _iosTests(
  String repo, {
  String? target,
  String? targetRegex,
  String? sdk,
  Map<String, String>? env,
  PatrolSelectionPlan? selection,
}) {
  final seen = <String>{};
  final tests = <_IosTest>[];
  for (final file in discoverPatrolTestFiles(
    repo,
    target: target,
    targetRegex: targetRegex,
    sdk: sdk,
    environment: env,
    selection: selection,
  )) {
    for (final test in file.tests) {
      var method = _orderedCamelMethod(file.basename, test.description);
      if (!seen.add(method)) {
        var index = 2;
        while (!seen.add('$method$index')) {
          index++;
        }
        method = '$method$index';
      }
      tests.add(_IosTest(method, test.description, file.basename));
    }
  }
  tests.sort((a, b) => a.method.compareTo(b.method));
  return tests;
}

/// The camelCase XCTest method name for [description]: `test` + an ordering
/// prefix + each word's first letter upper-cased (the rest preserved, so
/// `WebView`/`MFA` stay intact). LambdaTest discovery requires the `test[A-Z]`
/// (camelCase) form.
///
/// XCTest orders methods by name, so the prefix puts the happy login before
/// destructive fault scenarios in the declared order (`--order=declared`). A
/// seeded random order (the default) reorders them at runtime: see
/// `PatrolBridge.orderedMethods` and the LambdaTest shard coordinator. The Dart
/// group/description and LT task name remain unchanged.
String _orderedCamelMethod(String group, String description) {
  final base = _camelMethod(description);
  final orderPrefix = _isHappyLoginTest(group) ? 'A' : 'B';
  return 'test$orderPrefix${base.substring('test'.length)}';
}

bool _isHappyLoginTest(String group) => group == 'patrol_login_test';

/// The camelCase XCTest method body for [description].
String _camelMethod(String description) {
  final words = description.split(RegExp('[^A-Za-z0-9]+')).where((word) => word.isNotEmpty);
  final buffer = StringBuffer('test');
  for (final word in words) {
    buffer.write(word[0].toUpperCase() + word.substring(1));
  }
  return buffer.toString();
}

/// A readable, HyperExecute-safe Task name for [description] (lowercase words
/// joined by underscores; only `[A-Za-z0-9_]`).
String _taskName(String description) =>
    description.toLowerCase().split(RegExp('[^a-z0-9]+')).where((word) => word.isNotEmpty).join('_');

void _ensureRunnerUiTestsFiles(String repo) {
  final dir = Directory(p.join(repo, 'ios', 'RunnerUITests'))..createSync(recursive: true);
  final infoPlist = File(p.join(dir.path, 'Info.plist'));
  if (!infoPlist.existsSync()) {
    infoPlist.writeAsStringSync(_uiTestsInfoPlist);
  }
  final runner = File(p.join(repo, _runnerRelativePath));
  if (!runner.existsSync()) {
    runner.writeAsStringSync(_placeholderSwiftRunner);
  }
}

void _ensureRunnerUiTestsPodfileTarget(String repo) {
  final podfile = File(p.join(repo, _podfileRelativePath));
  if (!podfile.existsSync()) {
    return;
  }
  var source = podfile.readAsStringSync();
  if (source.contains("target 'RunnerUITests'")) {
    return;
  }
  const installLine = '  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))';
  final insertAt = source.indexOf(installLine);
  if (insertAt < 0) {
    return;
  }
  final afterInstallLine = source.indexOf('\n', insertAt);
  if (afterInstallLine < 0) {
    return;
  }
  const targetBlock = '''

  # Patrol-flavored XCUITest bundle for `mplatrol`.
  target 'RunnerUITests' do
    inherit! :complete
  end
''';
  source = source.replaceRange(afterInstallLine, afterInstallLine, targetBlock);
  podfile.writeAsStringSync(source);
}

void _ensureSwiftRunnerInXcodeProject(
  String repo, {
  required String bundleId,
  required bool disableCodeSigning,
  required bool keepGenericRunnerBundleId,
}) {
  final projectFile = File(p.join(repo, _xcodeProjectRelativePath));
  if (!projectFile.existsSync()) {
    return;
  }
  var source = projectFile.readAsStringSync();
  source = _ensureRunnerUiTestsTarget(
    source,
    disableCodeSigning: disableCodeSigning,
  );
  if (!keepGenericRunnerBundleId) {
    source = _ensureRunnerUiTestsBundleId(source, bundleId);
  }
  source = _ensureRunnerUiTestsCodeSigning(
    source,
    disableCodeSigning: disableCodeSigning,
  );
  source = _ensureRunnerUiTestsSwiftMembership(source);
  source = _ensureRunnerUiTestsSwiftPackage(source);
  writeIfChanged(projectFile, source);
}

String _ensureRunnerUiTestsTarget(
  String source, {
  required bool disableCodeSigning,
}) {
  if (source.contains('/* RunnerUITests */ = {') &&
      source.contains('productType = "com.apple.product-type.bundle.ui-testing";')) {
    return _addTargetToProject(source);
  }

  final projectId = _requiredId(source, RegExp(r'([0-9A-F]{24}) /\* Project object \*/ = \{'), 'PBXProject');
  final runnerTargetId = _requiredId(
    source,
    RegExp(r'([0-9A-F]{24}) /\* Runner \*/ = \{\s+isa = PBXNativeTarget;', dotAll: true),
    'Runner target',
  );
  final mainGroupId = _requiredId(source, RegExp('mainGroup = ([0-9A-F]{24});'), 'mainGroup');
  final productsGroupId = _requiredId(
    source,
    RegExp(r'productRefGroup = ([0-9A-F]{24}) /\* Products \*/;'),
    'Products group',
  );

  var updated = _insertBeforeSectionEnd(
    source,
    'PBXBuildFile',
    '\t\t$_swiftRunnerBuildFileId /* RunnerUITests.swift in Sources */ = '
        '{isa = PBXBuildFile; fileRef = $_swiftRunnerFileRefId '
        '/* RunnerUITests.swift */; };\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXContainerItemProxy',
    '\t\t$_uiTestsProxyId /* PBXContainerItemProxy */ = {\n'
        '\t\t\tisa = PBXContainerItemProxy;\n'
        '\t\t\tcontainerPortal = $projectId /* Project object */;\n'
        '\t\t\tproxyType = 1;\n'
        '\t\t\tremoteGlobalIDString = $runnerTargetId;\n'
        '\t\t\tremoteInfo = Runner;\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXFileReference',
    '\t\t$_uiTestsProductRefId /* RunnerUITests.xctest */ = '
        '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; '
        'includeInIndex = 0; path = RunnerUITests.xctest; '
        'sourceTree = BUILT_PRODUCTS_DIR; };\n'
        '\t\t$_uiTestsInfoPlistRefId /* Info.plist */ = '
        '{isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
        'path = Info.plist; sourceTree = "<group>"; };\n'
        '\t\t$_swiftRunnerFileRefId /* RunnerUITests.swift */ = '
        '{isa = PBXFileReference; includeInIndex = 1; '
        'lastKnownFileType = sourcecode.swift; path = RunnerUITests.swift; '
        'sourceTree = "<group>"; };\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXFrameworksBuildPhase',
    '\t\t$_uiTestsFrameworksPhaseId /* Frameworks */ = {\n'
        '\t\t\tisa = PBXFrameworksBuildPhase;\n'
        '\t\t\tbuildActionMask = 2147483647;\n'
        '\t\t\tfiles = (\n'
        '\t\t\t);\n'
        '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXGroup',
    '\t\t$_uiTestsGroupId /* RunnerUITests */ = {\n'
        '\t\t\tisa = PBXGroup;\n'
        '\t\t\tchildren = (\n'
        '\t\t\t\t$_uiTestsInfoPlistRefId /* Info.plist */,\n'
        '\t\t\t\t$_swiftRunnerFileRefId /* RunnerUITests.swift */,\n'
        '\t\t\t);\n'
        '\t\t\tpath = RunnerUITests;\n'
        '\t\t\tsourceTree = "<group>";\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXNativeTarget',
    '\t\t$_uiTestsTargetId /* RunnerUITests */ = {\n'
        '\t\t\tisa = PBXNativeTarget;\n'
        '\t\t\tbuildConfigurationList = $_uiTestsConfigListId '
        '/* Build configuration list for PBXNativeTarget "RunnerUITests" */;\n'
        '\t\t\tbuildPhases = (\n'
        '\t\t\t\t$_uiTestsSourcesPhaseId /* Sources */,\n'
        '\t\t\t\t$_uiTestsFrameworksPhaseId /* Frameworks */,\n'
        '\t\t\t\t$_uiTestsResourcesPhaseId /* Resources */,\n'
        '\t\t\t);\n'
        '\t\t\tbuildRules = (\n'
        '\t\t\t);\n'
        '\t\t\tdependencies = (\n'
        '\t\t\t\t$_uiTestsDependencyId /* PBXTargetDependency */,\n'
        '\t\t\t);\n'
        '\t\t\tname = RunnerUITests;\n'
        '\t\t\tproductName = RunnerUITests;\n'
        '\t\t\tproductReference = $_uiTestsProductRefId '
        '/* RunnerUITests.xctest */;\n'
        '\t\t\tproductType = "com.apple.product-type.bundle.ui-testing";\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXResourcesBuildPhase',
    '\t\t$_uiTestsResourcesPhaseId /* Resources */ = {\n'
        '\t\t\tisa = PBXResourcesBuildPhase;\n'
        '\t\t\tbuildActionMask = 2147483647;\n'
        '\t\t\tfiles = (\n'
        '\t\t\t);\n'
        '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXSourcesBuildPhase',
    '\t\t$_uiTestsSourcesPhaseId /* Sources */ = {\n'
        '\t\t\tisa = PBXSourcesBuildPhase;\n'
        '\t\t\tbuildActionMask = 2147483647;\n'
        '\t\t\tfiles = (\n'
        '\t\t\t\t$_swiftRunnerBuildFileId '
        '/* RunnerUITests.swift in Sources */,\n'
        '\t\t\t);\n'
        '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXTargetDependency',
    '\t\t$_uiTestsDependencyId /* PBXTargetDependency */ = {\n'
        '\t\t\tisa = PBXTargetDependency;\n'
        '\t\t\ttarget = $runnerTargetId /* Runner */;\n'
        '\t\t\ttargetProxy = $_uiTestsProxyId /* PBXContainerItemProxy */;\n'
        '\t\t};\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'XCBuildConfiguration',
    _uiTestsBuildConfiguration(
          _uiTestsReleaseConfigId,
          'Release',
          disableCodeSigning: disableCodeSigning,
        ) +
        _uiTestsBuildConfiguration(
          _uiTestsDebugConfigId,
          'Debug',
          disableCodeSigning: disableCodeSigning,
        ) +
        _uiTestsBuildConfiguration(
          _uiTestsProfileConfigId,
          'Profile',
          disableCodeSigning: disableCodeSigning,
        ),
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'XCConfigurationList',
    '\t\t$_uiTestsConfigListId '
        '/* Build configuration list for PBXNativeTarget "RunnerUITests" */ = {\n'
        '\t\t\tisa = XCConfigurationList;\n'
        '\t\t\tbuildConfigurations = (\n'
        '\t\t\t\t$_uiTestsDebugConfigId /* Debug */,\n'
        '\t\t\t\t$_uiTestsReleaseConfigId /* Release */,\n'
        '\t\t\t\t$_uiTestsProfileConfigId /* Profile */,\n'
        '\t\t\t);\n'
        '\t\t\tdefaultConfigurationIsVisible = 0;\n'
        '\t\t\tdefaultConfigurationName = Release;\n'
        '\t\t};\n',
  );

  updated = _addChildToGroup(updated, mainGroupId, '$_uiTestsGroupId /* RunnerUITests */,');
  updated = _addChildToGroup(updated, productsGroupId, '$_uiTestsProductRefId /* RunnerUITests.xctest */,');
  updated = _addTargetToProject(updated);
  return updated;
}

String _ensureRunnerUiTestsBundleId(String source, String bundleId) {
  if (bundleId.trim().isEmpty) {
    return source;
  }
  return source.replaceAllMapped(RegExp('PRODUCT_BUNDLE_IDENTIFIER = [^;]+;'), (match) {
    final configStart = source.lastIndexOf('isa = XCBuildConfiguration;', match.start);
    final configEnd = source.indexOf('name = ', match.end);
    final config = configStart >= 0 && configEnd >= 0 ? source.substring(configStart, configEnd) : '';
    if (!config.contains('INFOPLIST_FILE = RunnerUITests/Info.plist;')) {
      return match.group(0)!;
    }
    return 'PRODUCT_BUNDLE_IDENTIFIER = $bundleId.uitests;';
  });
}

String _ensureRunnerUiTestsSwiftMembership(String source) {
  var updated = _ensureRunnerUiTestsFileRef(source);
  updated = _ensureRunnerUiTestsBuildFile(updated);
  updated = _ensureRunnerUiTestsGroupMembership(updated);
  updated = _ensureRunnerUiTestsSourcesMembership(updated);
  return updated;
}

String _ensureRunnerUiTestsFileRef(String source) {
  if (source.contains(
    '/* RunnerUITests.swift */ = '
    '{isa = PBXFileReference;',
  )) {
    return source;
  }
  return _insertBeforeSectionEnd(
    source,
    'PBXFileReference',
    '\t\t$_swiftRunnerFileRefId /* RunnerUITests.swift */ = '
        '{isa = PBXFileReference; includeInIndex = 1; '
        'lastKnownFileType = sourcecode.swift; path = RunnerUITests.swift; '
        'sourceTree = "<group>"; };\n',
  );
}

String _ensureRunnerUiTestsBuildFile(String source) {
  if (source.contains(
    '/* RunnerUITests.swift in Sources */ = '
    '{isa = PBXBuildFile;',
  )) {
    return source;
  }
  return _insertBeforeSectionEnd(
    source,
    'PBXBuildFile',
    '\t\t$_swiftRunnerBuildFileId /* RunnerUITests.swift in Sources */ = '
        '{isa = PBXBuildFile; fileRef = $_swiftRunnerFileRefId '
        '/* RunnerUITests.swift */; };\n',
  );
}

String _ensureRunnerUiTestsGroupMembership(String source) {
  final match = _runnerUiTestsGroupPattern.firstMatch(source);
  if (match == null) {
    return _recreateRunnerUiTestsGroup(source);
  }
  var group = match.group(0)!;
  if (!group.contains('RunnerUITests.swift */,')) {
    group = group.replaceFirst(
      'children = (\n',
      'children = (\n\t\t\t\t$_swiftRunnerFileRefId '
          '/* RunnerUITests.swift */,\n',
    );
  }
  return source.replaceRange(match.start, match.end, group);
}

/// Rebuilds the RunnerUITests group after `pod install` pruned it.
///
/// CocoaPods reserializes the user project from the root object and drops
/// anything unreachable. A pruned group leaves the Swift file ref alive (its
/// PBXBuildFile keeps it reachable) but parentless, so its "`<group>`"-relative
/// `path = RunnerUITests.swift` resolves against the project root instead of
/// ios/RunnerUITests/ and xcodebuild fails on a missing source file. The
/// recreated group restores the directory component and is attached to the
/// mainGroup so the next reserialization keeps it.
String _recreateRunnerUiTestsGroup(String source) {
  final refMatch = RegExp(
    r'([0-9A-F]{24}) /\* RunnerUITests\.swift \*/ = \{isa = PBXFileReference;',
  ).firstMatch(source);
  if (refMatch == null) {
    return source;
  }
  final refId = refMatch.group(1)!;
  var updated = _insertBeforeSectionEnd(
    source,
    'PBXGroup',
    '\t\t$_uiTestsGroupId /* RunnerUITests */ = {\n'
        '\t\t\tisa = PBXGroup;\n'
        '\t\t\tchildren = (\n'
        '\t\t\t\t$refId /* RunnerUITests.swift */,\n'
        '\t\t\t);\n'
        '\t\t\tpath = RunnerUITests;\n'
        '\t\t\tsourceTree = "<group>";\n'
        '\t\t};\n',
  );
  final mainGroupId = RegExp('mainGroup = ([0-9A-F]{24});').firstMatch(updated)?.group(1);
  if (mainGroupId != null) {
    updated = _addChildToGroup(updated, mainGroupId, '$_uiTestsGroupId /* RunnerUITests */,');
  }
  return updated;
}

String _ensureRunnerUiTestsSourcesMembership(String source) {
  final match = _runnerUiTestsSourcesPhasePattern.firstMatch(source);
  if (match == null) {
    return source;
  }
  var phase = match.group(0)!;
  phase = phase.replaceAll(RegExp(r'\n\s+[0-9A-F]{24} /\* RunnerUITests\.m in Sources \*/,'), '');
  phase = phase.replaceAll(RegExp(r'\n\s+[0-9A-F]{24} /\* SwiftStub\.swift in Sources \*/,'), '');
  if (!phase.contains('RunnerUITests.swift in Sources')) {
    phase = phase.replaceFirst(
      'files = (\n',
      'files = (\n\t\t\t\t$_swiftRunnerBuildFileId '
          '/* RunnerUITests.swift in Sources */,\n',
    );
  }
  return source.replaceRange(match.start, match.end, phase);
}

String _requiredId(String source, RegExp pattern, String description) {
  final id = pattern.firstMatch(source)?.group(1);
  if (id == null) {
    throw StateError('Could not find $description in Xcode project.');
  }
  return id;
}

/// With Flutter's Swift Package Manager integration, plugins (Patrol included)
/// come from [_flutterSpmPackage], which Flutter links only into the Runner app.
/// RunnerUITests imports `patrol` too, so it gets its own product dependency on
/// that package, as in Patrol's example app; with CocoaPods the Podfile's
/// RunnerUITests target did this. Projects without the package are unchanged.
String _ensureRunnerUiTestsSwiftPackage(String source) {
  if (!source.contains('productName = $_flutterSpmPackage;') || source.contains(_uiTestsSpmProductRefId)) {
    return source;
  }
  final target = RegExp(
    r'[0-9A-F]{24} /\* RunnerUITests \*/ = \{\s+isa = PBXNativeTarget;.*?\n\t\t\};',
    dotAll: true,
  ).firstMatch(source);
  final frameworksPhaseId =
      target == null ? null : RegExp(r'([0-9A-F]{24}) /\* Frameworks \*/,').firstMatch(target.group(0)!)?.group(1);
  if (target == null || frameworksPhaseId == null) {
    return source;
  }
  final targetBlock = target.group(0)!;
  var updated = source.replaceFirst(
    targetBlock,
    targetBlock.replaceFirst(
      '\t\t\tname = RunnerUITests;\n',
      '\t\t\tname = RunnerUITests;\n'
          '\t\t\tpackageProductDependencies = (\n'
          '\t\t\t\t$_uiTestsSpmProductRefId /* $_flutterSpmPackage */,\n'
          '\t\t\t);\n',
    ),
  );
  updated = updated.replaceFirstMapped(
    RegExp('($frameworksPhaseId /\\* Frameworks \\*/ = \\{\\s+isa = PBXFrameworksBuildPhase;'
        r'\s+buildActionMask = \d+;\s+files = \(\n)'),
    (match) => '${match.group(1)}\t\t\t\t$_uiTestsSpmBuildFileId '
        '/* $_flutterSpmPackage in Frameworks */,\n',
  );
  updated = _insertBeforeSectionEnd(
    updated,
    'PBXBuildFile',
    '\t\t$_uiTestsSpmBuildFileId /* $_flutterSpmPackage in Frameworks */ = '
        '{isa = PBXBuildFile; productRef = $_uiTestsSpmProductRefId /* $_flutterSpmPackage */; };\n',
  );
  return _insertBeforeSectionEnd(
    updated,
    'XCSwiftPackageProductDependency',
    '\t\t$_uiTestsSpmProductRefId /* $_flutterSpmPackage */ = {\n'
        '\t\t\tisa = XCSwiftPackageProductDependency;\n'
        '\t\t\tproductName = $_flutterSpmPackage;\n'
        '\t\t};\n',
  );
}

String _insertBeforeSectionEnd(String source, String section, String insertion) {
  if (insertion.trim().isEmpty) {
    return source;
  }
  final end = '/* End $section section */';
  final index = source.indexOf(end);
  if (index < 0) {
    return source;
  }
  final idMatch = RegExp(r'^\s*([0-9A-F]{24}) ', multiLine: true).firstMatch(insertion);
  if (idMatch != null) {
    final id = idMatch.group(1)!;
    final existingObject = RegExp('^\\s*$id /\\*.*?\\*/ =', multiLine: true);
    if (existingObject.hasMatch(source)) {
      return source;
    }
  }
  return source.replaceRange(index, index, insertion);
}

String _addChildToGroup(String source, String groupId, String childLine) {
  // The `/* name */` comment is optional: Flutter's mainGroup is serialized
  // WITHOUT one. Requiring it left the RunnerUITests group detached from the
  // root object, and `pod install` prunes unreachable objects when it
  // reserializes the project — orphaning the Swift file ref and breaking the
  // test build with a missing-source error.
  final pattern = RegExp('$groupId (/\\* .*? \\*/ )?= \\{[\\s\\S]*?\\n\\s+\\};');
  final match = pattern.firstMatch(source);
  if (match == null) {
    return source;
  }
  var group = match.group(0)!;
  if (group.contains(childLine)) {
    return source;
  }
  group = group.replaceFirst('children = (\n', 'children = (\n\t\t\t\t$childLine\n');
  return source.replaceRange(match.start, match.end, group);
}

String _addTargetToProject(String source) {
  const sectionEndMarker = '/* End PBXProject section */';
  final sectionStart = source.indexOf('/* Begin PBXProject section */');
  if (sectionStart < 0) {
    return source;
  }
  final sectionEnd = source.indexOf(sectionEndMarker, sectionStart);
  if (sectionEnd < 0) {
    return source;
  }
  final section = source.substring(sectionStart, sectionEnd);
  if (section.contains('$_uiTestsTargetId /* RunnerUITests */')) {
    return source;
  }
  final targetsIndex = section.indexOf('targets = (');
  if (targetsIndex < 0) {
    return source;
  }
  final targetsLineEnd = section.indexOf('\n', targetsIndex);
  if (targetsLineEnd < 0) {
    return source;
  }
  final insertAt = sectionStart + targetsLineEnd + 1;
  return source.replaceRange(insertAt, insertAt, '\t\t\t\t$_uiTestsTargetId /* RunnerUITests */,\n');
}

String _ensureRunnerUiTestsCodeSigning(
  String source, {
  required bool disableCodeSigning,
}) {
  return source.replaceAllMapped(
    RegExp(
      r'\t\t[0-9A-F]{24} /\* (Debug|Release|Profile) \*/ = \{'
      r'[\s\S]*?\n\t\t\};',
    ),
    (match) {
      var config = match.group(0)!;
      if (!config.contains('INFOPLIST_FILE = RunnerUITests/Info.plist;')) {
        return config;
      }
      config = config.replaceAll(
        RegExp(
          '\n\\s+(CODE_SIGNING_ALLOWED|CODE_SIGNING_REQUIRED|'
          'CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|'
          'PROVISIONING_PROFILE_SPECIFIER) = [^;]+;',
        ),
        '',
      );
      return _withUiTestsCodeSigning(config, disableCodeSigning);
    },
  );
}

Map<String, String> _uiTestsCodeSigningSettings(bool disableCodeSigning) => {
      'CODE_SIGNING_ALLOWED': disableCodeSigning ? 'NO' : 'YES',
      'CODE_SIGNING_REQUIRED': disableCodeSigning ? 'NO' : 'YES',
      'CODE_SIGN_IDENTITY': '"Apple Development"',
      'CODE_SIGN_STYLE': 'Automatic',
      if (!disableCodeSigning && IosCodesign.teamId.isNotEmpty) 'DEVELOPMENT_TEAM': IosCodesign.teamId,
      'PROVISIONING_PROFILE_SPECIFIER': '""',
    };

String _withUiTestsCodeSigning(String config, bool disableCodeSigning) {
  var updated = config;
  for (final MapEntry(:key, :value) in _uiTestsCodeSigningSettings(disableCodeSigning).entries) {
    updated = upsertSortedPbxBuildSetting(updated, key, value);
  }
  return updated;
}

final _topLevelBuildSetting = RegExp(
  r'^\t\t\t\t(?:"([^"]+)"|([A-Za-z0-9_]+)) = ',
  multiLine: true,
);

/// Sets `key = value;` in [config] (one XCBuildConfiguration block), placing a
/// new key where CocoaPods' serializer would (keys sorted). `pod install`
/// rewrites the project with sorted keys, and Flutter re-runs `pod install`
/// whenever the project bytes change, so an out-of-order key makes every build
/// re-run it and recompile every pod.
String upsertSortedPbxBuildSetting(String config, String key, String value) {
  final existing = RegExp('\n\t\t\t\t${RegExp.escape(key)} = [^;]+;');
  if (existing.hasMatch(config)) {
    return config.replaceFirst(existing, '\n\t\t\t\t$key = $value;');
  }
  final line = '\t\t\t\t$key = $value;\n';
  final settingsEnd = config.indexOf('\n\t\t\t};');
  for (final match in _topLevelBuildSetting.allMatches(config)) {
    if (match.start > settingsEnd) {
      break;
    }
    final other = match.group(1) ?? match.group(2)!;
    if (other.compareTo(key) > 0) {
      return config.replaceRange(match.start, match.start, line);
    }
  }
  return config.replaceRange(settingsEnd + 1, settingsEnd + 1, line);
}

String _uiTestsBuildConfiguration(
  String id,
  String name, {
  required bool disableCodeSigning,
}) {
  final optimization = name == 'Debug' ? '\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";' : '';
  final validation = name == 'Debug' ? '' : '\t\t\t\tVALIDATE_PRODUCT = YES;\n';
  final onlyActiveArch = name == 'Debug' ? 'YES' : 'NO';
  return _withUiTestsCodeSigning(
      '\t\t$id /* $name */ = {\n'
      '\t\t\tisa = XCBuildConfiguration;\n'
      '\t\t\tbuildSettings = {\n'
      '\t\t\t\tCLANG_ENABLE_MODULES = YES;\n'
      '\t\t\t\tCLANG_ENABLE_OBJC_WEAK = NO;\n'
      '\t\t\t\t"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = i386;\n'
      '\t\t\t\tFRAMEWORK_SEARCH_PATHS = (\n'
      '\t\t\t\t\t"\$(inherited)",\n'
      '\t\t\t\t\t"\$(PLATFORM_DIR)/Developer/Library/Frameworks",\n'
      '\t\t\t\t);\n'
      '\t\t\t\tINFOPLIST_FILE = RunnerUITests/Info.plist;\n'
      '\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;\n'
      '\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
      '\t\t\t\t\t"\$(inherited)",\n'
      '\t\t\t\t\t"@executable_path/Frameworks",\n'
      '\t\t\t\t\t"@loader_path/Frameworks",\n'
      '\t\t\t\t);\n'
      '\t\t\t\tLIBRARY_SEARCH_PATHS = (\n'
      '\t\t\t\t\t"\$(inherited)",\n'
      '\t\t\t\t\t"\$(PLATFORM_DIR)/Developer/usr/lib",\n'
      '\t\t\t\t);\n'
      '\t\t\t\tONLY_ACTIVE_ARCH = $onlyActiveArch;\n'
      '\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.mobile.runner.uitests;\n'
      '\t\t\t\tPRODUCT_NAME = RunnerUITests;\n'
      '\t\t\t\tSDKROOT = iphoneos;\n'
      '\t\t\t\tSKIP_INSTALL = YES;$optimization\n'
      '\t\t\t\tSWIFT_VERSION = 5.0;\n'
      '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
      '\t\t\t\tTEST_TARGET_NAME = Runner;\n'
      '$validation'
      '\t\t\t};\n'
      '\t\t\tname = $name;\n'
      '\t\t};\n',
      disableCodeSigning);
}

void _ensureRunnerUiTestsScheme(String repo) {
  final schemeFile = File(p.join(repo, _xcodeSchemeRelativePath));
  if (!schemeFile.existsSync()) {
    return;
  }
  var source = schemeFile.readAsStringSync();
  if (source.contains('BlueprintName = "RunnerUITests"')) {
    return;
  }
  const testable = '''
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "$_uiTestsTargetId"
               BuildableName = "RunnerUITests.xctest"
               BlueprintName = "RunnerUITests"
               ReferencedContainer = "container:Runner.xcodeproj">
            </BuildableReference>
         </TestableReference>
''';
  source = source.replaceFirst('<Testables>\n', '<Testables>\n$testable');
  schemeFile.writeAsStringSync(source);
}

// `isa = PBXGroup;` disambiguates from the RunnerUITests PBXNativeTarget
// block, whose header is otherwise identical — without it, a project whose
// group was pruned matches the target here and the repair silently no-ops.
final _runnerUiTestsGroupPattern = RegExp(r'[0-9A-F]{24} /\* RunnerUITests \*/ = \{\s+isa = PBXGroup;[\s\S]*?\n\s+\};');

final _runnerUiTestsSourcesPhasePattern = RegExp(
  '$_uiTestsSourcesPhaseId /\\* Sources \\*/ = \\{[\\s\\S]*?\\n\\s+\\};',
);

const _uiTestsInfoPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>\$(DEVELOPMENT_LANGUAGE)</string>
\t<key>CFBundleExecutable</key>
\t<string>\$(EXECUTABLE_NAME)</string>
\t<key>CFBundleIdentifier</key>
\t<string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>\$(PRODUCT_NAME)</string>
\t<key>CFBundlePackageType</key>
\t<string>BNDL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>1.0</string>
\t<key>CFBundleVersion</key>
\t<string>1</string>
</dict>
</plist>
''';

const _placeholderSwiftRunner = '''import XCTest

class LoginE2ETests: XCTestCase {
  func testPlaceholder() {
    XCTAssertTrue(true)
  }
}
''';

String _render(List<_IosTest> tests, String bundleId, String selectionCoordinatorUrl) {
  final syntheticShardMethods = selectionCoordinatorUrl.isEmpty
      ? ''
      : List.generate(
          tests.length,
          (index) => '  func ${iosCoordinatorShardMethod(index, tests.length)}() throws {\n'
              '    try runAssignedCoordinatorShard()\n'
              '  }',
        ).join('\n\n');
  String method(_IosTest test) => '  func ${test.method}() throws {\n'
      '    guard PatrolBridge.shouldRun("${test.method}") else { return }\n'
      '    if let failure = PatrolBridge.selectionFailureMessage() { '
      'XCTFail(failure); return }\n'
      '    let result = PatrolBridge.run("${_escapeSwift(test.description)}", '
      'group: "${_escapeSwift(test.group)}")\n'
      '    if result.result == .skipped { throw XCTSkip(result.message) }\n'
      '    if result.result == .failure { XCTFail(result.message) }\n'
      '  }';
  final methods = tests.map(method).join('\n\n');
  final suiteMethods = tests.map((test) => '      "${test.method}",').join('\n');
  final dispatchCases = tests.map((test) => '      case "${test.method}": try ${test.method}()').join('\n');
  final selectionMap = tests
      .expand(
        (test) => [
          (selector: test.method, method: test.method),
          (selector: '$_swiftClassName/${test.method}', method: test.method),
          (selector: _taskName(test.description), method: test.method),
        ],
      )
      .map((entry) => '    "${_escapeSwift(entry.selector)}": "${entry.method}",')
      .join('\n');
  final allKnownMethods = tests.map((test) => '    "${_escapeSwift(test.method)}",').join('\n');
  return '''// GENERATED by `mplatrol` — do not edit by hand. Regenerated to match
// $defaultPatrolTestDirectory/*_test.dart on every `mplatrol` run, so the app
// gitignores it. See ios_patrol_runner.dart for why this is SWIFT, named
// LoginE2ETests (not RunnerUITests), with non-final camelCase methods, and why
// the Patrol state lives in PatrolBridge — all required by LambdaTest's iOS
// HyperExecute test discovery.
import Foundation
import XCTest
import patrol
// Swift Package Manager builds Patrol's Swift types (RunDartTestResponseResult,
// DartGroupEntry, ...) as a separate PatrolImpl module that the patrol module
// does not re-export; CocoaPods builds one patrol module.
#if canImport(PatrolImpl)
import PatrolImpl
// patrol's ObjC headers also declare PatrolServer; the server is PatrolImpl's.
typealias MplatrolPatrolServer = PatrolImpl.PatrolServer
#else
typealias MplatrolPatrolServer = PatrolServer
#endif

// XCTest launch/alert calls can block the test thread and its RunLoop timeout.
// This independent deadline deliberately fails the process if that thread stalls.
final class PatrolPhaseDeadline {
  private let lock = NSLock()
  private let timer = DispatchSource.makeTimerSource(
    queue: DispatchQueue(label: "patrol.phase-deadline")
  )
  private let timeout: TimeInterval
  private var phase: String
  private var finished = false

  init(phase: String, timeout: TimeInterval) {
    self.phase = phase
    self.timeout = timeout
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in self?.expire() }
    timer.resume()
    enter(phase)
  }

  func enter(_ phase: String) {
    lock.lock()
    self.phase = phase
    lock.unlock()
    NSLog("%@", "PATROL_PHASE phase=\\(phase) deadlineSeconds=\\(timeout) "
      + "testPort=8081 appPort=8082")
  }

  func finish() {
    lock.lock()
    finished = true
    lock.unlock()
    timer.cancel()
  }

  private func expire() {
    lock.lock()
    if finished { lock.unlock(); return }
    let message = "PATROL_PHASE_TIMEOUT phase=\\(phase) deadlineSeconds=\\(timeout). "
      + "Runner stopped: inspect XCTest/device logs for launch or permission stalls; "
      + "for app-service waits check 127.0.0.1:8082 and Patrol server port 8081. "
      + "Coordinator traffic uses the cloud tunnel, not these device-local ports."
    lock.unlock()
    NSLog("%@", message)
    fatalError(message)
  }
}

final class PatrolDirectClient {
  private let session: URLSession
  private let baseURL: URL

  init(port: Int = 8082) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 180
    config.timeoutIntervalForResource = 180
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.connectionProxyDictionary = [
      "HTTPEnable": 0,
      "HTTPSEnable": 0,
      "SOCKSEnable": 0,
      "ProxyAutoConfigEnable": 0,
    ]
    session = URLSession(configuration: config)
    baseURL = URL(string: "http://127.0.0.1:\\(port)")!
    NSLog("%@", "PATROL_DIRECT_CLIENT_READY: no-proxy 127.0.0.1:\\(port)")
  }

  func listDartTests(
    timeout: TimeInterval = 180,
    completion: @escaping ([String]?, Error?) -> Void
  ) {
    request(
      "listDartTests",
      responseType: ListDartTestsResponse.self,
      timeout: timeout
    ) { result in
      switch result {
      case .success(let response):
        completion(self.flattenedTests(in: response.group, parent: ""), nil)
      case .failure(let error):
        completion(nil, error)
      }
    }
  }

  func runDartTest(
    name: String,
    completion: @escaping (RunDartTestResponseResult?, String?, Error?) -> Void
  ) {
    let body = try? JSONSerialization.data(withJSONObject: ["name": name])
    // The caller already confirmed listDartTests contains the requested test.
    request("runDartTest", body: body, responseType: RunDartTestResponse.self) { result in
      switch result {
      case .success(let response):
        completion(response.result, response.details, nil)
      case .failure(let error):
        completion(nil, nil, error)
      }
    }
  }

  private func request<T: Decodable>(
    _ path: String,
    body: Data? = nil,
    responseType: T.Type,
    timeout: TimeInterval = 180,
    completion: @escaping (Result<T, Error>) -> Void
  ) {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = timeout
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    session.dataTask(with: request) { data, rawResponse, error in
      if let error = error {
        completion(.failure(error))
        return
      }
      guard let http = rawResponse as? HTTPURLResponse,
            http.statusCode == 200,
            let data = data else {
        let message = "Invalid response from \\(path): \\(String(describing: rawResponse))"
        completion(.failure(NSError(
          domain: "PatrolDirectClient",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: message]
        )))
        return
      }
      do {
        completion(.success(try JSONDecoder().decode(T.self, from: data)))
      } catch {
        completion(.failure(error))
      }
    }.resume()
  }

  private func flattenedTests(in entry: DartGroupEntry, parent: String) -> [String] {
    var tests: [String] = []
    for child in entry.entries {
      if child.type == .test {
        if !parent.isEmpty {
          tests.append("\\(parent) \\(child.name)")
        }
      } else if child.type == .group {
        let nextParent = parent.isEmpty ? child.name : "\\(parent) \\(child.name)"
        tests.append(contentsOf: flattenedTests(in: child, parent: nextParent))
      }
    }
    return tests
  }
}

// All Patrol state + logic lives here (NOT on the XCTestCase) so the test class's
// Swift field metadata stays free of cross-module Patrol types.
enum PatrolBridge {
  // The app under test, launched by bundle id (LambdaTest's .xctestrun carries
  // no UITargetAppPath, so a bare XCUIApplication() can't locate it).
  static let targetBundleId = "${_escapeSwift(bundleId)}"
  static let selectionCoordinatorUrl = "${_escapeSwift(selectionCoordinatorUrl)}"
  static var server: MplatrolPatrolServer?
  static var client: PatrolDirectClient?
  static var dartTests: [String] = []
  static var setupFailure: String?
  static var selectionFailure: String?
  static var coordinatorSelectedMethod: String?
  static var didQueryCoordinator = false
  // True when LambdaTest spawned more sessions than there are shards and the
  // coordinator told this (extra) session it has no shard to run. Such a
  // session must run an EMPTY suite and pass — not error, not run the full
  // suite — so an over-provisioned session can't show up as a failed test.
  static var coordinatorNoShard = false
  static var didSetup = false
  static var didLogSelectionContext = false
  static let selectionDebugLogging =
      ProcessInfo.processInfo.environment["MPLATROL_LOG_SELECTION"] != "0"
  static let runnerSessionDefaultsKey = "mplatrol.patrol.runnerSessionId"
  // Bounded wait for the shard coordinator before the shard is NOT RUN.
  static let coordinatorWindowSeconds: TimeInterval = $iosCoordinatorWindowSeconds

  static let selectionMap: [String: String] = [
$selectionMap
  ]
  static let allKnownMethods: Set<String> = [
$allKnownMethods
  ]

  static func appUnderTest() -> XCUIApplication {
    targetBundleId.isEmpty ? XCUIApplication() : XCUIApplication(bundleIdentifier: targetBundleId)
  }

  // The run's test order from mplatrol (`--seed`/`--order`): xcodebuild passes
  // TEST_RUNNER_$testOrderEnv to this process as $testOrderEnv, a comma-separated
  // method list. Methods it does not name keep their declared order after it.
  static func orderedMethods(_ declared: [String]) -> [String] {
    let raw = ProcessInfo.processInfo.environment["$testOrderEnv"] ?? ""
    let requested = raw.split(separator: ",").map(String.init).filter { declared.contains(\$0) }
    if requested.isEmpty { return declared }
    NSLog("%@", "PATROL_TEST_ORDER \\(requested.joined(separator: ","))")
    return requested + declared.filter { !requested.contains(\$0) }
  }

  static func shouldRun(_ method: String) -> Bool {
    logSelectionContext()
    guard let selected = selectedMethod() else { return true }
    if selected == method { return true }
    NSLog("%@", "PATROL_SKIP method=\\(method) selected=\\(selected)")
    return false
  }

  static func selectionFailureMessage() -> String? {
    selectionFailure
  }

  static func selectedMethodForDefaultSuite() -> String? {
    guard let method = selectedMethod() else { return nil }
    NSLog("%@", "PATROL_DEFAULT_SUITE method=\\(method)")
    return method
  }

  // An over-provisioned session (LambdaTest started more sessions than shards)
  // has no shard; it should run nothing and pass.
  static func isExtraSessionWithoutShard() -> Bool {
    coordinatorNoShard
  }

  private static func selectedMethod() -> String? {
    for argument in ProcessInfo.processInfo.arguments {
      if let method = selectedMethod(in: argument) {
        NSLog("%@", "PATROL_SELECTION_SOURCE source=argument method=\\(method)")
        return method
      }
    }

    let environment = ProcessInfo.processInfo.environment
    for key in environment.keys.sorted() {
      guard let value = environment[key] else { continue }
      if let method = selectedMethod(in: value) {
        NSLog("%@", "PATROL_SELECTION_SOURCE source=env:\\(key) method=\\(method)")
        return method
      }
    }

    if let path = xctestConfigurationPath(),
       let data = FileManager.default.contents(atPath: path),
       let plist = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
       ),
       let method = selectedMethod(inAny: plist) {
      NSLog("%@", "PATROL_SELECTION_SOURCE source=xctestConfiguration method=\\(method)")
      return method
    }

    if let method = selectedMethodFromCoordinator() {
      return method
    }

    return nil
  }

  private static func selectedMethodFromCoordinator() -> String? {
    if selectionCoordinatorUrl.isEmpty { return nil }
    if didQueryCoordinator { return coordinatorSelectedMethod }
    didQueryCoordinator = true
    guard let url = coordinatorAssignmentUrl() else {
      selectionFailure = "iOS shard coordinator URL is invalid: \\(selectionCoordinatorUrl)"
      return nil
    }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 30
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let urlSession = URLSession(configuration: config)

    // The coordinator is the mplatrol host process reached over the LambdaTest
    // tunnel; it is up for the whole run and assigns each installed runner a
    // single method idempotently. A miss here is a transient network/timing
    // blip at session start, NOT a real assignment failure — a single
    // non-retried request is exactly what made one session XCTFail in ~2s and
    // what dropped other sessions back to the full (multi-test) suite. Retry
    // with backoff; the idempotent runnerSession returns the same assignment.
    // The first shard can start before the tunnel forwards the coordinator
    // port (NSURLErrorDomain -1004 for ~20s), so retry for a bounded window
    // rather than a fixed attempt count.
    let windowSeconds = coordinatorWindowSeconds
    let started = Date()
    var lastFailure = "no method assigned"
    var attempt = 0
    var backoff = 1.0
    while true {
      attempt += 1
      var selected: String?
      var failure: String?
      var noShard = false
      let semaphore = DispatchSemaphore(value: 0)
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.timeoutInterval = 30
      urlSession.dataTask(with: request) { data, rawResponse, error in
        defer { semaphore.signal() }
        if let error = error {
          failure = "request failed: \\(error)"
          return
        }
        guard let http = rawResponse as? HTTPURLResponse else {
          failure = "no HTTP response"
          return
        }
        // 409 = every shard is already assigned, i.e. LambdaTest spawned more
        // sessions than shards. This session has no test to run; it is not an
        // error and retrying cannot change it.
        if http.statusCode == 409 {
          noShard = true
          return
        }
        guard http.statusCode == 200 else {
          let body = data.flatMap { String(data: \$0, encoding: .utf8) } ?? ""
          failure = "HTTP \\(http.statusCode): \\(body)"
          return
        }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              allKnownMethods.contains(method) else {
          failure = "no known method in response"
          return
        }
        selected = method
      }.resume()

      if semaphore.wait(timeout: .now() + 35) == .timedOut {
        failure = "request timed out"
      }
      if noShard {
        coordinatorNoShard = true
        NSLog("%@", "PATROL_SELECTION_NO_SHARD extra session (all shards assigned)")
        return nil
      }
      if let method = selected {
        coordinatorSelectedMethod = method
        NSLog("%@", "PATROL_SELECTION_SOURCE source=coordinator method=\\(method) attempt=\\(attempt)")
        return method
      }
      lastFailure = failure ?? lastFailure
      let elapsed = Date().timeIntervalSince(started)
      if elapsed + backoff > windowSeconds { break }
      NSLog("%@", "PATROL_SELECTION_COORDINATOR_RETRY attempt=\\(attempt) "
        + "elapsed=\\(Int(elapsed))s window=\\(Int(windowSeconds))s \\(redact(lastFailure))")
      Thread.sleep(forTimeInterval: backoff)
      backoff = min(backoff * 2, 10)
    }
    let elapsed = Int(Date().timeIntervalSince(started))
    selectionFailure = "PATROL_SHARD_NOT_RUN iOS shard coordinator unreachable after \\(attempt) attempt(s) "
      + "over \\(elapsed)s (window \\(Int(windowSeconds))s): \\(lastFailure). This shard never received a "
      + "test; NOT RUN (infrastructure: the device could not reach the mplatrol coordinator through the "
      + "LambdaTest tunnel), not a test result."
    NSLog("%@", "PATROL_SELECTION_COORDINATOR_FAILED attempts=\\(attempt) elapsed=\\(elapsed)s "
      + "window=\\(Int(windowSeconds))s \\(redact(lastFailure))")
    return nil
  }

  private static func coordinatorAssignmentUrl() -> URL? {
    guard var components = URLComponents(string: selectionCoordinatorUrl) else {
      return nil
    }
    var queryItems = components.queryItems ?? []
    let environment = ProcessInfo.processInfo.environment
    queryItems.append(URLQueryItem(name: "xctestSession", value: environment["XCTestSessionIdentifier"] ?? ""))
    queryItems.append(URLQueryItem(name: "runnerSession", value: runnerSessionId()))
    queryItems.append(URLQueryItem(name: "pid", value: String(ProcessInfo.processInfo.processIdentifier)))
    components.queryItems = queryItems
    return components.url
  }

  private static func runnerSessionId() -> String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: runnerSessionDefaultsKey),
       !existing.isEmpty {
      return existing
    }
    let created = UUID().uuidString
    defaults.set(created, forKey: runnerSessionDefaultsKey)
    defaults.synchronize()
    return created
  }

  private static func selectedMethod(inAny value: Any) -> String? {
    if let string = value as? String {
      return selectedMethod(in: string)
    }
    if let array = value as? [Any] {
      let matches = Set(array.compactMap { selectedMethod(inAny: \$0) })
      return selectedMethod(fromMatches: matches)
    }
    if let dictionary = value as? [AnyHashable: Any] {
      let matches = Set(dictionary.flatMap { key, value in
        [selectedMethod(in: String(describing: key)), selectedMethod(inAny: value)]
            .compactMap { \$0 }
      })
      return selectedMethod(fromMatches: matches)
    }
    return nil
  }

  private static func selectedMethod(in raw: String) -> String? {
    let matches = Set(selectionMap.compactMap { selector, method in
      raw.contains(selector) ? method : nil
    })
    if let method = selectedMethod(fromMatches: matches) {
      return method
    }
    return nil
  }

  private static func selectedMethod(fromMatches matches: Set<String>) -> String? {
    if matches.count == 1 { return matches.first }
    if allKnownMethods.count > 1 && matches.count == allKnownMethods.count - 1 {
      let remaining = allKnownMethods.subtracting(matches)
      if remaining.count == 1, let method = remaining.first {
        NSLog("%@", "PATROL_SELECTION_INFERRED_FROM_SKIP skipped=\\(Array(matches).sorted()) method=\\(method)")
        return method
      }
    }
    if matches.count > 1 && selectionDebugLogging {
      NSLog("%@", "PATROL_SELECTION_AMBIGUOUS matches=\\(Array(matches).sorted())")
    }
    return nil
  }

  private static func xctestConfigurationPath() -> String? {
    let args = ProcessInfo.processInfo.arguments
    for index in 0..<max(args.count - 1, 0) {
      if args[index] == "-XCTestConfigurationFilePath" {
        return args[index + 1]
      }
    }
    return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
  }

  private static func logSelectionContext() {
    if !selectionDebugLogging { return }
    if didLogSelectionContext { return }
    didLogSelectionContext = true
    let args = ProcessInfo.processInfo.arguments
        .map { redact(\$0) }
        .joined(separator: " | ")
    NSLog("%@", "PATROL_SELECTION_ARGS \\(args)")

    let environment = ProcessInfo.processInfo.environment
    let interesting = ["HYPER", "LAMBDA", "LT_", "XCTest", "XCODE", "TEST", "SHARD", "TASK", "JOB"]
    for key in environment.keys.sorted() {
      guard interesting.contains(where: { key.localizedCaseInsensitiveContains(\$0) }),
            let value = environment[key] else { continue }
      NSLog("%@", "PATROL_SELECTION_ENV key=\\(key) value=\\(redact(value, key: key))")
    }
    if let path = xctestConfigurationPath() {
      NSLog("%@", "PATROL_SELECTION_XCTEST_CONFIG path=\\(redact(path))")
      logXctestConfigurationContext(path: path)
    }
  }

  private static func logXctestConfigurationContext(path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
          ) else { return }
    logXctestConfigurationEntries(value: plist, path: [])
  }

  private static func logXctestConfigurationEntries(value: Any, path: [String]) {
    if let string = value as? String {
      let joinedPath = path.joined(separator: ".")
      if isSelectionContextInteresting(joinedPath) || isSelectionContextInteresting(string) {
        NSLog(
          "%@",
          "PATROL_SELECTION_XCTEST_CONFIG_ENTRY key=\\(redact(joinedPath)) value=\\(redact(string, key: joinedPath))"
        )
      }
      return
    }
    if let array = value as? [Any] {
      for (index, item) in array.enumerated() {
        logXctestConfigurationEntries(value: item, path: path + ["[\\(index)]"])
      }
      return
    }
    if let dictionary = value as? [AnyHashable: Any] {
      for key in dictionary.keys.sorted(by: { String(describing: \$0) < String(describing: \$1) }) {
        guard let item = dictionary[key] else { continue }
        logXctestConfigurationEntries(value: item, path: path + [String(describing: key)])
      }
    }
  }

  private static func isSelectionContextInteresting(_ value: String) -> Bool {
    let upper = value.uppercased()
    let tokens = [
      "HYPER", "LAMBDA", "LT_", "XCTEST", "XCODE", "TEST", "SHARD", "TASK", "JOB", "SESSION", "IDENTIFIER",
      "NAME", "ONLY", "SKIP",
    ]
    return tokens.contains { upper.contains(\$0) }
  }

  private static func redact(_ value: String, key: String = "") -> String {
    let upperKey = key.uppercased()
    let secretKeys = ["KEY", "TOKEN", "SECRET", "PASS", "PASSWORD", "AUTH", "USER", "EMAIL"]
    if secretKeys.contains(where: { upperKey.contains(\$0) }) {
      return "<redacted>"
    }
    var result = value
    if let regex = try? NSRegularExpression(pattern: #"(?i)(key|token|secret|password|pass)=([^\\s|]+)"#) {
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..<result.endIndex, in: result),
        withTemplatrole: "\$1=<redacted>"
      )
    }
    if let regex = try? NSRegularExpression(pattern: #"LT_[A-Za-z0-9]{12,}"#) {
      result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..<result.endIndex, in: result),
        withTemplatrole: "<redacted>"
      )
    }
    if result.count > 240 {
      return String(result.prefix(240)) + "...<truncated>"
    }
    return result
  }

  static func resetLocalNetworkPermission() {
    if #available(iOS 15.4, *) {
      appUnderTest().resetAuthorizationStatus(for: .localNetwork)
    }
  }

  private static func localNetworkPermissionPredicate() -> NSPredicate {
    NSPredicate(
      format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
      "would like to find and connect to devices on your local network",
      "to find devices on local networks?"
    )
  }

  private static func tapLocalNetworkAlertIfPresent() {
    let prompt = localNetworkPermissionPredicate()
    for bundleId in ["com.apple.springboard", targetBundleId] where !bundleId.isEmpty {
      let application = XCUIApplication(bundleIdentifier: bundleId)
      for containers in [application.alerts, application.sheets] {
        let button = containers.containing(prompt).buttons.matching(identifier: "Allow").firstMatch
        if button.exists && button.isHittable { button.tap(); return }
      }
    }
  }

  // Start Patrol's server + client, answer the one-time Local Network alert, and
  // wait until the Dart app service can list tests. LambdaTest launches the
  // xctest WITHOUT the ports, so pin them before PatrolServer reads them.
  static func ensureSetup() {
    if didSetup { return }
    didSetup = true
    let deadline = PatrolPhaseDeadline(phase: "setup.server-start", timeout: 180)
    defer { deadline.finish() }
    setenv("PATROL_TEST_PORT", "8081", 1)
    setenv("PATROL_APP_PORT", "8082", 1)
    let srv = MplatrolPatrolServer()
    server = srv
    do {
      try srv.start()
      NSLog("%@", "PATROL_SERVER_START_OK: listening on 8081")
    } catch {
      setupFailure = "PATROL_SERVER_START_FAILED port=8081: \\(error). "
        + "Check port ownership and PATROL_ENABLED before retrying."
      NSLog("%@", setupFailure!)
      return
    }
    client = PatrolDirectClient()

    deadline.enter("setup.local-network-reset")
    resetLocalNetworkPermission()
    let launchedApp = appUnderTest()
    deadline.enter("setup.terminate")
    launchedApp.terminate()
    deadline.enter("setup.launch")
    launchedApp.launch()
    guard let client = client else {
      setupFailure = "Patrol direct client was not initialized."
      return
    }
    let listedResult = waitForDartTests(
      client: client,
      expectedName: nil,
      maxAttempts: 30,
      requestTimeout: 5,
      logPrefix: "PATROL_LISTDARTTESTS_WAIT",
      deadline: deadline,
      beforeAttempt: tapLocalNetworkAlertIfPresent
    )
    let listed = listedResult.tests
    guard let listed = listed else {
      setupFailure = "Patrol app service never listed its Dart tests. Last: "
        + "\\(listedResult.failure)"
      NSLog("%@", "PATROL_DARTTESTS_TIMEOUT \\(listedResult.failure)")
      return
    }
    dartTests = listed
    NSLog("%@", "PATROL_SETUP_OK: \\(dartTests.count) Dart test(s) listed")
  }

  private static func waitForDartTests(
    client: PatrolDirectClient,
    expectedName: String?,
    maxAttempts: Int,
    requestTimeout: TimeInterval,
    logPrefix: String,
    deadline: PatrolPhaseDeadline,
    beforeAttempt: (() -> Void)? = nil
  ) -> (tests: [String]?, failure: String) {
    var lastListFailure = "not attempted"
    var hasConnected = false
    for attempt in 1...maxAttempts {
      if !hasConnected {
        deadline.enter(logPrefix + ".local-network-alert")
        beforeAttempt?()
      }
      deadline.enter(logPrefix + ".listDartTests")
      var requestCompleted = false
      var attemptTests: [String]?
      var attemptError: Error?
      client.listDartTests(timeout: requestTimeout) { tests, err in
        attemptTests = tests
        attemptError = err
        requestCompleted = true
      }
      var requestWaited = 0
      let waitLimit = max(2, Int(requestTimeout.rounded(.up)) + 1)
      while !requestCompleted && requestWaited < waitLimit {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        requestWaited += 1
      }
      if let tests = attemptTests {
        hasConnected = true
        if let expectedName = expectedName, !tests.contains(expectedName) {
          lastListFailure = "listed \\(tests.count) test(s), missing \\(expectedName)"
        } else {
          return (tests, "")
        }
      } else if let err = attemptError {
        lastListFailure = "\\(err)"
      } else {
        lastListFailure = "timed out waiting for listDartTests response"
      }
      if attempt == 1 || attempt == maxAttempts || attempt % 5 == 0 {
        NSLog("%@", "\\(logPrefix) attempt=\\(attempt)/\\(maxAttempts) "
          + "\\(lastListFailure)")
      }
    }
    return (nil, lastListFailure)
  }

  // Resolve the full Dart test name for [group] + [description] from the listed
  // tests, launch a fresh app, run it, and report the result.
  static func run(_ description: String, group: String)
    -> (result: RunDartTestResponseResult, message: String) {
    ensureSetup()
    if let failure = setupFailure { return (.failure, failure) }
    // Every iOS build compiles a bundle grouping each selected file under its
    // basename, so the name must START with [group]. A name nested under
    // another group (Android's mplatrol_filtered_test wrapper) means iOS compiled
    // a bundle it did not select.
    let prefix = group + " "
    let suffix = " " + description
    let matches = dartTests.filter { \$0.hasPrefix(prefix) && \$0.hasSuffix(suffix) }
    guard matches.count == 1, let name = matches.first else {
      return (.failure, "Expected exactly 1 Dart test in group '\\(group)' ending "
        + "with '\\(description)', found \\(matches.count) — regenerate the runner "
        + "(mplatrol). Listed: \\(dartTests)")
    }
    // Patrol's Dart-side app service accepts one runDartTest request per app
    // process. Terminate + relaunch before each native method so every XCTest
    // method gets a fresh Dart service and runs exactly one Patrol test. Retry
    // only on infrastructure evidence (the app never became ready, the
    // connection to it was lost, the WebView could not load); assertion/auth
    // failures and a Dart test that started and then timed out (a hang the
    // next attempt repeats) return immediately.
    guard let client = client else {
      return (.failure, "Patrol direct client was not initialized.")
    }
    var lastDetails = "(no details - app likely crashed)"
    for attempt in 1...4 {
      NSLog("%@", "PATROL_RUN name=\\(name) attempt=\\(attempt)")
      let readinessDeadline = PatrolPhaseDeadline(phase: "run.terminate", timeout: 60)
      defer { readinessDeadline.finish() }
      let app = appUnderTest()
      app.terminate()
      readinessDeadline.enter("run.launch")
      app.launch()
      readinessDeadline.enter("run.local-network-alert")
      tapLocalNetworkAlertIfPresent()
      let ready = waitForDartTests(
        client: client,
        expectedName: name,
        maxAttempts: 20,
        requestTimeout: 2,
        logPrefix: "PATROL_RUN_LISTDARTTESTS_WAIT",
        deadline: readinessDeadline,
        beforeAttempt: tapLocalNetworkAlertIfPresent
      )
      readinessDeadline.finish()
      if ready.tests == nil {
        lastDetails = "patrol_appready_timeout: fresh app service did not "
          + "list requested Dart test after relaunch. Last: \\(ready.failure)"
        NSLog("%@", "PATROL_RESULT name=\\(name) attempt=\\(attempt) "
          + "passed=false details=\\(lastDetails)")
        continue
      }
      NSLog("%@", "PATROL_RUN_READY name=\\(name) attempt=\\(attempt)")
      // Outlasts the wait loop below, so a slow Dart test fails on its own
      // and the runner moves on instead of stopping the whole process.
      let executionDeadline = PatrolPhaseDeadline(
        phase: "run.runDartTest",
        timeout: ${iosRunDartTestTimeoutSeconds + iosRunDartTestDeadlineGraceSeconds})
      defer { executionDeadline.finish() }
      var executionResult: RunDartTestResponseResult?
      var details: String?
      var error: Error?
      client.runDartTest(name: name) { result, message, err in
        if let err = err {
          error = err
        } else {
          executionResult = result
          details = message
        }
      }
      var runWaited = 0
      while executionResult == nil && error == nil {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        runWaited += 1
        if runWaited >= $iosRunDartTestTimeoutSeconds {
          error = NSError(
            domain: "PatrolDirectClient",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for runDartTest response."]
          )
          break
        }
      }
      let attemptPassed = executionResult == .success
      let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if attemptPassed && trimmedDetails.isEmpty {
        lastDetails = "Dart test completed successfully"
      } else {
        lastDetails = trimmedDetails.isEmpty
          ? error.map { "Patrol direct client error: \\(\$0)" } ?? "(no details - app likely crashed)"
          : trimmedDetails
      }
      NSLog("%@", "PATROL_RESULT name=\\(name) attempt=\\(attempt) passed=\\(attemptPassed) details=\\(lastDetails)")
      if executionResult == .skipped { return (.skipped, lastDetails) }
      if attemptPassed { return (.success, "") }
      if isDartTestTimeout(error) {
        NSLog("%@", "PATROL_RUN_NO_RETRY name=\\(name) attempt=\\(attempt) reason=dart_test_timeout "
          + "(the app was ready and the Dart test started, so a retry repeats the hang)")
        break
      }
      if !shouldRetry(details: lastDetails) { break }
    }
    return (.failure, "Patrol Dart test failed; see PATROL_RESULT. Last: \\(lastDetails)")
  }

  private static func shouldRetry(details: String) -> Bool {
    let lower = details.lowercased()
    let infrastructureSignals = [
      "errpage:",
      "net::",
      "chrome-error",
      "main-frame-error",
      "patrol_appready_timeout",
      "patrol_darttests_timeout",
      "listdarttests",
      "connection refused",
      "could not connect",
      "network connection was lost",
    ]
    return infrastructureSignals.contains { lower.contains(\$0) }
  }

  /// The runDartTest request outlived its timeout after the app listed the
  /// test: URLSession's request timeout or the runner's own wait.
  private static func isDartTestTimeout(_ error: Error?) -> Bool {
    guard let error = error as NSError? else { return false }
    return (error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut)
      || (error.domain == "PatrolDirectClient" && error.code == 2)
  }
}

// One camelCase test method per Patrol test. NOT
// `final` and named LoginE2ETests — both required by LambdaTest's iOS discovery.
class $_swiftClassName: XCTestCase {

  override class var defaultTestSuite: XCTestSuite {
    if let method = PatrolBridge.selectedMethodForDefaultSuite() {
      let suite = XCTestSuite(name: NSStringFromClass(self))
      suite.addTest($_swiftClassName(selector: NSSelectorFromString(method)))
      return suite
    }
    // No assigned method. If LambdaTest over-provisioned (more sessions than
    // shards), this extra session has no shard — run an EMPTY suite so it
    // passes cleanly rather than failing or running every test (which made one
    // session show as a failure and put all five tests in one session video).
    // A genuine coordinator failure still falls through to the full suite so
    // the selection-failure surfaces loudly instead of passing silently.
    if PatrolBridge.isExtraSessionWithoutShard() {
      NSLog("%@", "PATROL_NO_SHARD_SUITE empty suite for extra session")
      return XCTestSuite(name: NSStringFromClass(self))
    }
    return fullTestSuite()
  }

  private class func fullTestSuite() -> XCTestSuite {
    let suite = XCTestSuite(name: NSStringFromClass(self))
    let declared = [
$suiteMethods
    ]
    for method in PatrolBridge.orderedMethods(declared) {
      suite.addTest($_swiftClassName(selector: NSSelectorFromString(method)))
    }
    return suite
  }

$methods
${syntheticShardMethods.isEmpty ? '' : '\n\n$syntheticShardMethods\n'}
  private func runAssignedCoordinatorShard() throws {
    guard let method = PatrolBridge.selectedMethodForDefaultSuite() else {
      if PatrolBridge.isExtraSessionWithoutShard() { return }
      if let failure = PatrolBridge.selectionFailureMessage() {
        XCTFail(failure)
        return
      }
      XCTFail("iOS shard coordinator did not assign a method.")
      return
    }
    do {
      switch method {
$dispatchCases
      default:
        XCTFail("iOS shard coordinator assigned unknown method \\(method).")
      }
    } catch let skip as XCTSkip {
      // HyperExecute ios/xcui never finishes a task whose only test is
      // skipped: the device session ends but the task stays "running" until
      // the job is aborted, losing every other shard's result. Report the
      // runtime skip as a labelled non-pass so the task completes.
      let reason = skip.message ?? "no skip reason"
      NSLog("%@", "MPLATROL_TEST_SKIPPED coordinator shard method=\\(method) NOT RUN: \\(reason)")
      XCTFail("MPLATROL_TEST_SKIPPED \\(method) skipped at runtime (\\(reason)); NOT RUN, not a pass. "
        + "Reported as a failure because HyperExecute never completes a skipped-only task.")
    }
  }

}
''';
}

/// Escapes [value] for a Swift double-quoted string literal.
String _escapeSwift(String value) => value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
