import 'dart:io';

import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _harness = r'''
import Foundation
import XCTest
enum RunDartTestResponseResult: String, Codable { case success, skipped, failure }
struct RunDartTestResponse: Codable {
  var result: RunDartTestResponseResult
  var details: String?
}
var failures = 0
func XCTFail(_ message: String) { failures += 1 }
final class PatrolDirectClient {
  var payload = "{\"result\":\"success\"}"
  var calls = 0
  var transportError: NSError?
  // GENERATED_CLIENT
  private func request<T: Decodable>(_ path: String, body: Data?, responseType: T.Type,
    completion: @escaping (Result<T, Error>) -> Void) {
    calls += 1
    precondition(path == "runDartTest")
    let object = try! JSONSerialization.jsonObject(with: body!) as! [String: String]
    precondition(object["name"] == "typed_skip_test journey")
    if let transportError = transportError {
      completion(.failure(transportError))
      return
    }
    do { completion(.success(try JSONDecoder().decode(T.self, from: Data(payload.utf8)))) }
    catch { completion(.failure(error)) }
  }
}
final class FixtureApp {
  func terminate() {}
  func launch() {}
}
final class PatrolPhaseDeadline {
  init(phase: String, timeout: Int) {}
  func enter(_ phase: String) {}
  func finish() {}
}
enum PatrolBridge {
  static var setupFailure: String?
  static var dartTests = ["typed_skip_test journey"]
  static var client: PatrolDirectClient? = PatrolDirectClient()
  static var noShard = false
  static var readinessFailure = false
  static var readinessWaits = 0
  static func ensureSetup() {}
  static func shouldRun(_ method: String) -> Bool { !noShard }
  static func selectionFailureMessage() -> String? { nil }
  static func appUnderTest() -> FixtureApp { FixtureApp() }
  static func tapLocalNetworkAlertIfPresent() {}
  static func waitForDartTests(client: PatrolDirectClient, expectedName: String,
    maxAttempts: Int, requestTimeout: Int, logPrefix: String, deadline: PatrolPhaseDeadline,
    beforeAttempt: (() -> Void)?) -> (tests: [String]?, failure: String) {
    readinessWaits += 1
    return (readinessFailure ? nil : dartTests, "Fixture discovery unavailable")
  }
  // GENERATED_RUN
  // GENERATED_RETRY
}
final class FixtureSelectedTest {
  // GENERATED_TEST
}
func check(_ name: String, result: String, details: String? = nil, expectedSkip: Bool,
  expectedFailure: Bool) {
  failures = 0
  PatrolBridge.noShard = false
  PatrolBridge.setupFailure = nil
  PatrolBridge.readinessFailure = false
  PatrolBridge.dartTests = ["typed_skip_test journey"]
  let client = PatrolDirectClient()
  PatrolBridge.client = client
  client.payload = "{\"result\":\"\(result)\"}"
  if let details = details {
    client.payload = String(data: try! JSONSerialization.data(withJSONObject:
      ["result": result, "details": details]), encoding: .utf8)!
  }
  var skipped = false
  do { try FixtureSelectedTest().testAJourney() }
  catch is XCTSkip { skipped = true }
  catch { fatalError("Unexpected error") }
  precondition(skipped == expectedSkip, "\(name): wrong skip outcome")
  precondition((failures > 0) == expectedFailure, "\(name): wrong failure outcome")
  if expectedSkip { precondition(client.calls == 1, "Typed skip must not retry") }
}
check("success", result: "success", expectedSkip: false, expectedFailure: false)
check("registered skip", result: "skipped", details: "Test is skipped in this app build",
  expectedSkip: true, expectedFailure: false)
check("runtime skip", result: "skipped", details: "Dart test skipped at runtime",
  expectedSkip: true, expectedFailure: false)
check("skip with retry prose", result: "skipped", details: "connection refused",
  expectedSkip: true, expectedFailure: false)
check("failure with skip prose", result: "failure", details: "TestSkippedException",
  expectedSkip: false, expectedFailure: true)
check("false result is malformed", result: "false", expectedSkip: false, expectedFailure: true)
check("unknown enum", result: "unknown", expectedSkip: false, expectedFailure: true)
func checkUnavailable(_ name: String, configure: () -> Void) {
  failures = 0
  PatrolBridge.setupFailure = nil
  PatrolBridge.dartTests = ["typed_skip_test journey"]
  PatrolBridge.client = PatrolDirectClient()
  PatrolBridge.readinessFailure = false
  PatrolBridge.noShard = false
  configure()
  do { try FixtureSelectedTest().testAJourney() }
  catch { fatalError("\(name): unavailable execution must not throw a skip") }
  precondition(failures == 1, "\(name): missing failure")
}
checkUnavailable("setup") { PatrolBridge.setupFailure = "Fixture setup unavailable" }
checkUnavailable("missing discovery") { PatrolBridge.dartTests = [] }
checkUnavailable("duplicate discovery") {
  PatrolBridge.dartTests = ["typed_skip_test journey", "typed_skip_test journey"]
}
checkUnavailable("missing client") { PatrolBridge.client = nil }
checkUnavailable("readiness") { PatrolBridge.readinessFailure = true }
checkUnavailable("transport") {
  PatrolBridge.client!.transportError = NSError(domain: "FixtureTransport", code: 1)
}
func checkRetries(_ name: String, error: NSError?, expectedCalls: Int, expectedLaunches: Int) {
  failures = 0
  PatrolBridge.setupFailure = nil
  PatrolBridge.noShard = false
  PatrolBridge.readinessFailure = error == nil
  PatrolBridge.readinessWaits = 0
  PatrolBridge.dartTests = ["typed_skip_test journey"]
  let client = PatrolDirectClient()
  client.transportError = error
  PatrolBridge.client = client
  do { try FixtureSelectedTest().testAJourney() }
  catch { fatalError("\(name): a failed run must not throw") }
  precondition(failures == 1, "\(name): missing failure")
  precondition(client.calls == expectedCalls,
    "\(name): \(client.calls) runDartTest call(s), expected \(expectedCalls)")
  precondition(PatrolBridge.readinessWaits == expectedLaunches,
    "\(name): \(PatrolBridge.readinessWaits) launch(es), expected \(expectedLaunches)")
}
checkRetries("app never ready is retried", error: nil, expectedCalls: 0, expectedLaunches: 4)
checkRetries("lost connection is retried", error: NSError(domain: NSURLErrorDomain,
  code: NSURLErrorNetworkConnectionLost,
  userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]),
  expectedCalls: 4, expectedLaunches: 4)
checkRetries("URLSession timeout of a started Dart test is a hang", error: NSError(
  domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
  userInfo: [NSLocalizedDescriptionKey: "The request timed out."]),
  expectedCalls: 1, expectedLaunches: 1)
checkRetries("runner wait timeout of a started Dart test is a hang", error: NSError(
  domain: "PatrolDirectClient", code: 2,
  userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for runDartTest response."]),
  expectedCalls: 1, expectedLaunches: 1)
checkRetries("a hang stays a hang when the timeout nests a connection error", error: NSError(
  domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
    userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])]),
  expectedCalls: 1, expectedLaunches: 1)
checkRetries("an unknown client error is not infrastructure evidence",
  error: NSError(domain: "FixtureTransport", code: 1), expectedCalls: 1, expectedLaunches: 1)
failures = 0
PatrolBridge.noShard = true
PatrolBridge.client = PatrolDirectClient()
do { try FixtureSelectedTest().testAJourney() }
catch { fatalError("No-shard is not a Dart skip") }
precondition(failures == 0 && PatrolBridge.client!.calls == 0)
print("IOS_TYPED_SKIP_PRODUCER: 20 behavior cases passed (not native UI proof)")
''';

String _section(String source, String start, String end) {
  final first = source.indexOf(start);
  expect(first, greaterThanOrEqualTo(0));
  final last = source.indexOf(end, first);
  expect(last, greaterThan(first));
  return source.substring(first, last);
}

String _fixture(String source, String method) => _harness
    .replaceAll('testAJourney()', '$method()')
    .replaceFirst(
        '// GENERATED_CLIENT', _section(source, '  func runDartTest(', '  private func request<T: Decodable>'))
    .replaceFirst(
        '// GENERATED_RUN', _section(source, '  static func run(_ description:', '  private static func shouldRetry'))
    .replaceFirst(
        '// GENERATED_RETRY', _section(source, '  private static func shouldRetry', '\n}\n\n// One camelCase'))
    .replaceFirst(
        '// GENERATED_TEST', _section(source, '  func $method()', '\n  private func runAssignedCoordinatorShard'));

void main() {
  test('actual generated typed producer preserves skip/failure/success with Apple XCTest', () {
    final directory = Directory.systemTemp.createTempSync('ios-typed-skip-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final testFile = File(p.join(directory.path, 'patrol_test', 'typed_skip_test.dart'));
    testFile.parent.createSync(recursive: true);
    testFile.writeAsStringSync("patrolTest('journey', (\$) async {});\n");
    generateIosPatrolRunner(directory.path);
    final source = File(p.join(directory.path, 'ios', 'RunnerUITests', 'RunnerUITests.swift')).readAsStringSync();
    final method = iosTestShards(directory.path).single.method;
    final file = File(p.join(directory.path, 'fixture.swift'))..writeAsStringSync(_fixture(source, method));
    final platform = Process.runSync('xcrun', ['--sdk', 'macosx', '--show-sdk-platform-path']);
    expect(platform.exitCode, 0);
    final frameworks = p.join(platform.stdout.toString().trim(), 'Developer', 'Library', 'Frameworks');
    final swiftSupport = p.join(platform.stdout.toString().trim(), 'Developer', 'usr', 'lib');
    final privateFrameworks = p.join(platform.stdout.toString().trim(), 'Developer', 'Library', 'PrivateFrameworks');
    final typecheckSource = _fixture(source, method)
        .split('func check(')
        .first
        .replaceFirst('final class FixtureSelectedTest {', 'final class FixtureSelectedTest: XCTestCase {');
    final typecheckFile = File(p.join(directory.path, 'typecheck.swift'))..writeAsStringSync(typecheckSource);
    final typecheck = Process.runSync('xcrun', [
      'swiftc',
      '-typecheck',
      '-F',
      frameworks,
      '-I',
      swiftSupport,
      '-module-cache-path',
      p.join(directory.path, 'swift-cache'),
      typecheckFile.path
    ]);
    expect(typecheck.exitCode, 0, reason: typecheck.stderr.toString());
    expect(typecheck.stderr, isEmpty);
    final binary = p.join(directory.path, 'fixture');
    final compile = Process.runSync('xcrun', [
      'swiftc',
      '-F',
      frameworks,
      '-I',
      swiftSupport,
      '-L',
      swiftSupport,
      '-lXCTestSwiftSupport',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      swiftSupport,
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      privateFrameworks,
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      frameworks,
      '-module-cache-path',
      p.join(directory.path, 'swift-cache'),
      file.path,
      '-o',
      binary
    ]);
    expect(compile.exitCode, 0, reason: compile.stderr.toString());
    expect(compile.stderr, isEmpty);
    stdout.writeln('IOS_TYPED_SKIP_SWIFT_COMPILE_OK');
    final result = Process.runSync(binary, []);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, contains('IOS_TYPED_SKIP_PRODUCER: 20 behavior cases passed'));
  }, testOn: 'mac-os');
}
