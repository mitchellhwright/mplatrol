import 'dart:io';

import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/patrol_skip_detection.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _localNetworkHarness = r'''
import Foundation
class NativeQuery {
  let elements: [NativeElement]
  init(_ elements: [NativeElement]) { self.elements = elements }
  var allElementsBoundByIndex: [NativeElement] { elements }
  var firstMatch: NativeElement { elements.first ?? NativeElement(exists: false) }
  func containing(_ predicate: NSPredicate) -> NativeQuery {
    NativeQuery(elements.filter { element in
      element.exists && element.texts.contains { predicate.evaluate(with: ["label": $0]) }
    })
  }
  var buttons: NativeButtons {
    NativeButtons(elements.filter { !$0.vanishesBeforeButtons }.reduce(into: [:]) {
      $0.merge($1.actions) { first, _ in first }
    })
  }
}
class NativeButtons {
  let elements: [String: NativeElement]
  init(_ elements: [String: NativeElement]) { self.elements = elements }
  subscript(label: String) -> NativeElement {
    elements[label] ?? NativeElement(label: label, exists: false)
  }
  func matching(identifier: String) -> NativeQuery {
    NativeQuery(elements[identifier].map { [$0] } ?? [])
  }
}
class NativeElement {
  let text: String
  var label: String {
    precondition(!staleLabel, "No matches found for Element at index 2: stale snapshot")
    return text
  }
  let exists: Bool
  let hittable: Bool
  var isHittable: Bool { exists && hittable }
  var taps = 0
  var staleTextEnumeration = false
  var vanishesBeforeButtons = false
  var staleLabel = false
  let texts: [String]
  let actions: [String: NativeElement]
  init(label: String = "", exists: Bool = true, hittable: Bool = true, texts: [String] = [],
       actions: [String: NativeElement] = [:]) {
    self.text = label; self.exists = exists; self.hittable = hittable
    self.texts = texts; self.actions = actions
  }
  var staticTexts: NativeQuery {
    var elements = texts.map { NativeElement(label: $0) }
    if staleTextEnumeration {
      let stale = NativeElement(exists: false)
      stale.staleLabel = true
      elements.append(stale)
    }
    return NativeQuery(elements)
  }
  var buttons: NativeButtons { NativeButtons(actions) }
  func tap() { taps += 1 }
}
class XCUIApplication {
  static var alertsByBundle: [String: [NativeElement]] = [:]
  static var sheetsByBundle: [String: [NativeElement]] = [:]
  let bundleIdentifier: String
  init(bundleIdentifier: String) { self.bundleIdentifier = bundleIdentifier }
  var alerts: NativeQuery { NativeQuery(Self.alertsByBundle[bundleIdentifier] ?? []) }
  var sheets: NativeQuery { NativeQuery(Self.sheetsByBundle[bundleIdentifier] ?? []) }
}
enum Bridge {
  static let targetBundleId = "example.app"
// GENERATED_HELPERS
  static func assist() { tapLocalNetworkAlertIfPresent() }
}
let allowOnce = NativeElement(label: "Allow Once")
let genericAllow = NativeElement(label: "Allow")
let location = NativeElement(texts: [
  "Example App Would Like to Use Your Location",
  "Location improves nearby services on your local network."
], actions: ["Allow Once": allowOnce, "Allow": genericAllow])
XCUIApplication.alertsByBundle = ["com.apple.springboard": [location]]
Bridge.assist()
precondition(allowOnce.taps == 0 && genericAllow.taps == 0, "location was handled")
let networkAllow = NativeElement(label: "Allow")
let network = NativeElement(texts: [
  "Example App Would Like to Find and Connect to Devices on Your Local Network",
  "This app discovers and connects to devices on the networks you use."
], actions: ["Allow": networkAllow])
network.staleTextEnumeration = true
XCUIApplication.alertsByBundle["example.app"] = [network]
Bridge.assist()
precondition(networkAllow.taps == 1, "app-hosted Local Network was not handled")
XCUIApplication.alertsByBundle = ["com.apple.springboard": [network]]
Bridge.assist()
precondition(networkAllow.taps == 2, "SpringBoard Local Network was not handled")
XCUIApplication.alertsByBundle = [:]
Bridge.assist()
precondition(networkAllow.taps == 2, "absent alert caused a tap")
let missingAllow = NativeElement(texts: network.texts, actions: ["Allow Once": allowOnce])
XCUIApplication.alertsByBundle = ["com.apple.springboard": [missingAllow]]
Bridge.assist()
precondition(allowOnce.taps == 0, "generic Allow Once fallback was used")
let modernAllow = NativeElement(label: "Allow")
let modern = NativeElement(texts: [
  "Allow Example App to find devices on local networks?",
  "Allow Flutter tools on your computer to connect and debug your application."
], actions: ["Allow": modernAllow])
XCUIApplication.alertsByBundle = [:]
XCUIApplication.sheetsByBundle = ["com.apple.springboard": [modern]]
Bridge.assist()
precondition(modernAllow.taps == 1, "iOS 26 Local Network sheet was not handled")
modern.vanishesBeforeButtons = true
Bridge.assist()
precondition(modernAllow.taps == 1, "disappeared sheet was tapped")
let hiddenAllow = NativeElement(label: "Allow", hittable: false)
let hidden = NativeElement(texts: network.texts, actions: ["Allow": hiddenAllow])
XCUIApplication.sheetsByBundle = [:]
XCUIApplication.alertsByBundle = ["com.apple.springboard": [hidden]]
Bridge.assist()
precondition(hiddenAllow.taps == 0, "non-hittable Allow was tapped")
print("LOCAL_NETWORK_REGRESSION: passed")
''';

void main() {
  late Directory repo;

  String runnerPath() => p.join(repo.path, 'ios', 'RunnerUITests', 'RunnerUITests.swift');

  setUp(() {
    repo = Directory.systemTemp.createTempSync('ios_gen');
    Directory(p.join(repo.path, 'patrol_test')).createSync();
    Directory(p.join(repo.path, 'integration_test')).createSync();
  });

  tearDown(() => repo.deleteSync(recursive: true));

  void writeTest(String name, String body) => File(p.join(repo.path, 'patrol_test', name)).writeAsStringSync(body);

  group('Flutter Swift Package Manager project', () {
    // the app main (fea6fde9): plugins come from FlutterGeneratedPluginSwiftPackage, linked into Runner only.
    late File project;

    setUp(() {
      project = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
        ..createSync(recursive: true)
        ..writeAsStringSync(File('test/fixtures/ios_spm/project.pbxproj').readAsStringSync());
    });

    String uiTestsTarget(String source) => RegExp(
          r'[0-9A-F]{24} /\* RunnerUITests \*/ = \{\s+isa = PBXNativeTarget;.*?\n\t\t\};',
          dotAll: true,
        ).firstMatch(source)!.group(0)!;

    // Regression 2026-10-14: RunnerUITests.swift failed with "Unable to find module dependency: 'patrol'".
    test('links the generated plugin package into RunnerUITests so it can import patrol', () {
      ensureIosPatrolProject(repo.path, bundleId: 'com.example.app');
      final source = project.readAsStringSync();

      final target = uiTestsTarget(source);
      final productRef =
          RegExp(r'packageProductDependencies = \(\s+([0-9A-F]{24}) /\* FlutterGeneratedPluginSwiftPackage \*/')
              .firstMatch(target)!
              .group(1)!;
      final frameworksPhase = RegExp(r'([0-9A-F]{24}) /\* Frameworks \*/,').firstMatch(target)!.group(1)!;
      final buildFile = RegExp('([0-9A-F]{24}) /\\* FlutterGeneratedPluginSwiftPackage in Frameworks \\*/ = '
              '\\{isa = PBXBuildFile; productRef = $productRef ')
          .firstMatch(source)!
          .group(1)!;
      expect(
          RegExp('$frameworksPhase /\\* Frameworks \\*/ = \\{[^}]*$buildFile /\\* FlutterGeneratedPluginSwiftPackage')
              .hasMatch(source),
          isTrue,
          reason: "the build file must be in RunnerUITests' own Frameworks phase");
      expect(
          source,
          contains(
              '$productRef /* FlutterGeneratedPluginSwiftPackage */ = {\n\t\t\tisa = XCSwiftPackageProductDependency;'));
    });

    test('adds the package dependency once', () {
      ensureIosPatrolProject(repo.path, bundleId: 'com.example.app');
      final first = project.readAsStringSync();
      ensureIosPatrolProject(repo.path, bundleId: 'com.example.app');

      expect(project.readAsStringSync(), first);
      expect('packageProductDependencies'.allMatches(uiTestsTarget(first)).length, 1);
    });
  });

  test('leaves a CocoaPods project without a Swift package dependency', () {
    final project = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(File('test/fixtures/ios_spm/project.pbxproj')
          .readAsStringSync()
          .replaceAll('productName = FlutterGeneratedPluginSwiftPackage;', 'productName = SomeOtherPackage;'));

    ensureIosPatrolProject(repo.path, bundleId: 'com.example.app');

    expect(
        project.readAsStringSync(),
        isNot(
            contains('FlutterGeneratedPluginSwiftPackage in Frameworks */ = {isa = PBXBuildFile; productRef = 4F1C')));
  });

  test('throws when there are no patrol tests', () {
    writeTest('empty_test.dart', 'void main() {}');
    expect(() => generateIosPatrolRunner(repo.path), throwsStateError);
  });

  test('generates a Swift Patrol bridge + discoverable LoginE2ETests class', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing'); patrolTest('another thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    final count = generateIosPatrolRunner(repo.path);

    expect(count, 3);
    final source = File(runnerPath()).readAsStringSync();
    // PatrolBridge holds server/handshake/runDartTest state so the XCTestCase
    // metadata stays simple enough for LambdaTest HyperExecute discovery.
    expect(source, contains('enum PatrolBridge'));
    expect(source, contains('static func ensureSetup()'));
    expect(source, contains('class LoginE2ETests: XCTestCase'));

    // Every test is a camelCase method on LoginE2ETests; the dart file is the
    // group arg used to resolve the full Patrol Dart test at runtime.
    expect(source, contains('func testAHappyPath() throws {'));
    expect(source, contains('func testBAThing() throws {'));
    expect(source, contains('guard PatrolBridge.shouldRun("testBAThing")'));
    expect(source, contains('selectionFailureMessage()'));
    expect(source, contains('selectedMethodForDefaultSuite()'));
    expect(source, contains('override class var defaultTestSuite: XCTestSuite'));
    expect(source, contains('PATROL_DEFAULT_SUITE method=\\(method)'));
    expect(source, contains('NSSelectorFromString(method)'));
    expect(source, contains('return fullTestSuite()'));
    expect(source, contains('private class func fullTestSuite() -> XCTestSuite'));
    expect(
        source,
        contains('    let declared = [\n      "testAHappyPath",\n      "testBAThing",\n'
            '      "testBAnotherThing",\n    ]\n'));
    expect(
        source,
        contains('for method in PatrolBridge.orderedMethods(declared) {\n'
            '      suite.addTest(LoginE2ETests(selector: NSSelectorFromString(method)))'));
    // The seeded order arrives at runtime, so a new seed never changes the build.
    expect(source, contains('ProcessInfo.processInfo.environment["$testOrderEnv"]'));
    expect(source, contains('return requested + declared.filter { !requested.contains(\$0) }'));
    expect(source, contains('selectedMethodFromCoordinator()'));
    expect(source, contains('PATROL_SELECTION_COORDINATOR_FAILED'));
    expect(source, contains('"a_thing": "testBAThing"'));
    expect(source, contains('PatrolBridge.run("a thing", group: "login_faults_test")'));
    expect(source, contains('PatrolBridge.run("happy path", group: "patrol_login_test")'));
    expect(source.indexOf('func testAHappyPath()'), lessThan(source.indexOf('func testBAThing()')));
    expect(source, contains('app.terminate()'));
    expect(source, contains('waitForDartTests('));
    expect(source, contains('private static func tapLocalNetworkAlertIfPresent()'));
    expect(source, isNot(contains('XCTExpectFailure')));
    expect(source, isNot(contains('expectingNativeQueryMisses')));
    expect(source, contains('if result.result == .skipped { throw XCTSkip(result.message) }'));
    expect(source, contains('if result.result == .failure { XCTFail(result.message) }'));
    expect('beforeAttempt: tapLocalNetworkAlertIfPresent'.allMatches(source), hasLength(2));
    expect(
      source,
      contains('''
      while executionResult == nil && error == nil {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
'''),
    );
    expect(source, contains('PATROL_RUN_READY name=\\(name)'));
    expect(source, contains('PATROL_RUN_LISTDARTTESTS_WAIT'));
    expect(source, contains('client.runDartTest(name: name)'));
    expect(source, contains('if !shouldRetry(details: lastDetails) { break }'));
    expect(source, contains('private static func shouldRetry(details: String)'));
    expect(source, contains('if isDartTestTimeout(error) {'));
    expect(source, contains('PATROL_RUN_NO_RETRY name=\\(name) attempt=\\(attempt) reason=dart_test_timeout'));
    expect(source, isNot(contains('"timed out waiting for rundarttest",')),
        reason: 'a started Dart test that timed out is a hang, not infrastructure');
    expect(source, isNot(contains('"patrol direct client error",')));
    expect(source, isNot(contains('while !srv.appReady')));
    expect(source, contains('PATROL_LISTDARTTESTS_WAIT'));
    expect(source, contains('PATROL_SELECTION_XCTEST_CONFIG_ENTRY'));
    expect(source, contains('"USER", "EMAIL"'));

    // No shard-specific XCTestCase classes: the HyperExecute coordinator
    // selects the single method each session should run.
    expect(source, isNot(contains('class LTShard')));
  });

  test('local network assistance ends at connection before Dart execution', () {
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");
    generateIosPatrolRunner(repo.path);

    final source = File(runnerPath()).readAsStringSync();
    expect(source, contains('if !hasConnected {'));
    expect(source, contains('beforeAttempt?()'));
    expect(source, contains('deadline.enter(logPrefix + ".local-network-alert")'));
    expect(source, contains('if let tests = attemptTests {\n        hasConnected = true'));
    final runStart = source.indexOf('client.runDartTest(name: name)');
    final runEnd = source.indexOf('private static func shouldRetry', runStart);
    final runningDart = source.substring(runStart, runEnd);
    expect(runningDart, isNot(contains('tapLocalNetworkAlert')));
    expect(source, isNot(contains('XCTExpectFailure')));
    expect(source, contains('if result.result == .failure { XCTFail(result.message) }'));
  });

  test('generated helper survives stale alert snapshots and handles Local Network', () {
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");
    generateIosPatrolRunner(repo.path);
    final source = File(runnerPath()).readAsStringSync();
    final start = source.indexOf('  private static func', source.indexOf('static func resetLocalNetworkPermission'));
    final end = source.indexOf('  // Start Patrol', start);
    final helper = source.substring(start, end);
    final harness = File(p.join(repo.path, 'local_network_regression.swift'))
      ..writeAsStringSync(_localNetworkHarness.replaceFirst('// GENERATED_HELPERS', helper));
    final result = Process.runSync('swift', [
      '-module-cache-path',
      p.join(repo.path, 'swift-module-cache'),
      harness.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('LOCAL_NETWORK_REGRESSION: passed'));
  }, testOn: 'mac-os');

  _registerBootstrapDeadlineTests(writeTest, runnerPath);

  test('embeds an iOS HyperExecute shard coordinator URL when supplied', () {
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateIosPatrolRunner(repo.path, selectionCoordinatorUrl: 'http://localhost.lambdatest.com:12345/assign?run=abc');

    final source = File(runnerPath()).readAsStringSync();
    expect(
      source,
      contains(
        'static let selectionCoordinatorUrl = '
        '"http://localhost.lambdatest.com:12345/assign?run=abc"',
      ),
    );
    expect(
      source,
      contains(
        'URLQueryItem(name: "xctestSession", '
        'value: environment["XCTestSessionIdentifier"] ?? "")',
      ),
    );
    expect(
      source,
      contains(
        'URLQueryItem(name: "runnerSession", '
        'value: runnerSessionId())',
      ),
    );
    expect(source, contains('source=coordinator'));
    expect(source, contains('func testShard01() throws {'));
    expect(source, contains('runAssignedCoordinatorShard()'));
    expect(source, contains('case "testAHappyPath": try testAHappyPath()'));
    expect(source, contains('iOS shard coordinator did not assign a method.'));
    // HyperExecute ios/xcui leaves a task "running" forever when its only test
    // is skipped (jobs 0bbd0937, db1a87e1: every skipped session's task hung),
    // so a coordinator shard reports a runtime skip as a labelled XCTFail.
    expect(source, contains('} catch let skip as XCTSkip {'));
    expect(source, contains('let reason = skip.message ?? "no skip reason"'));
    expect(source, contains(r'XCTFail("MPLATROL_TEST_SKIPPED \(method) skipped at runtime'));
    expect(source, contains(r'"MPLATROL_TEST_SKIPPED coordinator shard method=\(method) NOT RUN: \(reason)"'));
    expect(
      patrolSkipSummary('MPLATROL_TEST_SKIPPED coordinator shard method=testAHappyPath NOT RUN: '
              'Dart test skipped at runtime')
          .hasSkippedTests,
      isTrue,
      reason: 'the CLI must still count the converted skip as a skip, not a test failure',
    );
    // The coordinator query retries with capped exponential backoff for a
    // bounded window (12 x 1.5s = ~18s was shorter than the tunnel needs to
    // forward the coordinator port to the first shard: NSURLErrorDomain -1004).
    expect(iosCoordinatorWindowSeconds, 120);
    expect(source, contains('static let coordinatorWindowSeconds: TimeInterval = 120'));
    expect(source, isNot(contains('maxAttempts = 12')));
    expect(source, contains('if elapsed + backoff > windowSeconds { break }'));
    expect(source, contains('backoff = min(backoff * 2, 10)'));
    expect(source, contains('PATROL_SELECTION_COORDINATOR_RETRY'));
    // A shard that never reached the coordinator says it never ran a test.
    expect(source, contains('PATROL_SHARD_NOT_RUN iOS shard coordinator unreachable'));
    expect(source, contains('NOT RUN (infrastructure'));
    // A 409 (LambdaTest spawned more sessions than shards) is handled as an
    // extra session with no shard: empty suite + pass, not a 409 -> XCTFail and
    // not the full multi-test suite.
    expect(source, contains('if http.statusCode == 409'));
    expect(source, contains('coordinatorNoShard = true'));
    expect(source, contains('isExtraSessionWithoutShard()'));
    expect(source, contains('PATROL_NO_SHARD_SUITE'));
    // PROJ-250836: under Swift Package Manager Patrol's Swift types live in PatrolImpl, and patrol's ObjC headers
    // also declare PatrolServer, so the runner imports PatrolImpl when it exists and names its server explicitly.
    expect(source, contains('#if canImport(PatrolImpl)\nimport PatrolImpl\n'));
    expect(
        source,
        contains(
            'typealias MplatrolPatrolServer = PatrolImpl.PatrolServer\n#else\ntypealias MplatrolPatrolServer = PatrolServer\n#endif'));
    expect(source, contains('static var server: MplatrolPatrolServer?'));
    expect(source, contains('let srv = MplatrolPatrolServer()'));
    expect(source, isNot(contains(': PatrolServer?')));
  });

  test('creates and wires the generated Swift runner into the Xcode test target', () {
    final projectFile = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(r'''
// !$*UTF8*$!
{
  objects = {
/* Begin PBXBuildFile section */
/* End PBXBuildFile section */
/* Begin PBXContainerItemProxy section */
/* End PBXContainerItemProxy section */
/* Begin PBXFileReference section */
    97C146EE1CF9000F007C117D /* Runner.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Runner.app; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */
/* Begin PBXFrameworksBuildPhase section */
    97C146EB1CF9000F007C117D /* Frameworks */ = {
      isa = PBXFrameworksBuildPhase;
      files = (
      );
    };
/* End PBXFrameworksBuildPhase section */
/* Begin PBXGroup section */
    97C146E51CF9000F007C117D = {
      isa = PBXGroup;
      children = (
        97C146F01CF9000F007C117D /* Runner */,
        97C146EF1CF9000F007C117D /* Products */,
      );
      sourceTree = "<group>";
    };
    97C146EF1CF9000F007C117D /* Products */ = {
      isa = PBXGroup;
      children = (
        97C146EE1CF9000F007C117D /* Runner.app */,
      );
      name = Products;
      sourceTree = "<group>";
    };
    97C146F01CF9000F007C117D /* Runner */ = {
      isa = PBXGroup;
      children = (
      );
      path = Runner;
      sourceTree = "<group>";
    };
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
    97C146ED1CF9000F007C117D /* Runner */ = {
      isa = PBXNativeTarget;
      buildConfigurationList = 97C147051CF9000F007C117D /* Build configuration list for PBXNativeTarget "Runner" */;
      buildPhases = (
        97C146EA1CF9000F007C117D /* Sources */,
        97C146EB1CF9000F007C117D /* Frameworks */,
        97C146EC1CF9000F007C117D /* Resources */,
      );
      dependencies = (
      );
      name = Runner;
      productName = Runner;
      productReference = 97C146EE1CF9000F007C117D /* Runner.app */;
      productType = "com.apple.product-type.application";
    };
/* End PBXNativeTarget section */
/* Begin PBXProject section */
    97C146E61CF9000F007C117D /* Project object */ = {
      isa = PBXProject;
      buildConfigurationList = 97C146E91CF9000F007C117D /* Build configuration list for PBXProject "Runner" */;
      mainGroup = 97C146E51CF9000F007C117D;
      productRefGroup = 97C146EF1CF9000F007C117D /* Products */;
      targets = (
        97C146ED1CF9000F007C117D /* Runner */,
      );
    };
/* End PBXProject section */
/* Begin PBXResourcesBuildPhase section */
    97C146EC1CF9000F007C117D /* Resources */ = {
      isa = PBXResourcesBuildPhase;
      files = (
      );
    };
/* End PBXResourcesBuildPhase section */
/* Begin PBXSourcesBuildPhase section */
    97C146EA1CF9000F007C117D /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
      );
    };
/* End PBXSourcesBuildPhase section */
/* Begin PBXTargetDependency section */
/* End PBXTargetDependency section */
/* Begin XCBuildConfiguration section */
    97C147061CF9000F007C117D /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app;}; name = Debug; };
    97C147071CF9000F007C117D /* Release */ = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app;}; name = Release; };
    249021D4217E4FDB00AE95B9 /* Profile */ = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app;}; name = Profile; };
    97C147031CF9000F007C117D /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
    97C147041CF9000F007C117D /* Release */ = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };
    249021D3217E4FDB00AE95B9 /* Profile */ = {isa = XCBuildConfiguration; buildSettings = {}; name = Profile; };
/* End XCBuildConfiguration section */
/* Begin XCConfigurationList section */
    97C147051CF9000F007C117D /* Build configuration list for PBXNativeTarget "Runner" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        97C147061CF9000F007C117D /* Debug */,
        97C147071CF9000F007C117D /* Release */,
        249021D4217E4FDB00AE95B9 /* Profile */,
      );
    };
    97C146E91CF9000F007C117D /* Build configuration list for PBXProject "Runner" */ = {
      isa = XCConfigurationList;
      buildConfigurations = (
        97C147031CF9000F007C117D /* Debug */,
        97C147041CF9000F007C117D /* Release */,
        249021D3217E4FDB00AE95B9 /* Profile */,
      );
    };
/* End XCConfigurationList section */
  };
  rootObject = 97C146E61CF9000F007C117D /* Project object */;
}
''');
    final schemeFile =
        File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'xcshareddata', 'xcschemes', 'Runner.xcscheme'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1510" version = "1.3">
   <TestAction buildConfiguration = "Debug">
      <Testables>
      </Testables>
   </TestAction>
</Scheme>
''');
    final podfile = File(p.join(repo.path, 'ios', 'Podfile'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
target 'Runner' do
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
''');
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateIosPatrolRunner(repo.path, bundleId: 'com.example.app');

    final source = projectFile.readAsStringSync();
    expect(source, contains('productType = "com.apple.product-type.bundle.ui-testing";'));
    expect(
      source,
      contains(
        'RunnerUITests.swift */ = '
        '{isa = PBXFileReference;',
      ),
    );
    expect(
      source,
      contains(
        'RunnerUITests.swift in Sources */ = '
        '{isa = PBXBuildFile;',
      ),
    );
    expect(source, contains('RunnerUITests.swift */,'));
    expect(source, contains('RunnerUITests.swift in Sources */,'));
    // The RunnerUITests group must be a child of the (comment-less) Flutter
    // mainGroup. An unattached group is unreachable from the root object, so
    // the next `pod install` reserialization prunes it — orphaning the Swift
    // file ref, whose "<group>"-relative path then resolves to the project
    // root and the test build fails with a missing source file.
    expect(
      source,
      matches(
        RegExp(
          r'97C146E51CF9000F007C117D = \{[^{}]*children = \([^)]*'
          r'/\* RunnerUITests \*/,',
        ),
      ),
    );
    expect(source, contains('PRODUCT_BUNDLE_IDENTIFIER = com.example.app.uitests;'));
    expect(source, contains('ONLY_ACTIVE_ARCH = YES;'));
    expect(source, isNot(contains('RunnerUITests.m in Sources */,')));
    expect(source, isNot(contains(r'$1')));
    expect(schemeFile.readAsStringSync(), contains('BlueprintName = "RunnerUITests"'));
    expect(podfile.readAsStringSync(), contains("target 'RunnerUITests' do"));
    expect(File(p.join(repo.path, 'ios', 'RunnerUITests', 'Info.plist')).existsSync(), isTrue);
  });

  test('repairs Swift membership in an existing RunnerUITests target', () {
    final projectFile = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(r'''
// !$*UTF8*$!
{
  objects = {
/* Begin PBXBuildFile section */
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
/* End PBXFileReference section */
/* Begin PBXGroup section */
    111111111111111111111111 /* RunnerUITests */ = {
      isa = PBXGroup;
      children = (
        222222222222222222222222 /* Info.plist */,
      );
      path = RunnerUITests;
      sourceTree = "<group>";
    };
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
    08693F719B49CEB16EFFFD06 /* RunnerUITests */ = {
      isa = PBXNativeTarget;
      productType = "com.apple.product-type.bundle.ui-testing";
    };
/* End PBXNativeTarget section */
/* Begin PBXProject section */
    333333333333333333333333 /* Project object */ = {
      isa = PBXProject;
      attributes = {
        TargetAttributes = {
          444444444444444444444444 = {
            CreatedOnToolsVersion = 7.3.1;
          };
        };
      };
      targets = (
        444444444444444444444444 /* Runner */,
      );
    };
/* End PBXProject section */
/* Begin PBXSourcesBuildPhase section */
    DAE17DAA9EDB4BD781A8B8EB /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
      );
    };
/* End PBXSourcesBuildPhase section */
  };
}
''');
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateIosPatrolRunner(repo.path);

    final source = projectFile.readAsStringSync();
    expect(
      source,
      contains(
        'RunnerUITests.swift */ = '
        '{isa = PBXFileReference;',
      ),
    );
    expect(
      source,
      contains(
        'RunnerUITests.swift in Sources */ = '
        '{isa = PBXBuildFile;',
      ),
    );
    expect(source, contains('08693F719B49CEB16EFFFD06 /* RunnerUITests */,'));
    expect(source, contains('RunnerUITests.swift */,'));
    expect(source, contains('RunnerUITests.swift in Sources */,'));
  });

  test('keeps RunnerUITests build settings in pod install key order', () {
    // `pod install` rewrites the project with sorted buildSettings keys, and
    // Flutter re-runs `pod install` (recompiling every pod) whenever the
    // project bytes change. Re-applying code signing must therefore leave a
    // pod-installed configuration byte-identical.
    const podInstalledConfig = '\t\t555555555555555555555555 /* Profile */ = {\n'
        '\t\t\tisa = XCBuildConfiguration;\n'
        '\t\t\tbuildSettings = {\n'
        '\t\t\t\tCLANG_ENABLE_MODULES = YES;\n'
        '\t\t\t\tCLANG_ENABLE_OBJC_WEAK = NO;\n'
        '\t\t\t\tCODE_SIGNING_ALLOWED = NO;\n'
        '\t\t\t\tCODE_SIGNING_REQUIRED = NO;\n'
        '\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";\n'
        '\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
        '\t\t\t\t"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = i386;\n'
        '\t\t\t\tINFOPLIST_FILE = RunnerUITests/Info.plist;\n'
        '\t\t\t\tPRODUCT_NAME = RunnerUITests;\n'
        '\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "";\n'
        '\t\t\t\tSDKROOT = iphoneos;\n'
        '\t\t\t};\n'
        '\t\t\tname = Profile;\n'
        '\t\t};\n';
    final projectFile = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
// !\$*UTF8*\$!
{
  objects = {
/* Begin PBXBuildFile section */
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
/* End PBXFileReference section */
/* Begin PBXGroup section */
    111111111111111111111111 /* RunnerUITests */ = {
      isa = PBXGroup;
      children = (
      );
      path = RunnerUITests;
      sourceTree = "<group>";
    };
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
    08693F719B49CEB16EFFFD06 /* RunnerUITests */ = {
      isa = PBXNativeTarget;
      productType = "com.apple.product-type.bundle.ui-testing";
    };
/* End PBXNativeTarget section */
/* Begin PBXProject section */
    333333333333333333333333 /* Project object */ = {
      isa = PBXProject;
      targets = (
        08693F719B49CEB16EFFFD06 /* RunnerUITests */,
      );
    };
/* End PBXProject section */
/* Begin PBXSourcesBuildPhase section */
    DAE17DAA9EDB4BD781A8B8EB /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
      );
    };
/* End PBXSourcesBuildPhase section */
/* Begin XCBuildConfiguration section */
$podInstalledConfig/* End XCBuildConfiguration section */
  };
}
''');
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateIosPatrolRunner(repo.path);

    expect(projectFile.readAsStringSync(), contains(podInstalledConfig));
  });

  test('does not embed the gitignored creds file in the Runner bundle', () {
    final projectFile = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(r'''
// !$*UTF8*$!
{
  objects = {
/* Begin PBXBuildFile section */
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
/* End PBXFileReference section */
/* Begin PBXGroup section */
    97C146E51CF9000F007C117D = {
      isa = PBXGroup;
      children = (
      );
      sourceTree = "<group>";
    };
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
    97C146ED1CF9000F007C117D /* Runner */ = {
      isa = PBXNativeTarget;
      buildPhases = (
        97C146EA1CF9000F007C117D /* Sources */,
        97C146EC1CF9000F007C117D /* Resources */,
      );
      name = Runner;
      productType = "com.apple.product-type.application";
    };
    08693F719B49CEB16EFFFD06 /* RunnerUITests */ = {
      isa = PBXNativeTarget;
      buildPhases = (
        DAE17DAA9EDB4BD781A8B8EB /* Sources */,
      );
      name = RunnerUITests;
      productType = "com.apple.product-type.bundle.ui-testing";
    };
/* End PBXNativeTarget section */
/* Begin PBXProject section */
    97C146E61CF9000F007C117D /* Project object */ = {
      isa = PBXProject;
      mainGroup = 97C146E51CF9000F007C117D;
      targets = (
        97C146ED1CF9000F007C117D /* Runner */,
        08693F719B49CEB16EFFFD06 /* RunnerUITests */,
      );
    };
/* End PBXProject section */
/* Begin PBXResourcesBuildPhase section */
    97C146EC1CF9000F007C117D /* Resources */ = {
      isa = PBXResourcesBuildPhase;
      files = (
      );
    };
/* End PBXResourcesBuildPhase section */
/* Begin PBXSourcesBuildPhase section */
    97C146EA1CF9000F007C117D /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
      );
    };
    DAE17DAA9EDB4BD781A8B8EB /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
      );
    };
/* End PBXSourcesBuildPhase section */
  };
  rootObject = 97C146E61CF9000F007C117D /* Project object */;
}
''');
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");
    File(
      p.join(repo.path, 'integration_test', 'e2e_credentials.local.json'),
    ).writeAsStringSync('{"E2E_USERNAME": "u"}');

    generateIosPatrolRunner(repo.path);

    final source = projectFile.readAsStringSync();
    expect(source, isNot(contains('e2e_credentials.local.json')));
  });

  test('skips the creds bundle resource when the file is absent', () {
    final projectFile = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(r'''
// !$*UTF8*$!
{
  objects = {
/* Begin PBXBuildFile section */
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
/* End PBXFileReference section */
/* Begin PBXGroup section */
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
    08693F719B49CEB16EFFFD06 /* RunnerUITests */ = {
      isa = PBXNativeTarget;
      buildPhases = (
        DAE17DAA9EDB4BD781A8B8EB /* Sources */,
      );
      name = RunnerUITests;
      productType = "com.apple.product-type.bundle.ui-testing";
    };
/* End PBXNativeTarget section */
/* Begin PBXProject section */
    97C146E61CF9000F007C117D /* Project object */ = {
      isa = PBXProject;
      mainGroup = 97C146E51CF9000F007C117D;
      targets = (
        08693F719B49CEB16EFFFD06 /* RunnerUITests */,
      );
    };
/* End PBXProject section */
/* Begin PBXSourcesBuildPhase section */
    DAE17DAA9EDB4BD781A8B8EB /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
      );
    };
/* End PBXSourcesBuildPhase section */
  };
  rootObject = 97C146E61CF9000F007C117D /* Project object */;
}
''');
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateIosPatrolRunner(repo.path);

    expect(projectFile.readAsStringSync(), isNot(contains('e2e_credentials.local.json')));
  });

  test('recreates the RunnerUITests group after pod install pruned it', () {
    // `pod install` reserializes the user project and drops objects that are
    // unreachable from the root object. This fixture mirrors that state: the
    // Swift file ref survives (reachable via its PBXBuildFile) but the
    // RunnerUITests group is gone, so the "<group>"-relative ref resolves to
    // ios/RunnerUITests.swift, which does not exist, and xcodebuild fails.
    final projectFile = File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync(r'''
// !$*UTF8*$!
{
  objects = {
/* Begin PBXBuildFile section */
    3EDA5D41A9364C4D95867227 /* RunnerUITests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5201F4411EAF4858888561A7 /* RunnerUITests.swift */; };
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
    5201F4411EAF4858888561A7 /* RunnerUITests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = RunnerUITests.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */
/* Begin PBXGroup section */
    97C146E51CF9000F007C117D = {
      isa = PBXGroup;
      children = (
      );
      sourceTree = "<group>";
    };
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
    08693F719B49CEB16EFFFD06 /* RunnerUITests */ = {
      isa = PBXNativeTarget;
      buildPhases = (
        DAE17DAA9EDB4BD781A8B8EB /* Sources */,
      );
      name = RunnerUITests;
      productType = "com.apple.product-type.bundle.ui-testing";
    };
/* End PBXNativeTarget section */
/* Begin PBXProject section */
    97C146E61CF9000F007C117D /* Project object */ = {
      isa = PBXProject;
      mainGroup = 97C146E51CF9000F007C117D;
      targets = (
        08693F719B49CEB16EFFFD06 /* RunnerUITests */,
      );
    };
/* End PBXProject section */
/* Begin PBXSourcesBuildPhase section */
    DAE17DAA9EDB4BD781A8B8EB /* Sources */ = {
      isa = PBXSourcesBuildPhase;
      files = (
        3EDA5D41A9364C4D95867227 /* RunnerUITests.swift in Sources */,
      );
    };
/* End PBXSourcesBuildPhase section */
  };
  rootObject = 97C146E61CF9000F007C117D /* Project object */;
}
''');
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    generateIosPatrolRunner(repo.path);

    final source = projectFile.readAsStringSync();
    // The group is back, holds the surviving file ref, and carries the path
    // component that makes the ref resolve to ios/RunnerUITests/.
    expect(
      source,
      matches(
        RegExp(
          r'/\* RunnerUITests \*/ = \{\s+isa = PBXGroup;[^}]*'
          r'5201F4411EAF4858888561A7 /\* RunnerUITests\.swift \*/,[^}]*'
          'path = RunnerUITests;',
        ),
      ),
    );
    // And it is reachable again: attached to the comment-less mainGroup so
    // the next pod install reserialization keeps it.
    expect(
      source,
      matches(
        RegExp(
          r'97C146E51CF9000F007C117D = \{[^{}]*children = \([^)]*'
          r'/\* RunnerUITests \*/,',
        ),
      ),
    );
  });

  test('throws when a malformed Xcode project cannot be repaired', () {
    File(p.join(repo.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{
  objects = {
/* Begin PBXProject section */
/* End PBXProject section */
  };
}
''');

    expect(() => ensureIosPatrolProject(repo.path), throwsStateError);
  });

  test('onlyTest regenerates RunnerUITests with just that one test', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing'); patrolTest('another thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    // onlyTest is the generated XCTest method name (IosTestShard.method).
    final count = generateIosPatrolRunner(repo.path, onlyTest: 'testAHappyPath');

    expect(count, 1);
    final source = File(runnerPath()).readAsStringSync();
    expect(source, contains('func testAHappyPath() throws {'));
    expect(source, isNot(contains('func testBAThing() throws {')));
    expect(source, isNot(contains('func testBAnotherThing() throws {')));
  });

  test('target generates only that file', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    final count = generateIosPatrolRunner(repo.path, target: 'patrol_test/patrol_login_test.dart');

    expect(count, 1);
    final source = File(runnerPath()).readAsStringSync();
    expect(source, contains('func testAHappyPath() throws {'));
    expect(
      source,
      contains(
        'PatrolBridge.run("happy path", '
        'group: "patrol_login_test")',
      ),
    );
    expect(source, isNot(contains('func testBAThing() throws {')));
  });

  test('throws when onlyTest matches no test', () {
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    expect(() => generateIosPatrolRunner(repo.path, onlyTest: 'test_nope'), throwsStateError);
  });

  test('exposes one shard (method + description) per test', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    final shards = iosTestShards(repo.path);
    // .method is the generated XCTest method name (the onlyTest value);
    // .description is the human build name.
    expect(shards.map((s) => s.method), ['testAHappyPath', 'testBAThing']);
    expect(shards.map((s) => s.description), ['happy path', 'a thing']);
    expect(shards.map((s) => s.onlyTesting), ['LoginE2ETests/testAHappyPath', 'LoginE2ETests/testBAThing']);
    expect(shards.map((s) => s.taskName), ['happy_path', 'a_thing']);
    expect(iosCoordinatorShardOnlyTesting(0, shards.length), 'LoginE2ETests/testShard01');
    expect(iosCoordinatorShardOnlyTesting(1, shards.length), 'LoginE2ETests/testShard02');
  });

  test('target filters shards to one file', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    final shards = iosTestShards(repo.path, target: 'patrol_test/patrol_login_test.dart');

    expect(shards.map((s) => s.method), ['testAHappyPath']);
    expect(shards.map((s) => s.description), ['happy path']);
  });

  // Every iOS build now compiles a bundle grouping each selected file under its
  // basename, so a Dart name nested under Android's mplatrol_filtered_test wrapper
  // ("mplatrol_filtered_test videosdk_sdk_smoke_test VideoSdk one") means iOS compiled a
  // bundle it did not select; the resolver must reject it, not match it.
  test('generated Swift resolver only accepts names starting with the file group', () {
    writeTest('videosdk_sdk_smoke_test.dart', "patrolTest('VideoSdk one');");

    generateIosPatrolRunner(repo.path, sdk: 'videosdk');

    final source = File(runnerPath()).readAsStringSync();
    expect(source, contains('let prefix = group + " "'));
    expect(
      source,
      contains(r'dartTests.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }'),
    );
    expect(source, isNot(contains('groupToken')));
    expect(source, isNot(contains(r'$0.contains(')));
    expect(source, contains('run("VideoSdk one", group: "videosdk_sdk_smoke_test")'));
  });

  test('sdk filters shards to every selected Patrol test method', () {
    writeTest('tenant_sdk_matrix_smoke_test.dart', "patrolTest('tenant one'); patrolTest('tenant two');");
    writeTest('videosdk_sdk_smoke_test.dart', "patrolTest('VideoSdk one');");

    final shards = iosTestShards(repo.path, sdk: 'tenant');

    expect(shards.map((s) => s.description), ['tenant one', 'tenant two']);
    expect(shards.map((s) => s.onlyTesting), ['LoginE2ETests/testBTenantOne', 'LoginE2ETests/testBTenantTwo']);
  });

  test('uniquifies shard method names across files', () {
    writeTest('a_test.dart', "patrolTest('dup');");
    writeTest('b_test.dart', "patrolTest('dup');");

    expect(iosTestShards(repo.path).map((s) => s.method), ['testBDup', 'testBDup2']);
  });

  test('increments duplicate shard suffixes until the method name is unique', () {
    writeTest('a_test.dart', "patrolTest('dup');");
    writeTest('b_test.dart', "patrolTest('dup 2');");
    writeTest('c_test.dart', "patrolTest('dup');");

    expect(iosTestShards(repo.path).map((s) => s.method), ['testBDup', 'testBDup2', 'testBDup3']);
  });

  test('a shard method round-trips through onlyTest', () {
    writeTest('login_faults_test.dart', "patrolTest('a thing');");
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");

    // Every shard's .method must select exactly that test as onlyTest — the
    // contract _buildAllPerTest relies on (a mismatch would throw on build).
    for (final shard in iosTestShards(repo.path)) {
      expect(
        generateIosPatrolRunner(repo.path, onlyTest: shard.method),
        1,
        reason: 'onlyTest=${shard.method} should match exactly one test',
      );
    }
  });

  test('escapes quotes in a description for the Swift string literal', () {
    writeTest('q_test.dart', "patrolTest('say \"hi\"');");

    generateIosPatrolRunner(repo.path);

    expect(File(runnerPath()).readAsStringSync(), contains(r'PatrolBridge.run("say \"hi\"", group: "q_test")'));
  });

  test('includes targetRegex in the error message when no tests match', () {
    writeTest('login_test.dart', "patrolTest('login');");
    expect(
      () => generateIosPatrolRunner(repo.path, targetRegex: 'no_such_sdk'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('matching /no_such_sdk/'),
      )),
    );
  });

  test('includes sdk in the error message when no tests match', () {
    writeTest('login_test.dart', "patrolTest('login');");
    expect(
      () => generateIosPatrolRunner(repo.path, sdk: 'no_such_sdk'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('for SDK "no_such_sdk"'),
      )),
    );
  });

  test('iosCoordinatorShardMethod throws RangeError when index is out of range', () {
    expect(() => iosCoordinatorShardMethod(-1, 3), throwsRangeError);
    expect(() => iosCoordinatorShardMethod(3, 3), throwsRangeError);
  });
}

void _registerBootstrapDeadlineTests(
  void Function(String, String) writeTest,
  String Function() runnerPath,
) {
  String generatedSource() {
    writeTest('patrol_login_test.dart', "patrolTest('happy path');");
    generateIosPatrolRunner(File(runnerPath()).parent.parent.parent.path);
    return File(runnerPath()).readAsStringSync();
  }

  test('bootstrap bounds setup, readiness and execution without fixed dispatch delay', () {
    final source = generatedSource();
    expect(source, contains('phase: "setup.server-start", timeout: 180'));
    expect(source, contains('phase: "run.terminate", timeout: 60'));
    expect(source, contains('phase: "run.runDartTest",\n        timeout: 210)'));
    // The graceful wait ends first, so a slow test fails alone instead of the
    // hard deadline stopping the runner.
    expect(source, contains('if runWaited >= 180 {'));
    expect(
        iosRunDartTestTimeoutSeconds + iosRunDartTestDeadlineGraceSeconds, greaterThan(iosRunDartTestTimeoutSeconds));
    expect(source, contains('deadline.enter("setup.launch")'));
    expect(source, contains('readinessDeadline.enter("run.launch")'));
    expect(source, contains('deadline.enter(logPrefix + ".listDartTests")'));
    expect(source, contains('defer { deadline.finish() }'));
    expect(source, contains('defer { readinessDeadline.finish() }'));
    expect(source, contains('defer { executionDeadline.finish() }'));
    expect(source, isNot(contains('DispatchQueue.main.asyncAfter')));
    expect(source.indexOf('if ready.tests == nil'), lessThan(source.indexOf('client.runDartTest(name: name)')));
  });

  test('server start failure returns before app launch with interpolated diagnostics', () {
    final source = generatedSource();
    final start = source.indexOf('try srv.start()');
    final end = source.indexOf('client = PatrolDirectClient()', start);
    final startup = source.substring(start, end);
    expect(startup, contains('catch {'));
    expect(startup, contains('setupFailure = "PATROL_SERVER_START_FAILED port=8081:'));
    expect(startup, contains('Check port ownership and PATROL_ENABLED before retrying.'));
    expect(startup, contains('return'));
    expect(startup, contains(r'\(error)'));
    expect(startup, isNot(contains(r'\\(error)')));
  });

  test('generated Swift deadline cancellation prevents termination', () {
    final result = _deadlineFixture(generatedSource(), 'finish', 'setup.launch');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('DEADLINE_CANCELLED'));
    expect(result.stderr, contains('PATROL_PHASE phase=setup.launch'));
  }, testOn: 'mac-os');

  for (final phase in ['setup.launch', 'run.launch', 'run.runDartTest']) {
    test('generated Swift deadline fails blocked $phase with actionable interpolation', () {
      final result = _deadlineFixture(generatedSource(), 'expire', phase);
      expect(result.exitCode, isNot(0), reason: '$phase must fail the blocked runner.');
      expect(result.exitCode, isNot(97), reason: 'Fixture safety deadline, not production expiry.');
      expect(result.stderr, contains('PATROL_PHASE_TIMEOUT phase=$phase'));
      expect(result.stderr, contains('deadlineSeconds=0.05'));
      expect(result.stderr, contains('127.0.0.1:8082'));
      expect(result.stderr, contains('Coordinator traffic uses the cloud tunnel'));
    }, testOn: 'mac-os');
  }
}

ProcessResult _deadlineFixture(String source, String mode, String phase) {
  final start = source.indexOf('final class PatrolPhaseDeadline');
  final end = source.indexOf('final class PatrolDirectClient', start);
  expect(start, greaterThanOrEqualTo(0));
  expect(end, greaterThan(start));
  final directory = Directory.systemTemp.createTempSync('patrol_deadline_fixture');
  addTearDown(() => directory.deleteSync(recursive: true));
  final harness = File(p.join(directory.path, 'deadline.swift'))
    ..writeAsStringSync('import Foundation\n'
        '${source.substring(start, end)}\n$_deadlineHarness');
  final executable = p.join(directory.path, 'deadline-fixture');
  final compile = Process.runSync('/usr/bin/swiftc', [harness.path, '-o', executable]);
  expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
  expect(compile.stderr, isEmpty, reason: 'Generated Swift must compile without warnings.');
  return Process.runSync(executable, [mode, phase]);
}

const _deadlineHarness = '''
let mode = CommandLine.arguments[1]
let phase = CommandLine.arguments[2]
let deadline = PatrolPhaseDeadline(phase: phase, timeout: 0.05)
deadline.enter(phase)
if mode == "finish" {
  deadline.finish()
  _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.1)
  print("DEADLINE_CANCELLED")
} else {
  // Bound the fixture itself if a regression disables the production deadline.
  DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(97) }
  // No main RunLoop progress: the independent deadline must still fail.
  DispatchSemaphore(value: 0).wait()
}
''';
