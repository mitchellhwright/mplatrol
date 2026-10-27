import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:mplatrol/src/ci_report/it_result_category.dart';
import 'package:mplatrol/src/ci_report/it_run_results.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:path/path.dart' as p;

/// A validated remedy for one kind of failure seen in mobile integration testing: what it looks like in the run
/// output ([symptom]), what it counts as ([category]) and how to fix it ([remedy]).
///
/// mplatrol ships the built-in lessons below. Projects add their own with [TestLesson.custom], registered through
/// `MplatrolCommandRunner(lessons: ...)` or the `lessons:` block of `mplatrol.yaml` (see [registerTestLessons]).
final class TestLesson {
  static const appPackage = TestLesson._(
      'appPackage',
      category: ItResultCategory.frameworkFailure,
      symptom: 'Patrol cannot launch the app: no launch intent, or the package name is invalid',
      'Pass the app applicationId to Patrol --package-name and '
          'PATROL_APP_PACKAGE_NAME; verify the installed APK package.');

  static const credentials = TestLesson._(
      'credentials',
      category: ItResultCategory.credFailure,
      symptom: 'Login fails on invalid or missing credentials (InvalidCredentials, missing E2E_USERNAME)',
      'Verify this tenant and environment login with your credential provider before retrying. Keep '
          'its one-time code with the login.');

  static const proxy = TestLesson._(
      'proxy',
      category: ItResultCategory.deviceFailure,
      symptom: 'Connection refused, ERR_PROXY_CONNECTION_FAILED or no network egress from the device',
      'Check both WebView and Flutter traffic. A physical Wi-Fi proxy alone '
          'does not route Flutter localhost:9090; use the owned adb reverse mapping '
          'or device VPN. On LambdaTest, check the tunnel and device binding.');

  static const appProcessCrashed = TestLesson._(
      'appProcessCrashed',
      category: ItResultCategory.appDefect,
      symptom: 'The app process crashed (Android FATAL EXCEPTION: main)',
      'The app under test crashed on an uncaught exception on its main thread, so the test lost the app. '
          'This is the app, not the test or the device: report it with the crash stack from the device log (the '
          'FATAL EXCEPTION block) and the session video, and rerun only to check whether it reproduces.');

  static const duplicateManifest = TestLesson._(
      'duplicateManifest',
      category: ItResultCategory.buildFailure,
      symptom: 'Android packaging fails on a duplicate META-INF/versions/9/OSGI-INF/MANIFEST.MF',
      'Exclude META-INF/versions/9/OSGI-INF/MANIFEST.MF from '
          'Android packaging; it is duplicate JVM metadata.');

  static const nativeAssetsMissing = TestLesson._(
      'nativeAssetsMissing',
      category: ItResultCategory.buildFailure,
      symptom: "The app fails at start with \"Couldn't resolve native function\" or dlopen of a native-asset "
          '.framework (no such file)',
      'A native-asset framework (package:objective_c, ...) is missing from '
          'Runner.app/Frameworks or was built for the simulator. Run a full '
          'clean of the app (build, ios/build, .dart_tool/flutter_build) and rebuild; mplatrol '
          'cleans automatically when it finds a simulator framework and verifies the '
          'frameworks before upload.');

  static const automationOwner = TestLesson._(
      'automationOwner',
      category: ItResultCategory.frameworkFailure,
      symptom: 'UiAutomation is already registered',
      'Patrol owns UiAutomation. Use its snapshot API or adb '
          'screencap/screenrecord; do not start a second uiautomator dump.');

  static const networkAllowlist = TestLesson._(
      'networkAllowlist',
      category: ItResultCategory.deviceFailure,
      symptom: 'The test environment answers "unauthorized network location"',
      'The test environment refused the device network. Emulators, '
          'simulators and LambdaTest reach it through this machine; mplatrol routes a USB '
          'Android phone automatically; an iPhone needs the one-time Wi-Fi proxy '
          '(Automatic) URL mplatrol prints. A phone on its own Wi-Fi is refused.');

  static const gradleDaemonEnvironment = TestLesson._(
      'gradleDaemonEnvironment',
      category: ItResultCategory.buildFailure,
      symptom: 'The Android device "is not found" or RecordTestResultEvent fails mid-run',
      'Gradle reused a daemon started in another environment '
          '(for example a sandboxed shell), so the test runner lost the device. Rerun '
          'with GRADLE_OPTS=-Dorg.gradle.daemon=false, or stop daemons with '
          '`./gradlew --stop` when no other build is using them.');

  static const emulatorOffline = TestLesson._(
      'emulatorOffline',
      category: ItResultCategory.deviceFailure,
      symptom: 'The Android emulator "is not found" by the test runner, or is offline or not booted before Gradle',
      'The emulator dropped off adb (it stayed offline after a reboot, usually after the adb auth handshake), so '
          'UTP could not find it and no test ran. mplatrol checks the emulator right before Gradle, reconnects '
          'it, then cold-starts the AVD, and stops with ANDROID_DEVICE_NOT_READY when it stays down. Check '
          '`adb devices`; if it lists the emulator as offline, close it, run `mplatrol devices --setup`, and rerun. '
          'Not a test or app result.');

  static const emulatorStorage = TestLesson._(
      'emulatorStorage',
      category: ItResultCategory.deviceFailure,
      symptom: 'INSTALL_FAILED_INSUFFICIENT_STORAGE on the emulator',
      'The emulator /data partition is full. Use an AVD with '
          'disk.dataPartition.size of 16G or more, or uninstall old app builds.');

  static const emulatorMemory = TestLesson._(
      'emulatorMemory',
      category: ItResultCategory.deviceFailure,
      symptom: 'A test process "was killed, which is usually due to low memory"',
      'The emulator ran out of memory and Android killed test '
          'services. Give it at least 6 GB (hw.ramSize=6144 or -memory 6144).');

  static const localDeviceContention = TestLesson._(
      'localDeviceContention',
      category: ItResultCategory.deviceFailure,
      symptom: 'LOCAL_DEVICE_CONTENTION: screenrecord processes this leg did not start ran on its local emulator',
      'Another adb client (another agent, tool or mplatrol run outside the lease) used the emulator during the leg: '
          "mplatrol found screenrecord processes it did not start. Dozens of them exhaust the emulator's binder "
          'buffers and Android restarts its system server ("System has crashed"), which aborts the run. Every local '
          '`mplatrol run` holds ~/.mplatrol/local-devices for the whole leg, and recorders writing '
          "/sdcard/mplatrol-e2e-* are mplatrol's own (it stops leftovers and never counts them); find the other client "
          '(`adb shell ps -A -o ARGS | grep screenrecord`, other terminals and agents), stop it, and rerun. '
          'Not a test or app result.');

  static const androidSystemCrashed = TestLesson._(
      'androidSystemCrashed',
      category: ItResultCategory.deviceFailure,
      symptom: 'INSTRUMENTATION_ABORTED: System has crashed (DeadSystemException) on the local emulator',
      "Android's system server died mid-run, so the instrumentation aborted and the remaining tests never ran: "
          "they are NOT RUN by the crash, not by a capability skip. On an overloaded host the emulator's watchdog "
          'kills a system server that is blocked for minutes (`adb logcat -b events -d | grep watchdog`, e.g. the '
          'window manager blocked for two minutes at a host load several times the core count). Look for '
          'LOCAL_DEVICE_CONTENTION in the '
          'leg log and for binder "No space left on device" errors in the per-test logcats under legs/<leg>/android; '
          'cold-boot the emulator (`adb emu kill`; the next local run boots it), run fewer lanes at once, and rerun. '
          'Not a test or app result.');

  static const androidSystemNotResponding = TestLesson._(
      'androidSystemNotResponding',
      category: ItResultCategory.deviceFailure,
      symptom: 'SYSTEM_NOT_RESPONDING: an "isn\'t responding" system dialog had focus on the local emulator',
      'An Android "not responding" dialog covered the app during the leg: System UI or the system server hung '
          'on the emulator, usually because the host is overloaded. mplatrol does not tap it (finding its Wait button '
          "needs uiautomator, which Patrol's instrumentation holds). Cold-boot the emulator (`adb emu kill`; the next "
          'local run boots it), run fewer lanes at once, and rerun. Not a test or app result.');

  static const permissionDialogUnanswered = TestLesson._(
      'permissionDialogUnanswered',
      category: ItResultCategory.frameworkFailure,
      symptom: 'PERMISSION_DIALOG_UNANSWERED: a system permission dialog stayed open without a button mplatrol knows',
      'The permission watcher found an Android permission dialog that stayed focused for several polls but could '
          'not place its button: either its window has no Frames line in `dumpsys window windows`, or its view '
          'hierarchy in `dumpsys activity top` has none of permission_allow_button, '
          'permission_allow_foreground_only_button or permission_allow_one_time_button. It did not tap: a blind tap '
          'can deny the permission (a blind tap can hit "Don\'t allow" on Android 16). Capture both dumps while '
          'the dialog shows and add its window or button format to android_permission_dialog.dart. A test that wants '
          'every dialog denied prints MPLATROL_PERMISSION_WATCHER=deny:all to the device log.');

  static const iosSimulatorFlutterLink = TestLesson._(
      'iosSimulatorFlutterLink',
      category: ItResultCategory.buildFailure,
      symptom: 'An iOS simulator build cannot link FlutterStandard classes or find Flutter/Flutter.h',
      'RunnerUITests did not link Flutter.framework. mplatrol '
          'patches the RunnerUITests Pods xcconfig after pod install for simulator '
          'builds; if pods were regenerated later, rerun so the patch applies.');

  static const locationAlert = TestLesson._(
      'locationAlert',
      category: ItResultCategory.testFailure,
      symptom: 'An iOS "Allow ... to use your location" alert blocks the flow',
      'An iOS location permission alert blocked the flow. Handle the '
          'location onboarding and its system alert in the test; a reinstall resets '
          'simctl privacy grants, so do not rely on pre-granting.');

  static const lambdaTestCapacity = TestLesson._(
      'lambdaTestCapacity',
      category: ItResultCategory.ltFailure,
      symptom: 'HyperExecute: no task started or finished for 5 minutes',
      'No task started or finished for 5 minutes. LambdaTest '
          'sessions are shared across the whole org; check its queue before calling '
          'it a device hang, and keep the default device pools instead of pinning one '
          'model.');

  static const lambdaTestDiscovery = TestLesson._(
      'lambdaTestDiscovery',
      category: ItResultCategory.ltFailure,
      symptom: 'LambdaTest failed to extract test cases from the device',
      'LambdaTest failed to extract test cases from the device. '
          'This is a provider-side failure, not a test result; retry later.');

  static const iosProvisioningExpired = TestLesson._(
      'iosProvisioningExpired',
      category: ItResultCategory.buildFailure,
      symptom: 'iOS signing: a provisioning profile expired',
      'An iOS provisioning profile has expired. mplatrol skips '
          'expired installed profiles and runs MPLATROL_IOS_SIGNING_COMMAND to install current '
          'ones; if that only finds expired profiles, renew them in the Apple developer account.');

  static const authPageScriptsBlocked = TestLesson._(
      'authPageScriptsBlocked',
      category: ItResultCategory.ltTunnelErr,
      symptom: 'A WebView page never shows its form (ERR_BLOCKED_BY_ORB)',
      'A WebView page loaded but its scripts never ran, so the '
          'form never appeared: its CDN requests were dropped on the way to the device (on LambdaTest the tunnel '
          "or its proxy; on a local device its network or this machine's egress proxy). This is network, not tenant or "
          'environment selection; rerun, and on LambdaTest run fewer lanes at once.');

  static const runtimeCredentialsUnreachable = TestLesson._(
      'runtimeCredentialsUnreachable',
      category: ItResultCategory.ltTunnelErr,
      symptom: 'A test cannot read its login: "Could not read runtime E2E credentials ... TimeoutException"',
      "The device could not reach this machine's credential server within 5 s, so the test never got its login: "
          'on LambdaTest through the tunnel (localhost.lambdatest.com), on a local Android device through adb '
          "reverse, on a local iPhone over this machine's network address. This is the connection, not the test or the "
          'user: rerun the leg; on LambdaTest run fewer lanes at once if several tests of one leg show it, locally '
          'check the device is still connected (`adb reverse --list`, or the iPhone on the same network).');

  static const ipAllowlistBlocked = TestLesson._(
      'ipAllowlistBlocked',
      category: ItResultCategory.ltTunnelErr,
      symptom: 'The backend answers "Your current IP address is not authorized" (an IP allowlist block page)',
      'The test environment refused the device because its traffic arrived from an address outside its allowlist: '
          'the device should reach the environment through this machine (a LambdaTest device through the tunnel, a '
          "local phone through this machine's egress proxy), so that path was not carrying the device's "
          'traffic. Tests that hang on that page then time out '
          '(iOS: Timed out waiting for runDartTest response). Check this machine reaches the environment, then rerun '
          'the leg; this is not a test failure.');

  static const lambdaTestFrameworkSetup = TestLesson._(
      'lambdaTestFrameworkSetup',
      category: ItResultCategory.ltFailure,
      symptom: 'HyperExecute: app update failed - Error setting up framework',
      'LambdaTest could not prepare the uploaded app for a '
          'device (HyperExecute "app update failed - Error setting up framework": its '
          'app patching never reported network_ready), so no test ran. This is NOT '
          'VERIFIED, not a test result; mplatrol already ran the job once more. If the retry failed the same way, '
          'the LambdaTest-side app patching of this upload is failing; upload the app again or raise it with '
          'LambdaTest support with the job link.');

  static const iosShardCoordinatorUnreachable = TestLesson._(
      'iosShardCoordinatorUnreachable',
      category: ItResultCategory.ltTunnelErr,
      symptom: 'An iOS shard is NOT RUN: it never reached the shard coordinator',
      'An iOS device session never reached the mplatrol shard '
          'coordinator while the other sessions of the same job did: every request was '
          'refused at 127.0.0.1, so LambdaTest most likely ran that session without '
          "binding it to this job's tunnel. The shard is NOT RUN, not a result; mplatrol "
          'reruns such shards once after the last wave. If it repeats, report the '
          'session to LambdaTest as a tunnel-binding failure.');

  static const iosDriverBindingReplacesPatrol = TestLesson._(
      'iosDriverBindingReplacesPatrol',
      category: ItResultCategory.frameworkFailure,
      symptom: 'iOS: the Developer Tools button is not reachable and the screen shows no widgets',
      'The iOS app ran under the Flutter driver binding '
          '(binding=_DriverBinding) instead of Patrol, so the Developer Tools button was never '
          'reachable and the screen showed no widgets: the app installs the Flutter driver extension in the build '
          'Patrol runs (for example `enableFlutterDriverExtension()` in a profile build). Skip the driver binding '
          'when Patrol runs. This is the build setup, not an app defect.');

  static const xcodebuildInterrupted = TestLesson._(
      'xcodebuildInterrupted',
      category: ItResultCategory.buildFailure,
      symptom: 'xcodebuild TEST BUILD INTERRUPTED, or build-for-testing failed (exit 75)',
      'xcodebuild build-for-testing was interrupted (exit 75): something outside the build '
          'stopped it, such as Ctrl-C on the run, a killed process group, or the machine sleeping. Not an app '
          'or test failure; rerun the leg.');

  static const lambdaTestTunnel = TestLesson._(
      'lambdaTestTunnel',
      category: ItResultCategory.ltTunnelErr,
      symptom: 'The LambdaTest tunnel fails (ERR::TUN::...)',
      'The LambdaTest tunnel failed, so no device could reach this machine. mplatrol retries a job whose tunnel never '
          'started once, and every test the tunnel stopped once more. "bind: address already in use" means another '
          'job holds the tunnel port; "signal: killed" '
          'means the tunnel process was stopped. Check LT_USERNAME and LT_ACCESS_KEY, run `mplatrol clean` when no '
          'other run uses a tunnel (it stops every tunnel), and rerun. Not a test or app result.');

  static const cocoaPodsSpecsOutdated = TestLesson._(
      'cocoaPodsSpecsOutdated',
      category: ItResultCategory.buildFailure,
      symptom: 'CocoaPods: none of your spec sources contain a spec satisfying the dependency',
      'The local CocoaPods spec repo is older than a pod the Podfile needs. Run `pod repo update trunk` (or '
          '`pod install --repo-update` in the app/ios), then rerun. Not a test or app result.');

  static const e2eImportsOptionalPackage = TestLesson._(
      'e2eImportsOptionalPackage',
      category: ItResultCategory.buildFailure,
      symptom: "The e2e bundle build fails: Couldn't resolve the package '<x>' or Error: Not found: 'package:...'",
      'A file in the app lib/e2e or patrol_test imports a package this tenant does not include (a '
          'tenant-optional plugin or SDK), so the bundle cannot compile and none of its tests ran. Remove the import '
          'and find the widget by Key, semantics label or runtimeType name instead. Not an app or test result.');

  static const staleIosDerivedData = TestLesson._(
      'staleIosDerivedData',
      category: ItResultCategory.buildFailure,
      symptom: 'xcodebuild: Undefined symbols for architecture arm64 in a vendor SDK (e.g. VisaPushProvisioning)',
      "The lane's iOS DerivedData (ios/build/xcui-lt) holds Swift modules of an SDK build another tenant used, or of "
          'the version before an SDK or plugin version switch, because Xcode keys them by path, so linking this tenant '
          'fails. mplatrol clears them when ios/Podfile.lock or the plugin set changes; otherwise move '
          'ios/build/xcui-lt to the Trash and rerun. Not an app or test result.');

  static const outdatedSystemWebView = TestLesson._(
      'outdatedSystemWebView',
      category: ItResultCategory.ltFailure,
      symptom: 'NoSuchMethodError: No method getWebkitToCompatConverter() in WebViewProviderFactoryBoundaryInterface',
      "The device's Android System WebView is older than the app's androidx.webkit, so the WebView failed to start. "
          'That is the LambdaTest device image, not the app or the test; the infra retry runs it again, and a device '
          'that repeats it should be avoided.');

  static const loginErrorPage = TestLesson._(
      'loginErrorPage',
      category: ItResultCategory.envFailure,
      symptom: 'The tenant login page loaded a browser error page (ERRPAGE:chrome-error://chromewebdata)',
      "The login WebView showed the browser's own error page instead of the tenant's login page: the environment's "
          'login host did not answer the WebView (network, DNS or the host down) at whichever login step it stalled. '
          'This is the environment, not the app or the test; rerun when the login page answers '
          "(`curl -sS -m 30 -o /dev/null -w '%{http_code}' <login URL>`).");

  static const iosSettingsAppNotRunning = TestLesson._(
      'iosSettingsAppNotRunning',
      category: ItResultCategory.frameworkFailure,
      symptom: 'iOS: XCUITest "Application com.apple.Preferences is not running"',
      'The runner queried the iOS Settings app after iOS ended it, usually right after a Settings switch was '
          'tapped, so XCUITest recorded a failure although the Dart test may have passed. A journey that toggles a '
          'Settings switch must read its result from inside the app, not by querying Settings again. Not an app '
          'defect.');

  static const iosOpenUrlTimeout = TestLesson._(
      'iosOpenUrlTimeout',
      category: ItResultCategory.frameworkFailure,
      symptom: 'iOS: XCUITest "Failed to open the default app for a URL: Timed out"',
      'The runner opened a deep link and XCUITest timed out waiting for iOS to finish the hand-off, although '
          'Patrol logged the URL as opened. A runner timing problem, not an app result; rerun, and report it if '
          'one deep link repeats it.');

  static const patrolClientTimeout = TestLesson._(
      'patrolClientTimeout',
      category: ItResultCategory.frameworkFailure,
      symptom: 'Patrol direct client error: "The request timed out." or "Timed out waiting for runDartTest response."',
      'The Patrol client on the device timed out: a native action took longer than the client timeout, the '
          'native side hung, or the Dart test never answered runDartTest. Not an app result; rerun, and report it '
          'if one step repeats it.');

  static const emptyCoverage = TestLesson._(
      'emptyCoverage',
      category: ItResultCategory.frameworkFailure,
      symptom: 'mplatrol run --coverage finished but Patrol wrote no coverage, or an lcov with no app code',
      'Patrol collects coverage only from a debug build whose COVERAGE_ENABLED dart-define is true; without it '
          'the app never signals Patrol and every test returns an empty report. mplatrol sets the define for '
          'local iOS and Android runs and rebuilds a build made without it. If it still happens, check that the log '
          'prints "Collected N / N coverages" and that Patrol ran a debug build; a test that never finishes also '
          'loses its coverage.');

  static const lambdaTestUpload = TestLesson._(
      'lambdaTestUpload',
      category: ItResultCategory.ltFailure,
      symptom: 'The LambdaTest app upload failed on every attempt (HTTP 5xx/429, connection reset, stalled upload)',
      'LambdaTest or the network failed every attempt to upload the app (mplatrol retried with backoff and then '
          'once more), so no test ran. This is LambdaTest infrastructure, not a test result: if other legs uploaded '
          'at the same time, rerun the leg; if every leg fails, check https://status.lambdatest.com and this '
          "machine's network to manual-api.lambdatest.com.");

  const TestLesson._(this.name, this.remedy, {required this.category, required this.symptom}) : pattern = null;

  /// A project lesson recognized by [pattern] (a regular expression, matched case-insensitively with `.`
  /// matching newlines) in the failure output.
  ///
  /// Throws:
  ///   ArgumentError: [name] is not a word of letters, digits and `_`, [pattern] is empty or not a valid regular
  ///     expression, or [category] is `pass`, `not-run`, `not-verified` or `not-selected` (a lesson explains a
  ///     failure; it never makes a result a pass or a verdict without a cause).
  TestLesson.custom({
    required this.name,
    required this.category,
    required this.symptom,
    required this.remedy,
    required String this.pattern,
  }) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'must start with a letter and hold only letters, digits and _');
    }
    if (_verdictOnlyCategories.contains(category)) {
      throw ArgumentError.value(category.label, 'category', 'a lesson must explain a failure');
    }
    if (pattern!.trim().isEmpty) {
      throw ArgumentError.value(pattern, 'pattern', 'must not be empty');
    }
    try {
      RegExp(pattern!);
    } on FormatException catch (error) {
      throw ArgumentError.value(pattern, 'pattern', 'is not a valid regular expression: ${error.message}');
    }
  }

  /// The built-in lessons, in recognition priority order.
  static const builtIn = <TestLesson>[
    appPackage,
    credentials,
    proxy,
    appProcessCrashed,
    duplicateManifest,
    nativeAssetsMissing,
    automationOwner,
    networkAllowlist,
    gradleDaemonEnvironment,
    emulatorOffline,
    emulatorStorage,
    emulatorMemory,
    localDeviceContention,
    androidSystemCrashed,
    androidSystemNotResponding,
    permissionDialogUnanswered,
    iosSimulatorFlutterLink,
    locationAlert,
    lambdaTestCapacity,
    lambdaTestDiscovery,
    iosProvisioningExpired,
    authPageScriptsBlocked,
    runtimeCredentialsUnreachable,
    ipAllowlistBlocked,
    lambdaTestFrameworkSetup,
    iosShardCoordinatorUnreachable,
    iosDriverBindingReplacesPatrol,
    xcodebuildInterrupted,
    lambdaTestTunnel,
    cocoaPodsSpecsOutdated,
    e2eImportsOptionalPackage,
    staleIosDerivedData,
    outdatedSystemWebView,
    loginErrorPage,
    iosSettingsAppNotRunning,
    iosOpenUrlTimeout,
    patrolClientTimeout,
    emptyCoverage,
    lambdaTestUpload,
  ];

  /// The built-in lessons, then the registered project lessons ([registerTestLessons]).
  static List<TestLesson> get values => List.unmodifiable([...builtIn, ..._registered]);

  /// The stable identifier reports, the lesson history and `lesson <name>` log lines use.
  final String name;

  /// The regular expression of a [TestLesson.custom] lesson; null for a built-in one.
  final String? pattern;

  /// What failed, in the words of the run output; `mplatrol docs --troubleshooting` lists lessons by it.
  final String symptom;

  /// The cause and the fix `mplatrol run` prints when it recognizes this lesson.
  final String remedy;

  /// What a result this lesson explains counts as in the reports.
  final ItResultCategory category;

  /// True when this failure is a defect in the app under test rather than in
  /// the test, the device or the environment.
  bool get appDefect => category == ItResultCategory.appDefect;

  @override
  String toString() => 'TestLesson.$name';
}

const _verdictOnlyCategories = {
  ItResultCategory.pass,
  ItResultCategory.notRun,
  ItResultCategory.notVerified,
  ItResultCategory.notSelected,
};

final _registered = <TestLesson>[];

/// Adds project [lessons] after the built-in ones, so [recognizeTestLessons] recognizes them and reports name
/// them. Registering a lesson again is a no-op.
///
/// Throws:
///   ArgumentError: a lesson is not a [TestLesson.custom] lesson, or its name is already taken by another lesson.
void registerTestLessons(Iterable<TestLesson> lessons) {
  for (final lesson in lessons) {
    if (lesson.pattern == null) {
      throw ArgumentError.value(lesson.name, 'lessons', 'only TestLesson.custom lessons can be registered');
    }
    if (_registered.contains(lesson)) {
      continue;
    }
    if (TestLesson.values.any((known) => known.name == lesson.name)) {
      throw ArgumentError.value(lesson.name, 'lessons', 'a lesson with this name already exists');
    }
    _registered.add(lesson);
  }
}

/// Removes every registered project lesson; for tests.
@visibleForTesting
void clearRegisteredTestLessons() => _registered.clear();

const _lessonPatterns = {
  TestLesson.appPackage: 'getlaunchintentforpackage|(?:app )?package name is invalid',
  TestLesson.credentials: 'invalidcredentials|missing username/password|missing e2e_username',
  TestLesson.proxy: 'connection refused|err_proxy_connection_failed|no network egress',
  TestLesson.appProcessCrashed: r'fatal exception: main\b',
  TestLesson.duplicateManifest: 'meta-inf/versions/9/osgi-inf/manifest\\.mf',
  TestLesson.nativeAssetsMissing: r"couldn't resolve native function|dlopen[^\n]*\.framework[^\n]*no such file|"
      r'native assets specification[^\n]*references[^\n]*which was not found',
  TestLesson.automationOwner: 'uiautomation.*already registered|already registered.*uiautomation',
  TestLesson.networkAllowlist: 'unauthorized network location',
  TestLesson.gradleDaemonEnvironment: r'android device \([^)]*\) is not found|recordtestresultevent failed',
  TestLesson.emulatorOffline: 'android device \\(emulator-\\d+\\) is not found|$androidDeviceNotReadyMarker',
  TestLesson.emulatorStorage: 'install_failed_insufficient_storage',
  TestLesson.emulatorMemory: 'was killed, which is usually due to low memory',
  TestLesson.iosSimulatorFlutterLink: r'_objc_class_\$_flutterstandard|.flutter/flutter\.h. file not found',
  TestLesson.locationAlert: r'allow [^\n]{0,80} to use your location',
  TestLesson.lambdaTestCapacity: 'no task started or finished for [0-9]+ min',
  TestLesson.lambdaTestDiscovery: 'failed to extract test cases from (?:the )?device',
  TestLesson.iosProvisioningExpired: 'provisioning profile "[^"]*" expired on',
  TestLesson.runtimeCredentialsUnreachable: r'could not read runtime e2e credentials[^\n]*timeoutexception',
  TestLesson.ipAllowlistBlocked: 'ip(?: |_)address(?: |_)is(?: |_)not(?: |_)authorized',
  TestLesson.authPageScriptsBlocked: r'net::err_blocked_by_orb',
  TestLesson.lambdaTestFrameworkSetup: 'app update failed - error setting up framework',
  TestLesson.lambdaTestUpload: r'lambdatest upload of [^\n]+ failed after \d+ attempts',
  TestLesson.iosShardCoordinatorUnreachable: 'patrol_shard_not_run|patrol_selection_coordinator_failed',
  TestLesson.iosDriverBindingReplacesPatrol: 'binding=_driverbinding|$_emptyDevToolsScreen',
  TestLesson.xcodebuildInterrupted: r'\*\* test build interrupted \*\*|build-for-testing failed \(exit 75\)',
  TestLesson.lambdaTestTunnel: 'err::tun::',
  TestLesson.cocoaPodsSpecsOutdated:
      'none of your spec sources contain a spec satisfying|out-of-date source repos which you can update',
  TestLesson.e2eImportsOptionalPackage: "couldn't resolve the package '[^']+'|error: not found: 'package:",
  TestLesson.staleIosDerivedData: 'undefined symbols for architecture arm64',
  TestLesson.loginErrorPage: 'errpage:chrome-error://',
  TestLesson.outdatedSystemWebView: 'no method getwebkittocompatconverter',
  TestLesson.iosSettingsAppNotRunning: r'application com\.apple\.preferences is not running',
  TestLesson.iosOpenUrlTimeout: 'failed to open the default app for a url: timed out',
  TestLesson.patrolClientTimeout:
      r'patrol direct client error:[^\n]{0,200}(?:request timed out|timed out waiting for rundarttest response)',
  TestLesson.localDeviceContention: localDeviceContentionMarker,
  TestLesson.permissionDialogUnanswered: permissionDialogUnansweredMarker,
  TestLesson.androidSystemCrashed: 'instrumentation_aborted: system has crashed|deadsystemexception',
  TestLesson.androidSystemNotResponding: systemNotRespondingMarker,
};

/// The Developer Tools timeout of an iOS app running under the Flutter driver
/// binding: Patrol sees only the root views and no text.
const _emptyDevToolsScreen = 'developer tools button was not reachable.{0,2000}?$_rootViewsOnly';
const _rootViewsOnly = r'widgets\[view,rawview,_mediaqueryfromview,privacyscreen\] texts\[\]';

/// What `mplatrol run` logs when a local Android device is offline, unauthorized, missing or not booted right
/// before Gradle, after the emulator recovery failed.
const androidDeviceNotReadyMarker = 'ANDROID_DEVICE_NOT_READY';

/// What `mplatrol run` logs when it finds screenrecord processes it did not start on its local emulator.
const localDeviceContentionMarker = 'LOCAL_DEVICE_CONTENTION';

/// What the Android permission watcher logs when it finds a permission dialog it cannot answer by element.
const permissionDialogUnansweredMarker = 'PERMISSION_DIALOG_UNANSWERED';

/// What the Android permission watcher logs when an "isn't responding" system dialog has focus.
const systemNotRespondingMarker = 'SYSTEM_NOT_RESPONDING';

/// Lessons a more specific lesson explains: the coordinator's refused connections are not a device proxy
/// problem, an emulator UTP cannot find had dropped off adb, and a system crash during contention was caused by
/// the other adb client.
const _supersededBy = {
  TestLesson.proxy: TestLesson.iosShardCoordinatorUnreachable,
  TestLesson.gradleDaemonEnvironment: TestLesson.emulatorOffline,
  TestLesson.androidSystemCrashed: TestLesson.localDeviceContention,
};

RegExp? _lessonPattern(TestLesson lesson) {
  final source = lesson.pattern ?? _lessonPatterns[lesson];
  return source == null ? null : RegExp(source, caseSensitive: false, dotAll: true);
}

/// Classifies explicit failure evidence; unknown failures remain unclassified.
Set<TestLesson> recognizeTestLessons(String evidence) {
  final matched = {
    for (final lesson in TestLesson.values)
      if (_lessonPattern(lesson)?.hasMatch(evidence) ?? false) lesson,
  };
  return matched.where((lesson) => !matched.contains(_supersededBy[lesson])).toSet();
}

/// The trimmed evidence line where [lesson] was recognized, or null when
/// [evidence] does not show it.
String? lessonKeyErrorLine(TestLesson lesson, String evidence) {
  final match = _lessonPattern(lesson)?.firstMatch(evidence);
  if (match == null) {
    return null;
  }
  final start = evidence.lastIndexOf('\n', match.start) + 1;
  final end = evidence.indexOf('\n', match.start);
  return evidence.substring(start, end < 0 ? evidence.length : end).trim();
}

/// Logs the remedy for every lesson recognized in [evidence] with how often it
/// has been seen in [repo], recording the occurrence, and hands the lessons to
/// [ItRunResults] to explain the tests of the current leg that end without a result. Unrecognized evidence
/// logs nothing.
void reportTestLessons(String evidence, {required String repo, required MplatrolLogger logger}) {
  final lessons = recognizeTestLessons(evidence);
  if (lessons.isEmpty) {
    return;
  }
  getDep<ItRunResults>().observeLessons(lessons);
  var counts = <TestLesson, int>{};
  try {
    counts = TestLessonHistory(repo).record(lessons);
  } on Exception catch (error) {
    logger.warn('Could not save mplatrol lesson history: ${error.runtimeType}.');
  }
  for (final lesson in lessons) {
    logger.info('lesson ${lesson.name} (observed ${counts[lesson] ?? 1}): ${lesson.remedy}');
  }
}

/// Stores only recognized category counts and timestamps, never raw evidence.
///
/// Corrupt history fails explicitly so the caller can report the problem.
class TestLessonHistory {
  TestLessonHistory(String repo) : file = File(p.join(repo, '.mplatrol', 'test_lessons.json'));

  final File file;

  /// Reads the validated counts used to surface recurring failures.
  Map<TestLesson, int> read() {
    if (!file.existsSync()) {
      return {};
    }
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map || data['schemaVersion'] != 1 || data['lessons'] is! Map) {
      throw const FormatException('Invalid mplatrol lesson history schema.');
    }
    final entries = data['lessons'] as Map;
    final counts = <TestLesson, int>{};
    for (final lesson in TestLesson.values) {
      final entry = entries[lesson.name];
      if (entry == null) {
        continue;
      }
      if (entry is! Map || entry['count'] is! int || (entry['count'] as int) < 1) {
        throw const FormatException('Invalid mplatrol lesson history count.');
      }
      counts[lesson] = entry['count'] as int;
    }
    return counts;
  }

  /// Records one occurrence per category and returns the updated counts.
  Map<TestLesson, int> record(Set<TestLesson> lessons) {
    final counts = read();
    for (final lesson in lessons) {
      counts[lesson] = (counts[lesson] ?? 0) + 1;
    }
    if (lessons.isEmpty) {
      return counts;
    }
    file.parent.createSync(recursive: true);
    final ignore = File(p.join(file.parent.path, '.gitignore'));
    if (!ignore.existsSync()) {
      ignore.writeAsStringSync('*\n');
    }
    file.writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'lessons': {
        for (final entry in counts.entries) entry.key.name: {'count': entry.value},
      },
    }));
    return counts;
  }
}
