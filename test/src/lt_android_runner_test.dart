import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/local_runner.dart';
import 'package:mplatrol/src/lt_android_runner.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/lt_tunnel.dart';
import 'package:mplatrol/src/patrol_sdk_artifact.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _MockMplatrolProcess extends Mock implements MplatrolProcess {}

/// The name the mocked [LtTunnel] reports for the started tunnel; the runner
/// forwards it into the Espresso trigger payload.
const _tunnelName = 'alkstg-me';

/// A scripted [MplatrolShell] mock for the runner's NON-HTTP shell steps only —
/// `git rev-parse` (build name) and `patrol build android`. The LambdaTest HTTP
/// calls no longer shell out to `curl`; they go through [LtHttp] and are stubbed
/// by [_HttpStubs]. The tunnel is started by [LtTunnel], mocked separately.
class _ScriptedShell {
  _ScriptedShell(this.shell);

  final MplatrolShell shell;

  /// Every command string seen, in order.
  final List<String> ranScripts = [];

  final List<MapEntry<String, ProcessResultX>> _routes = [];
  final List<MapEntry<String, List<ProcessResultX>>> _sequences = [];
  final ProcessResultX _defaultResult = _result();
  void Function(String command)? onCommand;
  void Function(String command)? afterCommand;

  /// Route any command string CONTAINING [needle] to a result with
  /// [stdout]/[exitCode].
  void route(String needle, {String stdout = '', int exitCode = 0}) {
    _routes.add(MapEntry(needle, _result(stdout: stdout, exitCode: exitCode)));
  }

  /// Route successive commands CONTAINING [needle] to [results] in order (the
  /// last entry is reused once exhausted). Lets a test model a build that fails
  /// transiently then succeeds on retry.
  void routeSequence(String needle, List<ProcessResultX> results) {
    _sequences.add(MapEntry(needle, [...results]));
  }

  void install() {
    when(
      () => shell.run(
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        silent: any(named: 'silent'),
        forceVerbose: any(named: 'forceVerbose'),
      ),
    ).thenAnswer((invocation) async => _respond(invocation.positionalArguments.first as String));
    when(
      () => shell.runArgs(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        silent: any(named: 'silent'),
        forceVerbose: any(named: 'forceVerbose'),
        quietBuild: any(named: 'quietBuild'),
      ),
    ).thenAnswer((invocation) async {
      final executable = invocation.positionalArguments[0] as String;
      final arguments = invocation.positionalArguments[1] as List<String>;
      return _respond('$executable ${arguments.join(' ')}');
    });
  }

  ProcessResultX _respond(String command) {
    ranScripts.add(command);
    onCommand?.call(command);
    afterCommand?.call(command);
    for (final sequence in _sequences.reversed) {
      if (command.contains(sequence.key)) {
        return sequence.value.length == 1 ? sequence.value.first : sequence.value.removeAt(0);
      }
    }
    // Later routes win, so a test can override a happy-path route by adding
    // another with the same needle after stubHappyShell().
    for (final route in _routes.reversed) {
      if (command.contains(route.key)) {
        return route.value;
      }
    }
    return _defaultResult;
  }

  bool ranContaining(String needle) => ranScripts.any((script) => script.contains(needle));

  static ProcessResultX _result({String stdout = '', int exitCode = 0}) =>
      ProcessResultX(pid: 1, exitCode: exitCode, stdout: stdout, stderr: '');
}

/// Stubs the runner's [LtHttp] calls for the Android happy path and records
/// each call so tests can assert on it. App and instrumentation uploads are
/// both direct multipart uploads and are told apart by their APK paths.
class _HttpStubs {
  _HttpStubs(this.http);

  final LtHttp http;

  /// Bodies returned by each happy-path call; tests reassign one before run().
  String appUploadBody = '{"app_url":"lt://APP_APP"}';
  String testUploadBody = '{"app_url":"lt://APP_TEST"}';
  String espressoBody = '{"buildId":"build-123"}';
  String pollBody = '{"data":{"status_ind":"passed"}}';
  String sessionsBody = '{"data":[]}';

  /// Every multipart POST with a `filePath` (the direct test-APK upload).
  final List<Invocation> directUploads = [];

  void install() {
    when(
      () => http.postMultipart(
        any(),
        headers: any(named: 'headers'),
        fields: any(named: 'fields'),
        filePath: any(named: 'filePath', that: isNotNull),
        onAnswered: any(named: 'onAnswered'),
      ),
    ).thenAnswer((invocation) async {
      directUploads.add(invocation);
      final filePath = invocation.namedArguments[#filePath] as String;
      final body = filePath.contains('androidTest') ? testUploadBody : appUploadBody;
      return _response(body, 200);
    });

    when(
      () => http.postJson(
        any(),
        headers: any(named: 'headers'),
        body: any(named: 'body'),
      ),
    ).thenAnswer((_) async => _response(espressoBody, 200));

    when(
      () => http.get(
        any(),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((invocation) async {
      final url = invocation.positionalArguments.first as String;
      final body = url.contains('/sessions?') ? sessionsBody : pollBody;
      return _response(body, 200);
    });
  }
}

http.Response _response(String body, int status) => http.Response(body, status);

/// Zero poll delay keeps the retry/poll loops instant in tests.
LtAndroidRunner _runner({Duration pollDelay = Duration.zero}) =>
    LtAndroidRunner(pollDelay: pollDelay, uploadPolicy: instantLtUploadPolicy);

Map<String, String> _fullEnv() => {
      'LT_USERNAME': 'lt-user',
      'LT_ACCESS_KEY': 'lt-key',
      'LT_BIN': '/Users/me/Downloads/LT',
    };

void main() {
  late Directory parentDir;
  late Directory appDir;
  late _ScriptedShell scripted;
  late _HttpStubs httpStubs;
  late FileSystem fileSystem;
  late LtTunnel ltTunnel;
  late _MockMplatrolProcess tunnelProcess;
  late bool tunnelKilled;
  late List<String?> startTunnelNames;

  String appApkPath() => p.join(appDir.path, 'build/app/outputs/apk/debug/app-debug.apk');
  String testApkPath() => p.join(appDir.path, 'build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk');
  String cachePath() => p.join(appDir.path, 'build/app/outputs/lt-last.json');

  /// Make the APK-existence reads deterministic by routing the FileSystem mock
  /// to a backing set the test controls.
  void stubFileSystem({bool appApk = true, bool testApk = true}) {
    final existing = <String>{if (appApk) appApkPath(), if (testApk) testApkPath()};
    when(
      () => fileSystem.fileExistsSync(any()),
    ).thenAnswer((invocation) {
      final path = invocation.positionalArguments.first as String;
      return _fixtureFileExists(existing, path, appApkPath(), testApkPath());
    });
  }

  /// Stub [LtTunnel.start] to report ready with [name] and hand back a process
  /// whose `kill()` flips [tunnelKilled]; record each requested name.
  void stubTunnel({bool ready = true, String name = _tunnelName}) {
    when(
      () => ltTunnel.start(
        ltBin: any(named: 'ltBin'),
        ltUser: any(named: 'ltUser'),
        ltKey: any(named: 'ltKey'),
        tunnelName: any(named: 'tunnelName'),
      ),
    ).thenAnswer((invocation) async {
      startTunnelNames.add(invocation.namedArguments[#tunnelName] as String?);
      return (process: tunnelProcess, ready: ready, name: name);
    });
  }

  /// Route the two non-HTTP shell steps (build name + patrol build) to their
  /// happy-path responses. The HTTP steps are stubbed by [_HttpStubs].
  void stubHappyShell() {
    scripted.route('git rev-parse --short HEAD', stdout: 'abc1234');
  }

  setUp(() async {
    await scaffoldMockDependencies();

    fileSystem = getDep<FileSystem>();
    parentDir = Directory.systemTemp.createTempSync('lt_android_runner');
    appDir = Directory(p.join(parentDir.path, 'app'))..createSync();
    File(p.join(appDir.path, 'android', 'app', 'build.gradle'))
      ..createSync(recursive: true)
      ..writeAsStringSync('android {\n defaultConfig {\n'
          ' applicationId "com.example.wccu.staging"\n }\n}\n');
    // A Patrol test fixture so generateAndroidPatrolRunner (run before the build)
    // has something to generate from instead of throwing on an empty suite.
    File(p.join(appDir.path, 'patrol_test', 'patrol_login_test.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("patrolTest('sample test', (\$) async {});\n");
    File(p.join(appDir.path, defaultE2eDartDefineFile))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"E2E_ENVIRONMENT": "Dev"}\n');
    _sdkFixture(appDir);
    when(fileSystem.getAppDirectory).thenReturn(appDir);
    when(() => fileSystem.readAsStringSync(any()))
        .thenAnswer((invocation) => File(invocation.positionalArguments.first as String).readAsStringSync());
    when(() => fileSystem.writeAsStringSync(
        filePath: any(named: 'filePath'),
        newContent: any(named: 'newContent'),
        flush: any(named: 'flush'))).thenAnswer((invocation) => File(invocation.namedArguments[#filePath] as String)
      ..createSync(recursive: true)
      ..writeAsStringSync(invocation.namedArguments[#newContent] as String));

    when(() => getDep<LocalRunner>().preparePatrolCliCommand(any())).thenAnswer((_) async => [
          '/fixture/pub-cache/bin/fvm',
          'dart',
          p.join(appDir.path, '.mplatrol/patched_packages/patrol_cli/bin/main.dart'),
        ]);
    scripted = _ScriptedShell(getDep<MplatrolShell>())..install();
    scripted.afterCommand = (command) => _compileFixtureCommand(command, appDir);
    httpStubs = _HttpStubs(getDep<LtHttp>());

    ltTunnel = getDep<LtTunnel>();
    tunnelProcess = _MockMplatrolProcess();
    tunnelKilled = false;
    startTunnelNames = [];
    when(tunnelProcess.kill).thenAnswer((_) => tunnelKilled = true);
    stubTunnel();
  });

  tearDown(() {
    if (parentDir.existsSync()) {
      parentDir.deleteSync(recursive: true);
    }
  });

  _sdkProducerCases(
      repo: () => appDir,
      scripted: () => scripted,
      httpStubs: () => httpStubs,
      stubFiles: stubFileSystem,
      stubShell: stubHappyShell);
  _automaticReuseCases(
      repo: () => appDir,
      scripted: () => scripted,
      httpStubs: () => httpStubs,
      stubFiles: stubFileSystem,
      stubShell: stubHappyShell);
  _legacyPackageBindingReceiptCase(
      repo: () => appDir,
      scripted: () => scripted,
      httpStubs: () => httpStubs,
      stubFiles: stubFileSystem,
      stubShell: stubHappyShell);
  _registrantAndLauncherCases(
      repo: () => appDir,
      scripted: () => scripted,
      httpStubs: () => httpStubs,
      stubFiles: stubFileSystem,
      stubShell: stubHappyShell);
  _flutterPropertyWriterCases(
      repo: () => appDir,
      scripted: () => scripted,
      httpStubs: () => httpStubs,
      stubFiles: stubFileSystem,
      stubShell: stubHappyShell);

  group('LtAndroidRunner.run', () {
    test('an unresolved package stops before invoking Patrol', () async {
      File(p.join(appDir.path, 'android', 'app', 'build.gradle'))
          .writeAsStringSync('android { defaultConfig { applicationId project.name } }');
      expect(await _runner().buildAndroid(repo: appDir.path, target: 'patrol_test/patrol_login_test.dart'),
          ExitCode.config.code);
      expect(scripted.ranContaining('patrol build android'), isFalse);
    });

    test('runs the full happy path and returns success', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();
      final http = getDep<LtHttp>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);

      // (1) one fresh tunnel started (no LT_TUNNEL_NAME in env => null) and
      // killed on the way out.
      expect(startTunnelNames, [null]);
      expect(tunnelKilled, isTrue);
      // (2) patrol build with the two dart-defines.
      expect(
        scripted.ranContaining(
          'build android --debug --package-name com.example.tenant.staging --no-label --target '
          'patrol_test/mplatrol_filtered_test.dart '
          '--dart-define=LT_PROXY=true --dart-define=E2E_TEST_BRIDGE=true '
          '--dart-define=PATROL_APP_PACKAGE_NAME=com.example.tenant.staging '
          '--dart-define=E2E_ENVIRONMENT=Dev',
        ),
        isTrue,
      );
      // (3) app and instrumentation APKs are uploaded directly. No GitLab PAT
      // is handed to LambdaTest as a url-fetch query string.
      verify(
        () => http.postMultipart(
          any(),
          headers: any(named: 'headers'),
          fields: any(
            named: 'fields',
            that: allOf(containsPair('name', 'PatrolAndroid-abc1234-app'), isNot(containsPair('url', anything))),
          ),
          filePath: any(named: 'filePath', that: equals(appApkPath())),
          onAnswered: any(named: 'onAnswered'),
        ),
      ).called(1);
      verify(
        () => http.postMultipart(
          any(),
          headers: any(named: 'headers'),
          fields: any(named: 'fields', that: containsPair('name', 'PatrolAndroid-abc1234-test')),
          filePath: any(named: 'filePath', that: equals(testApkPath())),
          onAnswered: any(named: 'onAnswered'),
        ),
      ).called(1);
      // (4) espresso trigger carries the build name, tunnel, localhost routing,
      // device, and idleTimeout in the JSON body without asking LT to rebuild
      // the uploaded app for network-log capture.
      verify(
        () => http.postJson(
          any(that: contains('espresso/build')),
          headers: any(named: 'headers'),
          body: any(
            named: 'body',
            that: allOf([
              containsPair('build', 'PatrolAndroid-abc1234'),
              containsPair('tunnel', true),
              containsPair('tunnelName', _tunnelName),
              containsPair('localhost', true),
              containsPair('mitmProxy', true),
              isNot(containsPair('network', true)),
              containsPair('idleTimeout', 900),
              containsPair('device', ['Galaxy S23-13']),
            ]),
          ),
        ),
      ).called(1);
      // (5) poll the build to a terminal status.
      verify(
        () => http.get(
          any(that: contains('/builds/build-123')),
          headers: any(named: 'headers'),
        ),
      ).called(1);

      verify(() => logger.progress('Uploading app APK to LambdaTest')).called(1);
      verify(() => logger.progress('Uploading test APK to LambdaTest')).called(1);
      verify(
        () => logger.info(
          any(
            that: contains(
              'Generated 1 Android LambdaTest Patrol @Test '
              'method',
            ),
          ),
        ),
      ).called(1);
      verifyNever(() => logger.info(any(that: startsWith('app: '))));
      verifyNever(() => logger.info(any(that: startsWith('test: '))));
      verify(() => logger.success(any(that: contains('build-123')))).called(1);
    });

    test('test-only edits regenerate discovery and invoke a fresh incremental build', () async {
      stubFileSystem();
      stubHappyShell();
      final cache = File(p.join(appDir.path, '.dart_tool/flutter_build/kernel-cache'))
        ..createSync(recursive: true)
        ..writeAsStringSync('valid incremental cache');
      final target = File(p.join(appDir.path, 'patrol_test/patrol_login_test.dart'))
        ..writeAsStringSync("patrolTest('first regression', (\$) async {});\n");
      var builds = 0;
      scripted.onCommand = (command) {
        if (!command.contains('build android')) {
          return;
        }
        builds++;
        expect(cache.readAsStringSync(), 'valid incremental cache');
        final directory = Directory(p.join(appDir.path, 'android/app/src/androidTest/java/mplatrol/e2e'));
        final generated = directory.listSync().whereType<File>().map((file) => file.readAsStringSync()).join('\n');
        expect(generated, contains('runDartTest("first regression")'));
        expect(generated.contains('runDartTest("second regression")'), builds == 2);
      };
      Future<int> build() => _runner().buildAndroid(
            repo: appDir.path,
            target: 'patrol_test/patrol_login_test.dart',
            env: _fullEnv(),
          );

      expect(await build(), ExitCode.success.code);
      target.writeAsStringSync("patrolTest('first regression', (\$) async {});\n"
          "patrolTest('second regression', (\$) async {});\n");
      expect(await build(), ExitCode.success.code);
      expect(builds, 2);
    });

    test('keeps incremental caches but clears final APK outputs before building', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final incrementalDirectories = [
        Directory(p.join(appDir.path, '.dart_tool/flutter_build')),
        Directory(p.join(appDir.path, 'build/app/intermediates/flutter')),
      ];
      final staleDirectories = [
        Directory(p.join(appDir.path, 'build/app/outputs/flutter-apk')),
      ];
      for (final directory in [...incrementalDirectories, ...staleDirectories]) {
        directory.createSync(recursive: true);
        File(p.join(directory.path, 'sentinel')).writeAsStringSync('stale');
      }
      final staleApks = [File(appApkPath()), File(testApkPath())];
      for (final file in staleApks) {
        file.createSync(recursive: true);
        file.writeAsStringSync('stale');
      }
      scripted.onCommand = (command) {
        if (!command.contains('build android')) {
          return;
        }
        for (final directory in incrementalDirectories) {
          expect(File(p.join(directory.path, 'sentinel')).readAsStringSync(), 'stale');
        }
        for (final directory in staleDirectories) {
          expect(directory.existsSync(), isFalse);
        }
        for (final file in staleApks) {
          expect(file.existsSync(), isFalse);
        }
      };

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
    });

    test('forwards LT_TUNNEL_NAME from env to the tunnel', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final env = _fullEnv()..['LT_TUNNEL_NAME'] = 'configured-tunnel';

      await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: env,
      );

      expect(startTunnelNames, ['configured-tunnel']);
    });

    test('uses the short SHA in the build name', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final http = getDep<LtHttp>();

      await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      verify(
        () => http.postJson(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body', that: containsPair('build', 'PatrolAndroid-abc1234')),
        ),
      ).called(1);
    });

    test('falls back to a "local" build name when the SHA is empty', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      scripted.route('git rev-parse --short HEAD');
      final http = getDep<LtHttp>();

      await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      verify(
        () => http.postJson(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body', that: containsPair('build', 'PatrolAndroid-local')),
        ),
      ).called(1);
    });

    test('returns config error and logs each missing env value', () async {
      final logger = getDep<MplatrolLogger>();
      final env = _fullEnv()..remove('LT_BIN');

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: env,
      );

      expect(exitCode, ExitCode.config.code);
      verify(() => logger.err(any(that: contains('LT_BIN')))).called(1);
      // It must not start any shell work — including the tunnel — when env is
      // incomplete.
      expect(scripted.ranScripts, isEmpty);
      expect(startTunnelNames, isEmpty);
    });

    test('treats an empty env value as missing', () async {
      final env = _fullEnv()..['LT_ACCESS_KEY'] = '';

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: env,
      );

      expect(exitCode, ExitCode.config.code);
    });

    test('returns unavailable and kills the tunnel when it never becomes ready', () async {
      stubTunnel(ready: false, name: '');
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.unavailable.code);
      // The tunnel handle is still killed on the failure path.
      expect(tunnelKilled, isTrue);
      // Never proceeds to the build.
      expect(scripted.ranContaining('build android'), isFalse);
    });

    test('returns software (not a crash) when the tunnel fails to start', () async {
      // The tunnel start is now inside run()'s try, so a ProcessException
      // (e.g. a missing LT_BIN) is caught and surfaced as a clean exit code.
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      when(
        () => ltTunnel.start(
          ltBin: any(named: 'ltBin'),
          ltUser: any(named: 'ltUser'),
          ltKey: any(named: 'ltKey'),
          tunnelName: any(named: 'tunnelName'),
        ),
      ).thenThrow(const ProcessException('lt', [], 'No such file'));
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('LambdaTest Android E2E failed')))).called(1);
      // The tunnel was never assigned, so the null-guarded finally must not
      // dereference it (no kill, no crash).
      expect(tunnelKilled, isFalse);
      expect(scripted.ranContaining('build android'), isFalse);
    });

    test('returns software error when patrol build fails', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      scripted.route('build android', exitCode: 1);
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('patrol build android failed')))).called(1);
      // The tunnel is killed even when an early step fails.
      expect(tunnelKilled, isTrue);
    });

    test('shows a spinner while patrol build output stays silent', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();

      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: 'patrol_test/patrol_login_test.dart',
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().progress('Building Android APKs with Patrol')).called(1);
      verify(
        () => getDep<MplatrolShell>().runArgs(
          'env',
          any(
              that: containsAllInOrder([
            'ORG_GRADLE_PROJECT_disable-abi-filtering=true',
            '/fixture/pub-cache/bin/fvm',
            'dart',
            'build',
          ])),
          workingDirectory: appDir.path,
          throwOnError: false,
          silent: true,
          forceVerbose: any(named: 'forceVerbose'),
          quietBuild: any(named: 'quietBuild'),
        ),
      ).called(1);
    });

    test('buildAndroid falls back to the platform environment', () async {
      stubFileSystem();
      stubHappyShell();
      when(() => getDep<PlatformWrapper>().environment).thenReturn(_fullEnv());

      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: 'patrol_test/patrol_login_test.dart',
      );

      expect(exitCode, ExitCode.success.code);
      expect(scripted.ranContaining('--dart-define=E2E_ENVIRONMENT=Dev'), isTrue);
    });

    test('buildAndroid returns software when patrol build throws', () async {
      stubFileSystem();
      stubHappyShell();
      when(
        () => getDep<MplatrolShell>().runArgs(
          'env',
          any(
              that: containsAllInOrder([
            'ORG_GRADLE_PROJECT_disable-abi-filtering=true',
            '/fixture/pub-cache/bin/fvm',
            'dart',
            'build',
          ])),
          workingDirectory: appDir.path,
          throwOnError: false,
          silent: true,
          forceVerbose: any(named: 'forceVerbose'),
          quietBuild: any(named: 'quietBuild'),
        ),
      ).thenThrow(Exception('boom'));

      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: 'patrol_test/patrol_login_test.dart',
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('patrol build android failed:')))).called(1);
    });

    test('includes sdk in the log message when sdk is non-null', () async {
      stubFileSystem();
      stubHappyShell();
      final logger = getDep<MplatrolLogger>();

      // 'login' is a token in the fixture file 'patrol_login_test.dart', so
      // discovery succeeds and the sdk parameter reaches the log message.
      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: null,
        sdk: 'login',
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(() => logger.info(any(that: contains('(sdk: login)')))).called(1);
    });

    test('retries patrol build once on a transient dependency failure', () async {
      stubFileSystem();
      stubHappyShell();
      scripted.routeSequence('build android', [
        ProcessResultX(
          pid: 1,
          exitCode: 1,
          stdout: "Could not GET 'https://feeds.example.com/m.xml'. "
              'Received status code 504 from server: Gateway Timeout',
          stderr: '',
        ),
        ProcessResultX(pid: 1, exitCode: 0, stdout: '', stderr: ''),
      ]);
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: 'patrol_test/patrol_login_test.dart',
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(() => logger.warn(any(that: contains('[build-retry]')))).called(1);
    });

    test('gives up after exhausting the build-retry budget', () async {
      stubFileSystem();
      stubHappyShell();
      scripted.route(
        'build android',
        stdout: 'Repository maven2 is disabled due to earlier error',
        exitCode: 1,
      );
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: 'patrol_test/patrol_login_test.dart',
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      // Two retries after the first attempt (the _buildRetryAttempts budget).
      verify(() => logger.warn(any(that: contains('[build-retry]')))).called(2);
    });

    test('does not retry a real (non-transient) build failure', () async {
      stubFileSystem();
      stubHappyShell();
      scripted.route(
        'build android',
        stdout: 'lib/main.dart:3:1: Error: compile failure',
        exitCode: 1,
      );
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().buildAndroid(
        repo: appDir.path,
        target: 'patrol_test/patrol_login_test.dart',
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verifyNever(() => logger.warn(any(that: contains('[build-retry]'))));
    });

    test('returns software error when the app APK is not produced', () async {
      stubFileSystem(appApk: false);
      stubHappyShell();
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('App APK not produced')))).called(1);
    });

    test('returns software error when the test APK is not produced', () async {
      stubFileSystem(testApk: false);
      stubHappyShell();
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('Test APK not produced')))).called(1);
    });

    test('returns software error when the app upload has no app_url', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.appUploadBody = '{"error":"bad gateway"}';
      httpStubs.install();
      final http = getDep<LtHttp>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      // The test APK uploads at the same time as the app APK, once.
      verify(
        () => http.postMultipart(
          any(),
          headers: any(named: 'headers'),
          fields: any(named: 'fields'),
          filePath: any(named: 'filePath', that: equals(testApkPath())),
          onAnswered: any(named: 'onAnswered'),
        ),
      ).called(1);
      verify(() => getDep<MplatrolLogger>()
              .err(any(that: contains('LambdaTest upload of PatrolAndroid-abc1234-app failed after 6 attempts'))))
          .called(1);
      verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson lambdaTestUpload (observed 1): '))))
          .called(1);
    });

    test('retries the test APK upload then fails after the cap', () async {
      stubFileSystem();
      stubHappyShell();
      // Every direct upload attempt returns a non-app_url body.
      httpStubs.testUploadBody = '502 Bad Gateway';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('failed after 6 attempts')))).called(1);
      final testUploads = httpStubs.directUploads.where((invocation) {
        return invocation.namedArguments[#filePath] == testApkPath();
      });
      // 6 attempts, then 6 more in the one infrastructure retry.
      expect(testUploads.length, 12);
    });

    test('succeeds when the test APK upload recovers on a later attempt', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      // First two attempts fail, third returns app_url. Re-install a custom
      // answer for the direct-upload route so it varies per call.
      var attempts = 0;
      final http = getDep<LtHttp>();
      when(
        () => http.postMultipart(
          any(),
          headers: any(named: 'headers'),
          fields: any(named: 'fields'),
          filePath: any(named: 'filePath', that: isNotNull),
          onAnswered: any(named: 'onAnswered'),
        ),
      ).thenAnswer((invocation) async {
        final filePath = invocation.namedArguments[#filePath] as String;
        if (filePath == appApkPath()) {
          return _response('{"app_url":"lt://APP_APP"}', 200);
        }
        attempts++;
        return _response(attempts < 3 ? 'transient error' : '{"app_url":"lt://APP_TEST"}', 200);
      });

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      expect(attempts, 3);
    });

    test('returns software error when the espresso response is not JSON', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.espressoBody = '<html>502 Bad Gateway</html>';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('not valid JSON')))).called(1);
    });

    test('returns software error when the espresso response has no buildId', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.espressoBody = '{"message":"queued"}';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('No buildId')))).called(1);
    });

    test('returns software error when buildId is an empty list', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.espressoBody = '{"buildId":[]}';
      httpStubs.install();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
    });

    test('extracts buildId from a non-empty list and uses it downstream', () async {
      stubFileSystem();
      stubHappyShell();
      // buildId arrives as a list; the poll must query that id.
      httpStubs.espressoBody = '{"buildId":["build-777"]}';
      httpStubs.install();
      final http = getDep<LtHttp>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(
        () => http.get(
          any(that: contains('/builds/build-777')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('retries a transient tunnel liveness response from the trigger', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final http = getDep<LtHttp>();
      var triggerCalls = 0;
      when(
        () => http.postJson(
          any(that: contains('espresso/build')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async {
        triggerCalls += 1;
        if (triggerCalls == 1) {
          return _response('{"message":"Either tunnel is not running or disconnected"}', 200);
        }
        return _response('{"buildId":"build-123"}', 200);
      });

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      expect(triggerCalls, 2);
      verify(
        () => http.get(
          any(that: contains('/builds/build-123')),
          headers: any(named: 'headers'),
        ),
      ).called(1);
    });

    test('dedupes repeated transient trigger readiness messages', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final http = getDep<LtHttp>();
      final logger = getDep<MplatrolLogger>();
      var triggerCalls = 0;
      when(
        () => http.postJson(
          any(that: contains('espresso/build')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async {
        triggerCalls += 1;
        if (triggerCalls < 3) {
          return _response('{"message":["Either tunnel is not running","or disconnected"]}', 200);
        }
        return _response('{"buildId":"build-123"}', 200);
      });

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      expect(triggerCalls, 3);
      verify(() => logger.warn(any(that: contains('LambdaTest Android trigger not ready yet')))).called(1);
      verify(() => logger.detail('LambdaTest Android trigger still not ready.')).called(1);
    });

    test('returns software error when the build status is failed', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.pollBody = '{"data":{"status_ind":"failed"}}';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('status "failed"')))).called(1);
    });

    test('passes when the build status is failed but all sessions passed', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.pollBody = '{"data":{"status_ind":"failed"}}';
      httpStubs.sessionsBody = '''
{
  "data": [
    {"status_ind": "passed", "session_id": "session-1"}
  ]
}
''';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(() => logger.warn(any(that: contains('build build-123 reported failed, but all 1')))).called(1);
      verify(() => logger.success(any(that: contains('build-123')))).called(1);
      verifyNever(() => logger.err(any(that: contains('did not pass'))));
    });

    test('treats a completed build status as a pass', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.pollBody = '{"data":{"status_ind":"completed"}}';
      httpStubs.install();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
    });

    test('treats idle_timeout as terminal and fails the run', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.pollBody = '{"data":{"status_ind":"idle_timeout"}}';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('status "idle_timeout"')))).called(1);
    });

    test('keeps polling past a non-terminal status until terminal', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      var polls = 0;
      final http = getDep<LtHttp>();
      when(
        () => http.get(
          any(),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((_) async {
        polls++;
        final body = polls < 2 ? '{"data":{"status_ind":"running"}}' : '{"data":{"status_ind":"passed"}}';
        return _response(body, 200);
      });

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      expect(polls, 2);
    });

    test(
        'sizes the poll budget from queueTimeout + idleTimeout when the poll '
        'delay is non-zero', () async {
      // A non-zero poll delay drives the budget through the real
      // attempts = ceil((queueTimeout + idleTimeout + margin) / delay) path
      // (not the zero-delay floor). The happy-path poll is terminal on the
      // first call, so it returns before any wait actually elapses.
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();

      final exitCode = await _runner(pollDelay: const Duration(seconds: 1)).run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
    });

    test('fails when the build poll never reaches a terminal status', () async {
      stubFileSystem();
      stubHappyShell();
      // A non-JSON body keeps status "?" forever; the loop exhausts its
      // attempts and the run fails because "?" is not "passed".
      httpStubs.pollBody = 'gateway timeout';
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('status "?"')))).called(1);
    });

    test('returns software (not a crash) when an LtHttp call throws', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      // A network exception from the app upload must be caught by run()'s
      // generic catch and surfaced as a clean software exit, not a crash.
      final http = getDep<LtHttp>();
      when(
        () => http.postMultipart(
          any(),
          headers: any(named: 'headers'),
          fields: any(named: 'fields'),
          filePath: any(named: 'filePath', that: equals(appApkPath())),
          onAnswered: any(named: 'onAnswered'),
        ),
      ).thenThrow(Exception('network'));
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('LambdaTest Android E2E failed')))).called(1);
      // The tunnel is still torn down on the thrown path.
      expect(tunnelKilled, isTrue);
    });

    test('returns software when the poll GET keeps throwing', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      // Every poll throws; _pollBuild catches each (status stays "?") and the
      // run fails after exhausting attempts, never crashing.
      final http = getDep<LtHttp>();
      when(
        () => http.get(
          any(),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenThrow(Exception('timeout'));
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.software.code);
      verify(() => logger.err(any(that: contains('status "?"')))).called(1);
    });

    test('a normal run caches the uploaded app/test ids', () async {
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      when(
        () => fileSystem.writeAsStringSync(
          filePath: any(named: 'filePath'),
          newContent: any(named: 'newContent'),
          flush: any(named: 'flush'),
        ),
      ).thenReturn(null);

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(
        () => fileSystem.writeAsStringSync(
          filePath: any(named: 'filePath', that: endsWith('lt-last.json')),
          newContent: any(named: 'newContent', that: contains('lt://APP_APP')),
          flush: any(named: 'flush'),
        ),
      ).called(1);
    });
  });

  group('LtAndroidRunner.run reuse-last', () {
    test('rejects a changed compiled JUnit timeout', () async {
      when(() => fileSystem.fileExistsSync(cachePath())).thenReturn(true);
      when(() => fileSystem.readAsStringSync(cachePath())).thenReturn(jsonEncode({
        'app': 'lt://APP_ID',
        'test': 'lt://TEST_ID',
        'nativeGenerator': androidPatrolGeneratorIdentity(),
      }));
      stubHappyShell();
      httpStubs.install();
      final result = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv()..[e2eTestTimeoutMsEnv] = '600000',
        reuseLast: true,
      );
      expect(result, ExitCode.usage.code);
      expect(tunnelKilled, isTrue);
    });
    for (final identity in [null, 'previous-templatrole-digest']) {
      test('rejects missing or stale native identity: $identity', () async {
        when(() => fileSystem.fileExistsSync(cachePath())).thenReturn(true);
        when(() => fileSystem.readAsStringSync(cachePath())).thenReturn(jsonEncode({
          'app': 'lt://APP_ID',
          'test': 'lt://TEST_ID',
          if (identity != null) 'nativeGenerator': identity,
        }));
        stubHappyShell();
        httpStubs.install();
        final result = await _runner().run(
          target: 'patrol_test/patrol_login_test.dart',
          devices: const ['Galaxy S23-13'],
          idleTimeoutSeconds: 900,
          env: _fullEnv(),
          reuseLast: true,
        );
        expect(result, ExitCode.usage.code);
        expect(scripted.ranContaining('build android'), isFalse);
        expect(tunnelKilled, isTrue);
        verifyNever(() => getDep<LtHttp>().postJson(
              any(that: contains('espresso/build')),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            ));
      });
    }
    test('refuses legacy cached ids without SDK receipt', () async {
      when(() => fileSystem.fileExistsSync(cachePath())).thenReturn(true);
      when(() => fileSystem.readAsStringSync(cachePath())).thenReturn(jsonEncode({
        'app': 'lt://APP_ID',
        'test': 'lt://TEST_ID',
        'nativeGenerator': androidPatrolGeneratorIdentity(),
      }));
      stubHappyShell();
      httpStubs.install();
      final http = getDep<LtHttp>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
        reuseLast: true,
      );

      expect(exitCode, ExitCode.usage.code);
      // No build and no uploads — it jumps straight to trigger + poll.
      expect(scripted.ranContaining('build android'), isFalse);
      verifyNever(
        () => http.putFile(
          any(),
          headers: any(named: 'headers'),
          filePath: any(named: 'filePath'),
        ),
      );
      verifyNever(
        () => http.postMultipart(
          any(),
          headers: any(named: 'headers'),
          fields: any(named: 'fields'),
          filePath: any(named: 'filePath'),
          onAnswered: any(named: 'onAnswered'),
        ),
      );
      verifyNever(() => http.postJson(any(that: contains('espresso/build')),
          headers: any(named: 'headers'), body: any(named: 'body')));
    });

    test('returns usage and logs when there is no cached build', () async {
      when(() => fileSystem.fileExistsSync(cachePath())).thenReturn(false);
      stubHappyShell();
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
        reuseLast: true,
      );

      expect(exitCode, ExitCode.usage.code);
      verify(() => logger.err(any(that: contains('reuse-last')))).called(1);
      expect(scripted.ranContaining('build android'), isFalse);
    });

    test('returns usage when the cached build is incomplete', () async {
      when(() => fileSystem.fileExistsSync(cachePath())).thenReturn(true);
      when(() => fileSystem.readAsStringSync(cachePath())).thenReturn('{}');
      stubHappyShell();
      httpStubs.install();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
        reuseLast: true,
      );

      expect(exitCode, ExitCode.usage.code);
      expect(scripted.ranContaining('build android'), isFalse);
    });
  });

  group('LtAndroidRunner.run with targetRegex', () {
    test('generates a filtered bundle target and logs the run target', () async {
      // targetRegex is non-null → retargetPatrolTestBundle is called (covers
      // lines 357, 365-366) and the logger.info interpolates targetRegex (380-381).
      stubFileSystem();
      stubHappyShell();
      httpStubs.install();
      final logger = getDep<MplatrolLogger>();

      final exitCode = await _runner().run(
        target: 'patrol_test/patrol_login_test.dart',
        targetRegex: 'sample',
        devices: const ['Galaxy S23-13'],
        idleTimeoutSeconds: 900,
        env: _fullEnv(),
      );

      expect(exitCode, ExitCode.success.code);
      verify(
        () => logger.info(
          any(that: contains('[bundle] LambdaTest Android generated run target')),
        ),
      ).called(1);
      verify(
        () => logger.info(
          any(that: contains('target-regex: sample')),
        ),
      ).called(1);
    });
  });
}

const _sdkRegistry = 'class GeneratedPluginRegistrant {\n'
    '  void register() { new vendor.NativeSdkPlugin(); }\n}\n';

void _flutterPropertyWriterCases({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() stubFiles,
  required void Function() stubShell,
}) {
  for (final drift in [
    'none',
    'sdk.dir',
    'flutter.sdk',
    'flutter.versionName',
    'flutter.versionCode',
    'flutter.buildMode',
    'custom.control',
    'pubspec.yaml'
  ]) {
    test('Flutter source-derived version rewrite with $drift drift remains guarded', () async {
      stubFiles();
      stubShell();
      httpStubs().install();
      final manifest = File(p.join(repo().path, 'pubspec.yaml'));
      manifest.writeAsStringSync('${manifest.readAsStringSync()}version: 1.2.0\n');
      final properties = File(p.join(repo().path, 'android/local.properties'));
      properties.parent.createSync(recursive: true);
      properties.writeAsStringSync('sdk.dir=/fixture/sdk\nflutter.sdk=/fixture/flutter\n'
          'flutter.buildMode=release\nflutter.versionName=old\nflutter.versionCode=999\n'
          'custom.control=retained');
      const expected = 'sdk.dir=/fixture/sdk\nflutter.sdk=/fixture/flutter\n'
          'flutter.buildMode=debug\nflutter.versionName=1.2.0\ncustom.control=retained';
      scripted().onCommand = (command) {
        if (!command.contains('build android')) {
          return;
        }
        var written = expected;
        if (drift == 'pubspec.yaml') {
          manifest.writeAsStringSync(manifest.readAsStringSync().replaceFirst('1.2.0', '2.0.0'));
        } else if (drift == 'flutter.versionCode') {
          written = '$written\nflutter.versionCode=17';
        } else if (drift != 'none') {
          written = written.replaceFirst(RegExp('$drift=[^\\n]*'), '$drift=changed');
        }
        properties.writeAsStringSync(written);
      };
      final artifacts = await _produceSdk(repo());
      if (drift == 'none') {
        expect(artifacts, isNotNull);
        expect(httpStubs().directUploads, hasLength(2));
        expect(await _produceSdk(repo()), isNotNull);
        expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(1));
        expect(httpStubs().directUploads, hasLength(2));
      } else {
        expect(artifacts, isNull);
        expect(httpStubs().directUploads, isEmpty);
        expect(scripted().ranContaining('build android'), isTrue);
      }
    });
  }
}

const _developmentRegistry = 'class GeneratedPluginRegistrant {\n'
    '  void register() {\n'
    '    new vendor.NativeSdkPlugin();\n'
    '    new IntegrationTestPlugin();\n'
    '    new PatrolPlugin();\n'
    '  }\n}\n';

void _registrantAndLauncherCases({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() stubFiles,
  required void Function() stubShell,
}) {
  for (final scenario in ['release rewrite', 'unchanged debug', 'SDK plugin changed', 'local mode rewrite']) {
    test('compiled registry $scenario preserves guarded producer identity', () async {
      stubFiles();
      stubShell();
      httpStubs().install();
      final registry =
          File(p.join(repo().path, 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'));
      registry
        ..createSync(recursive: true)
        ..writeAsStringSync(_developmentRegistry);
      final properties = File(p.join(repo().path, 'android/local.properties'));
      if (scenario == 'local mode rewrite') {
        properties.writeAsStringSync('sdk.dir=/fixture/sdk\nflutter.buildMode=release');
      }
      scripted().onCommand = (command) {
        if (command.contains('build android')) {
          if (scenario == 'local mode rewrite') {
            properties.writeAsStringSync('sdk.dir=/fixture/sdk\nflutter.buildMode=debug');
          }
          if (scenario == 'release rewrite') {
            registry.writeAsStringSync(_sdkRegistry);
          }
          if (scenario == 'SDK plugin changed') {
            registry.writeAsStringSync(
                _developmentRegistry.replaceFirst('vendor.NativeSdkPlugin', 'vendor.DifferentSdkPlugin'));
          }
        }
      };
      final artifacts = await _produceSdk(repo());
      if (scenario == 'unchanged debug' || scenario == 'local mode rewrite') {
        expect(artifacts, isNotNull);
        expect(httpStubs().directUploads, hasLength(2));
        expect(await _produceSdk(repo(), reuse: true), isNotNull);
        expect(httpStubs().directUploads, hasLength(2));
      } else {
        expect(artifacts, isNull);
        expect(httpStubs().directUploads, isEmpty);
        final data =
            jsonDecode(File(p.join(repo().path, '.mplatrol/android_sdk_build_input_drift.json')).readAsStringSync())
                as Map;
        final changed = data['changed'] as List;
        expect(changed.map((dynamic item) => item['input']),
            contains('app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'));
        expect(jsonEncode(data), isNot(contains('vendor.NativeSdkPlugin')));
        expect(jsonEncode(data), isNot(contains('test-auth')));
      }
      final build = scripted().ranScripts.singleWhere((cmd) => cmd.contains('build android'));
      expect(build, contains('.mplatrol/patched_packages/patrol_cli/bin/main.dart'));
      expect(build, isNot(contains('PUB_CACHE=')));
      expect(build, isNot(contains(' patrol ')));
    });
  }
  test('missing patched CLI refuses instead of falling back to global Patrol', () async {
    stubFiles();
    when(() => getDep<LocalRunner>().preparePatrolCliCommand(any())).thenAnswer((_) async => null);
    expect(await _produceSdk(repo()), isNull);
    expect(scripted().ranContaining('build android'), isFalse);
  });
}

void _sdkFixture(Directory repo) {
  final files = <String, String>{
    'pubspec.yaml': 'name: app\npatrol:\n  test_directory: patrol_test\n',
    'android/app/build.gradle': 'android { defaultConfig {\napplicationId "com.example.tenant.staging"\n} }',
    'pubspec.lock': 'packages: {}',
    '.dart_tool/package_config.json': '{"configVersion":2,"packages":[]}',
    '.flutter-plugins-dependencies': '{"plugins":{"android":[],"ios":[]}}',
    'lib/core/feature_registrations.dart': '// BEGIN MPLATROL TAG: vendor_registration\n'
        '// vendor.SdkRegistration();\n'
        '// END MPLATROL TAG: vendor_registration\n',
    'patrol_test/sdk_requirements.json': jsonEncode({
      'schema': 1,
      'capabilities': {
        'vendor': {
          'packages': ['vendor'],
          'nativePlugins': {
            'android': ['vendor']
          },
          'registrations': [
            {
              'source': 'lib/core/feature_registrations.dart',
              'tag': 'vendor_registration',
              'symbol': 'vendor.SdkRegistration()',
            }
          ],
        },
      },
      'unresolvedRegistrations': [],
      'tests': [
        _sdkDeclaration('patrol_login_test', ['sample test'])
      ],
    }),
  };
  for (final entry in files.entries) {
    File(p.join(repo.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
}

Map<String, Object?> _sdkDeclaration(String file, List<String> descriptions, {bool sdk = false}) => {
      'file': 'patrol_test/$file.dart',
      'descriptions': descriptions,
      'platforms': ['android', 'ios'],
      'coverage': 'journey',
      'requires': sdk
          ? [
              ['vendor']
            ]
          : [],
    };

void _compiledFixtureApks(Directory repo) {
  for (final sourceSet in ['main', 'androidTest']) {
    final asset = File(p.join(repo.path, 'android/app/src', sourceSet, 'assets', patrolSdkArtifactAsset));
    if (!asset.existsSync()) {
      continue;
    }
    final contents = asset.readAsBytesSync();
    final archive = Archive()..addFile(ArchiveFile('assets/$patrolSdkArtifactAsset', contents.length, contents));
    File(sourceSet == 'main' ? LtAndroidRunner.appApkPath(repo.path) : LtAndroidRunner.testApkPath(repo.path))
      ..createSync(recursive: true)
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }
}

Future<AndroidLtArtifacts?> _produceSdk(Directory repo,
        {bool reuse = false, String? target, String? regex, String? sdk, Map<String, String>? env}) =>
    _runner().buildUploadAndroid(
        repo: repo.path,
        target: target,
        targetRegex: regex,
        sdk: sdk,
        buildName: 'prepared-android',
        auth: 'test-auth',
        env: env ?? _fullEnv(),
        reuseLast: reuse);

void _unsupportedSdk(Directory repo) {
  File(p.join(repo.path, 'patrol_test/neutral_test.dart')).writeAsStringSync("patrolTest('SDK journey');");
  final file = File(p.join(repo.path, 'patrol_test/sdk_requirements.json'));
  final data = jsonDecode(file.readAsStringSync()) as Map;
  (data['tests'] as List).add(_sdkDeclaration('neutral_test', ['SDK journey'], sdk: true));
  file.writeAsStringSync(jsonEncode(data));
}

void _sdkProducerCases(
    {required Directory Function() repo,
    required _ScriptedShell Function() scripted,
    required _HttpStubs Function() httpStubs,
    required void Function() stubFiles,
    required void Function() stubShell}) {
  void setup() {
    stubFiles();
    stubShell();
    httpStubs().install();
  }

  test('SDK producer shares plan between Dart/native/artifact selection', () async {
    setup();
    final root = repo();
    _unsupportedSdk(root);
    final artifacts = await _produceSdk(root);
    expect(artifacts, isNotNull);
    expect(artifacts!.selection!.selectedCount, 1);
    expect(artifacts.selection!.excludedCount, 1);
    expect(artifacts.selectedNativeTests, {
      for (final test in artifacts.selection!.files.single.tests) 'mplatrol.e2e.PatrolLoginTest/${test.method}',
    });
    final bundle = File(p.join(root.path, 'patrol_test/mplatrol_filtered_test.dart')).readAsStringSync();
    expect(bundle, contains('patrol_login_test.main()'));
    expect(bundle, isNot(contains('neutral_test')));
    final native = Directory(p.join(root.path, 'android/app/src/androidTest/java/mplatrol/e2e'));
    expect(File(p.join(native.path, 'NeutralTest.java')).existsSync(), isFalse);
    expect(
        File(p.join(native.path, 'PatrolLoginTest.java')).readAsStringSync(), contains('runDartTest("sample test")'));
    final cache = jsonDecode(File(p.join(root.path, 'build/app/outputs/lt-last.json')).readAsStringSync()) as Map;
    expect((cache['sdkReceipt'] as Map)['manifest'], isA<Map>());
  });
  test('unsupported SDK target refuses before build/upload/UI scheduling', () async {
    setup();
    _unsupportedSdk(repo());
    expect(await _produceSdk(repo(), target: 'patrol_test/neutral_test.dart'), isNull);
    expect(scripted().ranContaining('build android'), isFalse);
    expect(httpStubs().directUploads, isEmpty);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('No eligible')))).called(1);
  });
  test('supported fresh pair is reusable without build or upload', () async {
    setup();
    final fresh = await _produceSdk(repo());
    expect(fresh, isNotNull);
    final builds = scripted().ranScripts.length;
    final uploads = httpStubs().directUploads.length;
    final reused = await _produceSdk(repo(), reuse: true);
    expect(reused!.selectedNativeTests, fresh!.selectedNativeTests);
    expect(reused.appId, fresh.appId);
    expect(scripted().ranScripts.length, builds);
    expect(httpStubs().directUploads.length, uploads);
  });
  _sdkInputFailureCases(repo: repo, scripted: scripted, httpStubs: httpStubs, setup: setup);
}

void _sdkInputFailureCases(
    {required Directory Function() repo,
    required _ScriptedShell Function() scripted,
    required _HttpStubs Function() httpStubs,
    required void Function() setup}) {
  for (final path in ['patrol_test/sdk_requirements.json', '.flutter-plugins-dependencies']) {
    test('missing $path refuses before build/upload', () async {
      setup();
      File(p.join(repo().path, path)).deleteSync();
      expect(await _produceSdk(repo()), isNull);
      expect(scripted().ranContaining('build android'), isFalse);
      expect(httpStubs().directUploads, isEmpty);
    });
  }
  test('unknown active registration fails closed rather than excluding variant', () async {
    setup();
    final file = File(p.join(repo().path, 'patrol_test/sdk_requirements.json'));
    final data = jsonDecode(file.readAsStringSync()) as Map;
    data['unresolvedRegistrations'] = [
      {
        'source': 'lib/core/feature_registrations.dart',
        'tag': 'vendor_registration',
        'symbol': 'vendor.SdkRegistration()',
        'reason': 'unestablished native metadata',
      }
    ];
    file.writeAsStringSync(jsonEncode(data));
    final source = File(p.join(repo().path, 'lib/core/feature_registrations.dart'));
    source.writeAsStringSync(source.readAsStringSync().replaceAll('// vendor.', 'vendor.'));
    expect(await _produceSdk(repo()), isNull);
    expect(httpStubs().directUploads, isEmpty);
  });
  test('partial-file regex remains explicit failure, not hidden superset', () async {
    setup();
    File(p.join(repo().path, 'patrol_test/patrol_login_test.dart'))
        .writeAsStringSync("patrolTest('sample test'); patrolTest('other test');");
    final file = File(p.join(repo().path, 'patrol_test/sdk_requirements.json'));
    final data = jsonDecode(file.readAsStringSync()) as Map;
    data['tests'] = [
      _sdkDeclaration('patrol_login_test', ['sample test', 'other test'])
    ];
    file.writeAsStringSync(jsonEncode(data));
    expect(await _produceSdk(repo(), regex: '^sample test\$'), isNull);
    expect(scripted().ranContaining('build android'), isFalse);
    expect(httpStubs().directUploads, isEmpty);
  });
  test('source changed during build refuses compiled metadata before upload', () async {
    setup();
    scripted().onCommand = (command) {
      if (command.contains('build android')) {
        File(p.join(repo().path, 'lib/new_source.dart')).writeAsStringSync('changed');
      }
    };
    expect(await _produceSdk(repo()), isNull);
    expect(httpStubs().directUploads, isEmpty);
  });
  test('source changed during upload refuses to record the uploaded pair', () async {
    setup();
    when(
      () => httpStubs().http.postMultipart(
            any(),
            headers: any(named: 'headers'),
            fields: any(named: 'fields'),
            filePath: any(named: 'filePath', that: isNotNull),
            onAnswered: any(named: 'onAnswered'),
          ),
    ).thenAnswer((invocation) async {
      httpStubs().directUploads.add(invocation);
      File(p.join(repo().path, 'lib/new_source.dart')).writeAsStringSync('changed during upload');
      return _response('{"app_url":"lt://APP_ANY"}', 200);
    });
    expect(await _produceSdk(repo()), isNull);
    expect(httpStubs().directUploads, hasLength(2));
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('Android build inputs changed during upload'))))
        .called(1);
    expect(File(p.join(repo().path, 'build/app/outputs/lt-last.json')).existsSync(), isFalse);
  });
  test('changed actual environment refuses cached uploaded pair', () async {
    setup();
    expect(await _produceSdk(repo()), isNotNull);
    final uploads = httpStubs().directUploads.length;
    final defines = File(p.join(repo().path, defaultE2eDartDefineFile));
    defines.writeAsStringSync('{"E2E_ENVIRONMENT":"Staging"}');
    expect(await _produceSdk(repo(), reuse: true), isNull);
    expect(httpStubs().directUploads.length, uploads);
  });
  test('refreshed SS/process and unused package docs preserve uploaded reuse', () async {
    setup();
    final fresh = await _produceSdk(repo());
    expect(fresh, isNotNull);
    final uploads = httpStubs().directUploads.length;
    final env = _fullEnv()
      ..addAll({
        'OPERATIONAL_TOKEN': 'fixture-refreshed-token',
        'PWD': '/different/path',
        'SHLVL': '7',
        'MPLATROL_E2E_CREDENTIALS_PORT': '12345',
      });
    File(p.join(repo().path, 'README.md')).writeAsStringSync('unrelated documentation');
    final reused = await _produceSdk(repo(), reuse: true, env: env);
    expect(reused, isNotNull);
    expect(reused!.appId, fresh!.appId);
    expect(httpStubs().directUploads.length, uploads);
  });
  test('changed Android project inputs refuse cached uploaded pair', () async {
    setup();
    expect(await _produceSdk(repo()), isNotNull);
    File(p.join(repo().path, 'android/settings.gradle')).writeAsStringSync('// changed input');
    expect(await _produceSdk(repo(), reuse: true), isNull);
  });
}

void _automaticReuseCases({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() stubFiles,
  required void Function() stubShell,
}) {
  void setup() {
    stubFiles();
    stubShell();
    httpStubs().install();
  }

  test('identical automatic second call skips compilation and both uploads', () async {
    setup();
    final fresh = await _produceSdk(repo());
    final builds = scripted().ranScripts.length;
    final reused = await _produceSdk(repo());
    expect(fresh, isNotNull);
    expect(reused!.appId, fresh!.appId);
    expect(reused.testSuiteAppId, fresh.testSuiteAppId);
    expect(reused.selectedNativeTests, fresh.selectedNativeTests);
    expect(scripted().ranScripts.length, builds);
    expect(httpStubs().directUploads, hasLength(2));
    verify(() => getDep<MplatrolLogger>().info(any(that: contains('[artifact-auto-reuse] app=')))).called(1);
  });
  test('failed native runs reuse artifacts but trigger and evaluate each new job', () async {
    setup();
    httpStubs().pollBody = '{"data":{"status_ind":"failed"}}';
    Future<int> run() =>
        _runner().run(target: null, devices: const ['Galaxy S23-13'], idleTimeoutSeconds: 900, env: _fullEnv());
    expect(await run(), ExitCode.software.code);
    httpStubs().espressoBody = '{"buildId":"fresh-job-456"}';
    expect(await run(), ExitCode.software.code);
    expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(1));
    expect(httpStubs().directUploads, hasLength(2));
    verify(() => getDep<LtHttp>().postJson(any(that: contains('espresso/build')),
        headers: any(named: 'headers'), body: any(named: 'body'))).called(2);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('build fresh-job-456, status "failed"')))).called(1);
  });
  test('prepared namespace drift refuses explicit reuse and automatically recompiles', () async {
    setup();
    expect(await _produceSdk(repo()), isNotNull);
    File(p.join(repo().path, 'android/app/build.gradle'))
        .writeAsStringSync('android { defaultConfig {\napplicationId "com.example.newtenant.staging"\n} }');
    expect(await _produceSdk(repo(), reuse: true), isNull);
    expect(httpStubs().directUploads, hasLength(2));
    expect(await _produceSdk(repo()), isNotNull);
    final builds = scripted().ranScripts.where((cmd) => cmd.contains('build android')).toList();
    expect(builds, hasLength(2));
    expect(builds.last, contains('--package-name com.example.newtenant.staging'));
    expect(httpStubs().directUploads, hasLength(4));
  });
  for (final selected in [false, true]) {
    test('unresolved package refuses before compilation/upload selected=$selected', () async {
      setup();
      File(p.join(repo().path, 'android/app/build.gradle')).deleteSync();
      if (selected) {
        expect(await _produceSdk(repo()), isNull);
      } else {
        expect(await _runner().buildAndroid(repo: repo().path, target: null, env: _fullEnv()), ExitCode.config.code);
      }
      expect(scripted().ranContaining('build android'), isFalse);
      expect(httpStubs().directUploads, isEmpty);
    });
  }
  test('nonselected whole-suite producer also passes prepared package', () async {
    setup();
    await _runner().buildAndroid(repo: repo().path, target: null, env: _fullEnv());
    expect(scripted().ranScripts.singleWhere((cmd) => cmd.contains('build android')),
        contains('--package-name com.example.tenant.staging'));
  });
  _automaticDriftCases(repo: repo, scripted: scripted, httpStubs: httpStubs, setup: setup);
  _automaticInvalidCases(repo: repo, scripted: scripted, httpStubs: httpStubs, setup: setup);
  _sharedCacheCases(repo: repo, scripted: scripted, httpStubs: httpStubs, setup: setup);
}

void _sharedCacheCases({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() setup,
}) {
  late Directory home;
  List<File> records() => [
        ...Directory(p.join(home.path, '.mplatrol', 'lt-artifacts')).listSync().whereType<File>(),
      ];
  void setupWithHome() {
    setup();
    home = Directory.systemTemp.createTempSync('mplatrol_home');
    addTearDown(() => home.deleteSync(recursive: true));
    when(() => getDep<PlatformWrapper>().environment).thenReturn({..._fullEnv(), 'HOME': home.path});
  }

  void forgetLaneUpload() => File(p.join(repo().path, 'build/app/outputs/lt-last.json')).deleteSync();

  test('a lane whose own record is gone reuses the per-user record of the same build', () async {
    setupWithHome();
    final fresh = await _produceSdk(repo());
    expect(records(), hasLength(1));
    forgetLaneUpload();

    final reused = await _produceSdk(repo());
    expect(reused!.appId, fresh!.appId);
    expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(1));
    expect(httpStubs().directUploads, hasLength(2));
    verify(() => getDep<MplatrolLogger>().info(any(
        that: startsWith('[artifact-cache] recorded the Android upload '
            'for build identity ')))).called(1);
    verify(() => getDep<MplatrolLogger>().info(any(
        that: allOf(startsWith('[artifact-cache] hit: build identity '),
            contains('skipping the Android build and upload'))))).called(1);
  });

  test('a lane that generated another runner reuses the record once it regenerates this one', () async {
    setupWithHome();
    expect(await _produceSdk(repo()), isNotNull);
    forgetLaneUpload();
    final runners = Directory(p.join(repo().path, 'android/app/src/androidTest/java'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.java'))
        .toList();
    expect(runners, isNotEmpty);
    for (final runner in runners) {
      runner.writeAsStringSync('// another tenant selection');
    }

    expect(await _produceSdk(repo()), isNotNull);
    expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(1));
    expect(httpStubs().directUploads, hasLength(2));
    verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('[artifact-cache] hit: ')))).called(1);
  });

  test('an old per-user record is a miss with its age', () async {
    setupWithHome();
    expect(await _produceSdk(repo()), isNotNull);
    forgetLaneUpload();
    records().single.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 9)));

    expect(await _produceSdk(repo()), isNotNull);
    expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(2));
    expect(httpStubs().directUploads, hasLength(4));
    verify(() => getDep<MplatrolLogger>().info(any(
        that: allOf(
            startsWith('[artifact-cache] miss: the upload recorded '
                'for build identity '),
            contains(' is 9 days old; building and uploading the Android pair'))))).called(2);
  });

  test('a build prepared with another inputs revision misses the per-user record', () async {
    setupWithHome();
    expect(await _produceSdk(repo(), env: {..._fullEnv(), ltInputsRevisionEnv: 'aaaa'}), isNotNull);
    forgetLaneUpload();

    expect(await _produceSdk(repo(), env: {..._fullEnv(), ltInputsRevisionEnv: 'bbbb'}), isNotNull);
    expect(records().map((file) => p.basename(file.path).split('-').last).toSet(), {'aaaa.json', 'bbbb.json'});
    expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(2));
  });

  test('a changed source misses the per-user record and names why', () async {
    setupWithHome();
    expect(await _produceSdk(repo()), isNotNull);
    File(p.join(repo().path, 'lib/changed.dart')).writeAsStringSync('const changed = 2;');

    expect(await _produceSdk(repo()), isNotNull);
    expect(records(), hasLength(2));
    verify(() => getDep<MplatrolLogger>().info(any(
        that: allOf(
            startsWith('[artifact-cache] miss: no upload recorded '
                'for build identity '),
            endsWith('; building and uploading the Android pair'))))).called(2);
  });
}

void _automaticDriftCases({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() setup,
}) {
  for (final input in ['source', 'native SDK', 'generator', 'arguments', 'environment', 'credential transport']) {
    test('automatic $input drift rebuilds; explicit stale reuse refuses', () async {
      setup();
      expect(await _produceSdk(repo()), isNotNull);
      final env = _fullEnv();
      switch (input) {
        case 'source':
          File(p.join(repo().path, 'lib/changed.dart')).writeAsStringSync('const changed = 1;');
        case 'native SDK':
          File(p.join(repo().path, 'android/settings.gradle')).writeAsStringSync('// SDK change');
        case 'generator':
          env[e2eTestTimeoutMsEnv] = '600000';
        case 'arguments':
          File(p.join(repo().path, defaultE2eDartDefineFile)).writeAsStringSync('{"E2E_ENVIRONMENT":"Staging"}');
        case 'environment':
          env['JAVA_HOME'] = '/fixture/other-jdk';
        case 'credential transport':
          env['MPLATROL_E2E_CREDENTIALS_URL'] = 'http://localhost:45678/e2e-credentials?token=changed-fixture';
      }
      expect(await _produceSdk(repo(), reuse: true, env: env), isNull);
      expect(httpStubs().directUploads, hasLength(2));
      expect(await _produceSdk(repo(), env: env), isNotNull);
      expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(2));
      expect(httpStubs().directUploads, hasLength(4));
      verify(() => getDep<MplatrolLogger>().info(any(that: contains('[artifact-auto-reuse] miss:')))).called(2);
    });
  }
}

void _automaticInvalidCases({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() setup,
}) {
  for (final damage in ['malformed cache', 'unknown receipt', 'missing receipt', 'stale receipt']) {
    test('automatic $damage never reuses an unvalidated uploaded pair', () async {
      setup();
      expect(await _produceSdk(repo()), isNotNull);
      final file = File(p.join(repo().path, 'build/app/outputs/lt-last.json'));
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      switch (damage) {
        case 'malformed cache':
          file.writeAsStringSync('{');
        case 'unknown receipt':
          (data['sdkReceipt'] as Map)['schema'] = 999;
          file.writeAsStringSync(jsonEncode(data));
        case 'missing receipt':
          data.remove('sdkReceipt');
          file.writeAsStringSync(jsonEncode(data));
        case 'stale receipt':
          (data['sdkReceipt'] as Map)['receiptDigest'] = '0000000000000000';
          file.writeAsStringSync(jsonEncode(data));
      }
      expect(await _produceSdk(repo(), reuse: true), isNull);
      expect(await _produceSdk(repo()), isNotNull);
      expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(2));
      expect(httpStubs().directUploads, hasLength(4));
    });
  }
  for (final damage in ['malformed eligibility', 'unknown SDK', 'malformed compiled APK']) {
    test('$damage refuses rather than accepting cached evidence', () async {
      setup();
      expect(await _produceSdk(repo()), isNotNull);
      if (damage == 'malformed eligibility') {
        File(p.join(repo().path, 'patrol_test/sdk_requirements.json')).writeAsStringSync('{');
      } else if (damage == 'malformed compiled APK') {
        File(p.join(repo().path, 'lib/changed.dart')).writeAsStringSync('const changed = 1;');
        scripted().afterCommand = (command) {
          if (command.contains('build android')) {
            File(LtAndroidRunner.appApkPath(repo().path)).writeAsBytesSync([1, 2, 3]);
          }
        };
      }
      expect(await _produceSdk(repo(), sdk: damage == 'unknown SDK' ? 'unknown-sdk' : null), isNull);
      expect(httpStubs().directUploads, hasLength(2));
    });
  }
}

bool _fixtureFileExists(Set<String> existing, String path, String appApk, String testApk) =>
    path == appApk || path == testApk ? existing.contains(path) : File(path).existsSync();

void _compileFixtureCommand(String command, Directory repo) {
  if (command.contains('build android')) {
    _compiledFixtureApks(repo);
  }
}

void _legacyPackageBindingReceiptCase({
  required Directory Function() repo,
  required _ScriptedShell Function() scripted,
  required _HttpStubs Function() httpStubs,
  required void Function() stubFiles,
  required void Function() stubShell,
}) {
  test('package changes during compilation refuse the built pair before upload', () async {
    stubFiles();
    stubShell();
    httpStubs().install();
    scripted().onCommand = (command) {
      if (command.contains('build android')) {
        File(p.join(repo().path, 'android/app/build.gradle'))
            .writeAsStringSync('android { defaultConfig {\napplicationId "com.example.changed"\n} }');
      }
    };
    expect(await _produceSdk(repo()), isNull);
    expect(httpStubs().directUploads, isEmpty);
  });
  test('valid prior-binding receipt cannot reuse an otherwise unchanged APK pair', () async {
    stubFiles();
    stubShell();
    httpStubs().install();
    final fresh = (await _produceSdk(repo()))!;
    final selection = fresh.selection!;
    final generator = androidPatrolGeneratorIdentity(env: _fullEnv());
    const legacyIdentity = '0123456789abcdef';
    // Model a valid compiled/uploaded prior-recipe receipt, not a damaged receipt.
    prepareAndroidPatrolSdkAssets(selection, buildIdentity: legacyIdentity, nativeGeneratorIdentity: generator);
    _compiledFixtureApks(repo());
    final receipt = await uploadPatrolSdkArtifacts(
        selection: selection,
        buildIdentity: legacyIdentity,
        nativeGeneratorIdentity: generator,
        appApk: LtAndroidRunner.appApkPath(repo().path),
        testApk: LtAndroidRunner.testApkPath(repo().path),
        upload: () async => (appId: fresh.appId, testId: fresh.testSuiteAppId));
    receipt.validate(
        selection: selection,
        buildIdentity: legacyIdentity,
        nativeGeneratorIdentity: generator,
        appId: fresh.appId,
        testId: fresh.testSuiteAppId);
    final file = File(p.join(repo().path, 'build/app/outputs/lt-last.json'));
    final cache = jsonDecode(file.readAsStringSync()) as Map;
    cache['sdkReceipt'] = receipt.toJson();
    file.writeAsStringSync(jsonEncode(cache));
    expect(await _produceSdk(repo(), reuse: true), isNull);
    expect(httpStubs().directUploads, hasLength(2));
    expect(await _produceSdk(repo()), isNotNull);
    expect(scripted().ranScripts.where((cmd) => cmd.contains('build android')), hasLength(2));
    expect(httpStubs().directUploads, hasLength(4));
  });
}
