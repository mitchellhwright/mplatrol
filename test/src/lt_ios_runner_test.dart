import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/ios_codesign.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_ios_runner.dart';
import 'package:mplatrol/src/lt_tunnel.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _MockMplatrolProcess extends Mock implements MplatrolProcess {}

ProcessResultX _result(String stdout, {int exitCode = 0, String stderr = ''}) =>
    ProcessResultX.from(ProcessResult(0, exitCode, stdout, stderr));

/// The bundle id `xcodebuild -showBuildSettings` resolves to in the stubs; the
/// PATROL_* build inputs and entitlements derive from it.
const _bundleId = 'com.example.demostagingapp';

/// The name the mocked [LtTunnel] reports; forwarded into the trigger payload.
const _tunnelName = 'alkstg';

const _env = {
  'LT_USERNAME': 'user',
  'LT_ACCESS_KEY': 'key',
  'LT_BIN': '/Downloads/LT',
  'CODESIGN_IDENTITY': 'Apple Development: Tester',
  'LT_IOS_PROVISIONING_PROFILE': '<set in setUp>',
};

/// The happy-path LambdaTest HTTP response bodies the runner parses. The
/// GitLab upload returns an empty body with a 201 status, so it needs no
/// constant. These are now `http.Response` bodies, not curl stdout.
const _passBuild = '{"data": {"status_ind": "passed"}}';
const _ltUploadAppOk = '{"app_url": "lt://APP_ID"}';
const _xcuiTriggerOk = '{"buildId": "BID-1"}';

String _nativeXCTestLog(String identity) {
  final parts = identity.split('/');
  return "Test Case '-[${parts[0]} ${parts[1]}]' started.\n"
      "Test Case '-[${parts[0]} ${parts[1]}]' passed (2.0 seconds).\n"
      "Test Suite '${parts[0]}' passed at 2026-09-30 12:00:00.\n"
      'Executed 1 test, with 0 failures (0 unexpected) in 2.0 seconds\n';
}

/// A minimal stand-in for Patrol's generated `test_bundle.dart` carrying the
/// marker regions the runner rewrites — seeded with a DIFFERENT import so a
/// retarget is observable.
const _bundleTemplatrole = '''
// GENERATED CODE - DO NOT MODIFY BY HAND
import 'package:patrol/patrol.dart';
// START: GENERATED TEST IMPORTS
import 'some_other_test.dart' as some_other_test;
// END: GENERATED TEST IMPORTS

Future<void> main() async {
// START: GENERATED TEST GROUPS
  group('some_other_test', some_other_test.main);
// END: GENERATED TEST GROUPS
}
''';

/// True when [args] (a `runArgs` argument vector) contains an element that has
/// [needle] as a substring.
bool _argsContain(List<String> args, String needle) => args.any((arg) => arg.contains(needle));

String _encodedDartDefines(List<String> defines) =>
    defines.map((define) => base64.encode(utf8.encode(define))).join(',');

List<String> _readDartDefines(File file) {
  final line = file.readAsLinesSync().firstWhere((line) => line.startsWith('DART_DEFINES='));
  return line.substring('DART_DEFINES='.length).split(',').map((value) => utf8.decode(base64.decode(value))).toList();
}

/// A mocktail matcher for "the argument vector has an element containing
/// [needle]" — the `runArgs` analogue of `contains(...)` over a command string.
Matcher _hasArg(String needle) =>
    predicate<List<String>>((args) => _argsContain(args, needle), 'has an argument containing "$needle"');

/// The last element of a `runArgs` vector — for codesign/ditto this is the
/// bundle/destination path, which is how the resign steps are told apart.
String _last(List<String> args) => args.isEmpty ? '' : args.last;

/// Matches the runner-signing codesign call: it carries `--entitlements` and
/// its final argument (the bundle path) is the runner `.app`.
Matcher get _signsRunnerApp => predicate<List<String>>(
      (args) => _argsContain(args, '--entitlements') && _last(args).endsWith('RunnerUITests-Runner.app'),
      'codesigns the runner .app with entitlements',
    );

void main() {
  late MplatrolShell shell;
  late MplatrolLogger logger;
  late LtTunnel ltTunnel;
  late IosCodesign codesign;
  late LtHttp ltHttp;
  late _MockMplatrolProcess tunnelProcess;
  late Directory iosDir;
  late Directory appDir;
  late Directory productsDir;
  late String profilePath;
  final nativeIdentities = <String, String>{};

  /// A uniform `runArgs` matcher: every positional and the working-directory
  /// are mocktail matchers so there is no raw-value/matcher mixing. Callers
  /// constrain only what they care about and leave the rest as `anything`.
  Future<ProcessResultX> runArgsMatch({Matcher? exe, Matcher? args, Matcher? workingDirectory}) => shell.runArgs(
        any(that: exe ?? anything),
        any(that: args ?? anything),
        workingDirectory: any(named: 'workingDirectory', that: workingDirectory ?? anything),
        throwOnError: any(named: 'throwOnError'),
      );

  /// The LambdaTest direct upload call (`postMultipart` to
  /// `app/upload/realDevice` with the IPA as `filePath`).
  Future<http.Response> ltUpload({Matcher? url, Matcher? fields, Matcher? filePath}) => ltHttp.postMultipart(
        any(that: url ?? anything),
        headers: any(named: 'headers'),
        fields: any(named: 'fields', that: fields ?? anything),
        filePath: any(named: 'filePath', that: filePath ?? anything),
        onAnswered: any(named: 'onAnswered'),
      );

  /// The XCUITest trigger call (`postJson` to `framework/v1/xcui/build`). The
  /// payload is now a `Map<String, dynamic>` body, not a JSON string argument.
  Future<http.Response> ltTrigger({Matcher? url, Matcher? body}) => ltHttp.postJson(
        any(that: url ?? anything),
        headers: any(named: 'headers'),
        body: any(named: 'body', that: body ?? anything),
      );

  /// The build-status poll call (`get` to `mobile-automation/.../builds/<id>`).
  Future<http.Response> ltPoll({Matcher? url}) => ltHttp.get(
        any(that: url ?? anything),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      );

  /// Stub [LtTunnel.start] to report ready with [name] and hand back the tunnel
  /// process whose `kill()` the runner calls on exit.
  void stubTunnel({bool ready = true, String name = _tunnelName}) {
    when(
      () => ltTunnel.start(
        ltBin: any(named: 'ltBin'),
        ltUser: any(named: 'ltUser'),
        ltKey: any(named: 'ltKey'),
        tunnelName: any(named: 'tunnelName'),
      ),
    ).thenAnswer((_) async => (process: tunnelProcess, ready: ready, name: name));
  }

  void createBuildProductsFixture() {
    // Runner.app with one framework to embed + sign.
    Directory(p.join(productsDir.path, 'Runner.app', 'Frameworks', 'Flutter.framework')).createSync(recursive: true);
    File(
      p.join(productsDir.path, 'Runner.app', 'Frameworks', 'Flutter.framework', 'Flutter'),
    ).writeAsStringSync('binary');
    // RunnerUITests-Runner.app with its embedded xctest plugin.
    Directory(
      p.join(productsDir.path, 'RunnerUITests-Runner.app', 'PlugIns', 'RunnerUITests.xctest'),
    ).createSync(recursive: true);
    File(
      p.join(productsDir.path, 'RunnerUITests-Runner.app', 'PlugIns', 'RunnerUITests.xctest', 'Info.plist'),
    ).writeAsStringSync('<plist/>');
    // A nested framework + dylib already inside the runner so the bare-identity
    // signing pass (signs every nested framework/dylib) has something to sign.
    Directory(
      p.join(productsDir.path, 'RunnerUITests-Runner.app', 'Frameworks', 'XCTest.framework'),
    ).createSync(recursive: true);
    File(
      p.join(productsDir.path, 'RunnerUITests-Runner.app', 'Frameworks', 'libswift.dylib'),
    ).writeAsStringSync('dylib');
  }

  /// A script-aware default `run` stub for the single-binary build steps that
  /// stay on [MplatrolShell.run] (git rev-parse, the bundle-id read, flutter build,
  /// xcodebuild).
  void stubRun() {
    when(
      () => shell.run(
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        silent: any(named: 'silent'),
        forceVerbose: any(named: 'forceVerbose'),
      ),
    ).thenAnswer((invocation) async {
      final script = invocation.positionalArguments.first as String;
      if (script.contains('git rev-parse')) {
        return _result('abc1234\n');
      }
      if (script.contains('-showBuildSettings')) {
        return _result('    PRODUCT_BUNDLE_IDENTIFIER = $_bundleId\n');
      }
      if (script.contains('build-for-testing')) {
        createBuildProductsFixture();
      }
      return _result('');
    });
  }

  /// A script-aware default `runArgs` stub returning the right canned payload
  /// for each external command so the happy path completes. HTTP no longer runs
  /// through the shell (curl is gone — see [stubHttp]); only plutil needs a
  /// scripted reply. Individual tests override one command to fail.
  void stubRunArgs() {
    when(
      () => shell.runArgs(
        any(),
        any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
      ),
    ).thenAnswer((invocation) async {
      final exe = invocation.positionalArguments[0] as String;
      if (exe == 'plutil') {
        return _result('com.example.demo.uitests\n');
      }
      if (exe == 'zip') {
        final args = invocation.positionalArguments[1] as List<String>;
        File(args[2]).writeAsStringSync('${p.basename(args[2])}:compiled fixture');
      }
      // ditto, codesign (nested + entitlements + verify), zip all succeed.
      return _result('');
    });
  }

  void rememberNativeIdentity(String id, Invocation invocation) {
    final payload = invocation.namedArguments[#body] as Map<String, dynamic>;
    final name = payload['build'] as String;
    final shards = iosTestShards(appDir.path);
    final matches = shards.where((shard) => name.endsWith(' - ${shard.description}')).toList();
    if (matches.length == 1) {
      nativeIdentities[id] = matches.single.onlyTesting;
    }
  }

  /// Stub the injected [LtHttp] (resolved via `getDep<LtHttp>()`) to the iOS
  /// happy-path responses so a default run uploads, triggers, and polls to
  /// success. Individual tests override one call to fail or throw.
  void stubHttp() {
    when(ltUpload).thenAnswer((_) async => http.Response(_ltUploadAppOk, 200));
    when(ltTrigger).thenAnswer((invocation) async {
      final id = 'BID-${nativeIdentities.length + 1}';
      rememberNativeIdentity(id, invocation);
      return http.Response(id == 'BID-1' ? _xcuiTriggerOk : jsonEncode({'buildId': id}), 200);
    });
    when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async => http.Response(_passBuild, 200));
    when(() => ltPoll(url: contains('/sessions?build_id='))).thenAnswer((invocation) async {
      final uri = Uri.parse(invocation.positionalArguments.first as String);
      final id = uri.queryParameters['build_id']!;
      return http.Response(
          jsonEncode({
            'data': [
              {
                'session_id': 'SID-$id',
                if (RegExp(r'^[0-9]+$').hasMatch(id)) 'build_id': id,
                'status_ind': 'passed',
              },
            ]
          }),
          200);
    });
    when(() => ltPoll(url: contains('/log/instrumentation'))).thenAnswer((invocation) async {
      final uri = Uri.parse(invocation.positionalArguments.first as String);
      final id = uri.pathSegments[4].substring(4);
      final identity = nativeIdentities[id] ?? iosTestShards(appDir.path).single.onlyTesting;
      return http.Response(_nativeXCTestLog(identity), 200);
    });
  }

  Map<String, String> envWithProfile([Map<String, String>? overrides]) => {
        ..._env,
        'LT_IOS_PROVISIONING_PROFILE': profilePath,
        ...?overrides,
      };

  setUp(() async {
    nativeIdentities.clear();
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    logger = getDep<MplatrolLogger>();
    ltTunnel = getDep<LtTunnel>();
    codesign = getDep<IosCodesign>();
    ltHttp = getDep<LtHttp>();

    final tempRoot = Directory.systemTemp.createTempSync('lt_ios_runner');
    appDir = Directory(p.join(tempRoot.path, 'app'))..createSync();
    iosDir = Directory(p.join(appDir.path, 'ios'))..createSync();

    // Patrol's generated test bundle the iOS build compiles; the run retargets
    // its marker regions to --target before building.
    final bundleFile = File(p.join(appDir.path, 'patrol_test', 'test_bundle.dart'))..parent.createSync(recursive: true);
    bundleFile.writeAsStringSync(_bundleTemplatrole);
    // A Patrol test fixture so generateIosPatrolRunner (run before the build)
    // has something to generate from instead of throwing on an empty suite.
    File(
      p.join(appDir.path, 'patrol_test', 'patrol_login_test.dart'),
    ).writeAsStringSync("patrolTest('sample test', (\$) async {});\n");
    File(p.join(appDir.path, defaultE2eDartDefineFile))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"E2E_ENVIRONMENT": "Dev"}\n');
    File(p.join(appDir.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[]}');
    File(p.join(appDir.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');

    // The rewrite does file/dir work through dart:io, so the build-products
    // tree the resign + packaging steps touch must exist on disk.
    productsDir = Directory(p.join(iosDir.path, LtIosRunner.defaultProductsDir))..createSync(recursive: true);
    createBuildProductsFixture();
    // Pre-create one output IPA as a file so the pre-clean step exercises the
    // file-delete branch (the zip itself is mocked and never writes one).
    File(p.join(productsDir.path, 'Runner.ipa')).writeAsStringSync('stale');
    // The provisioning profile copied to embedded.mobileprovision.
    profilePath = p.join(tempRoot.path, 'runner.mobileprovision');
    File(profilePath).writeAsStringSync('profile');

    final fileSystem = getDep<FileSystem>();
    when(fileSystem.getIosDirectory).thenReturn(iosDir);
    when(fileSystem.getAppDirectory).thenReturn(appDir);

    tunnelProcess = _MockMplatrolProcess();
    when(tunnelProcess.kill).thenReturn(null);
    stubTunnel();
    stubRun();
    stubRunArgs();
    stubHttp();
  });

  LtIosRunner buildRunner({Duration pollDelay = Duration.zero}) =>
      LtIosRunner(pollDelay: pollDelay, uploadPolicy: instantLtUploadPolicy);

  Future<int> runDefault({
    Map<String, String>? env,
    List<String>? devices,
    int idleTimeoutSeconds = 240,
    bool reuseLast = false,
    Duration pollDelay = Duration.zero,
    String? target = 'patrol_test/patrol_login_test.dart',
  }) =>
      buildRunner(pollDelay: pollDelay).run(
        target: target,
        devices: devices ?? const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: idleTimeoutSeconds,
        env: env ?? envWithProfile(),
        reuseLast: reuseLast,
      );

  Map<String, Object?> buildInputs({String? target = 'patrol_test/patrol_login_test.dart'}) {
    final definePath = p.join(appDir.path, defaultE2eDartDefineFile);
    final stat = File(definePath).statSync();
    return {
      'nativeGenerator': iosPatrolGeneratorIdentity(),
      'selectionCoordinatorUrl': '',
      'target': target ?? '',
      'targetRegex': '',
      'sdk': '',
      'dartDefines': const ['LT_PROXY=true', 'E2E_TEST_BRIDGE=true'],
      'defineFile': {
        'path': definePath,
        'exists': true,
        'length': stat.size,
        'modifiedMicros': stat.modified.microsecondsSinceEpoch,
      },
    };
  }

  String perTestCacheJson({
    String? target = 'patrol_test/patrol_login_test.dart',
    String app = 'lt://APP_ID',
    List<Map<String, String>> tests = const [
      {'id': 'lt://TEST_ID', 'name': 'sample test'},
    ],
  }) {
    return jsonEncode({
      'schema': 2,
      'inputs': buildInputs(target: target),
      'app': app,
      'tests': tests,
    });
  }

  String hyperexecuteInputsJson({String? target = 'patrol_test/patrol_login_test.dart'}) =>
      jsonEncode({'schema': 2, 'inputs': buildInputs(target: target)});

  /// The single-build reuse-last cache path (used only by the whole-suite
  /// fallback) inside [productsDir].
  String cachePath() => p.join(productsDir.path, 'lt-last.json');

  /// The per-test reuse-last cache path the runner reads/writes inside
  /// [productsDir] for the normal (per-test-build) path.
  String perTestCachePath() => p.join(productsDir.path, 'lt-last-pertest.json');

  String hyperexecuteInputsPath() => p.join(productsDir.path, 'hyperexecute-inputs.json');

  group('LtIosRunner', () {
    group('input validation', () {
      for (final key in const [
        'LT_USERNAME',
        'LT_ACCESS_KEY',
        'LT_BIN',
      ]) {
        test('returns usage exit when $key is missing', () async {
          final env = envWithProfile()..remove(key);
          final result = await runDefault(env: env);

          expect(result, ExitCode.usage.code);
          verify(() => logger.err(any(that: contains(key)))).called(1);
          verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
        });
      }

      test('returns usage exit when devices is empty', () async {
        final result = await runDefault(devices: const []);

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('No LambdaTest iOS devices')))).called(1);
      });

      test('returns usage exit when targetRegex matches no iOS test shards', () async {
        final result = await buildRunner().run(
          target: 'patrol_test/patrol_login_test.dart',
          targetRegex: 'no_match_xyz',
          devices: const ['iPhone 17 Pro-26'],
          idleTimeoutSeconds: 240,
          env: envWithProfile(),
        );

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('No iOS Patrol test shards matched')))).called(1);
      });
    });

    group('tunnel', () {
      test('returns unavailable and kills the tunnel when it never readies', () async {
        stubTunnel(ready: false, name: '');

        final result = await runDefault();

        expect(result, ExitCode.unavailable.code);
        verify(tunnelProcess.kill).called(1);
        // The tunnel now starts after the build/upload (so it isn't held idle
        // and dropped), so the device-run trigger must not fire when it fails
        // to ready.
        verifyNever(
          () => ltHttp.postJson(
            any(that: contains('xcui/build')),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
          ),
        );
      });

      test('kills the tunnel after a successful run', () async {
        await runDefault();

        verify(tunnelProcess.kill).called(1);
      });
    });

    group('test bundle', () {
      String bundleContent(String name) => File(p.join(appDir.path, 'patrol_test', name)).readAsStringSync();

      test('writes the iOS-owned bundle for --target before building', () async {
        final result = await runDefault();

        expect(result, ExitCode.success.code);
        final bundle = bundleContent(iosPatrolTestBundleFile);
        expect(bundle, contains("import 'patrol_login_test.dart' as patrol_login_test;"));
        expect(bundle, contains("group('patrol_login_test', () { patrol_login_test.main(); });"));
        // The seeded templatrole's import was replaced, not appended.
        expect(bundle, isNot(contains('some_other_test')));
        // Patrol's shared bundle belongs to the Android arm and stays untouched.
        expect(bundleContent('test_bundle.dart'), _bundleTemplatrole);
      });

      group("fresh checkout without Patrol's test_bundle.dart", () {
        late Directory pubCache;

        File sharedBundle() => File(p.join(appDir.path, 'patrol_test', 'test_bundle.dart'));

        Future<ProcessResultX> dartRun() => runArgsMatch(exe: equals('dart'));

        setUp(() {
          sharedBundle().deleteSync();
          pubCache = Directory.systemTemp.createTempSync('lt_ios_pub_cache');
          when(() => getDep<PlatformWrapper>().environment).thenReturn({'PUB_CACHE': pubCache.path});
        });

        void activatePatrolCli() =>
            File(p.join(pubCache.path, 'global_packages', 'patrol_cli', '.dart_tool', 'package_config.json'))
              ..createSync(recursive: true)
              ..writeAsStringSync('{}');

        test('generates the scaffolding with patrol_cli and leaves the shared bundle to Android', () async {
          activatePatrolCli();
          final generatorArgs = <List<String>>[];
          when(dartRun).thenAnswer((invocation) async {
            final args = invocation.positionalArguments[1] as List<String>;
            generatorArgs.add(args);
            File(p.join(args[3], 'patrol_test', 'test_bundle.dart')).writeAsStringSync(_bundleTemplatrole);
            return _result('');
          });

          final result = await runDefault();

          expect(result, ExitCode.success.code);
          expect(generatorArgs.single.take(2), [
            'run',
            '--packages=${p.join(pubCache.path, 'global_packages', 'patrol_cli', '.dart_tool', 'package_config.json')}',
          ]);
          expect(generatorArgs.single.last, 'patrol_login_test');
          expect(Directory(generatorArgs.single[3]).existsSync(), isFalse, reason: 'scratch dir is removed');
          final bundle = bundleContent(iosPatrolTestBundleFile);
          expect(bundle, contains("import 'patrol_login_test.dart' as patrol_login_test;"));
          expect(bundle, isNot(contains('some_other_test')));
          expect(sharedBundle().existsSync(), isFalse);
          verify(() => shell.stubbedRun(any(that: contains('flutter build ios')),
              workingDirectory: any(named: 'workingDirectory'))).called(1);
        });

        test('asks for patrol_cli activation when it is not globally activated', () async {
          final result = await runDefault();

          expect(result, ExitCode.config.code);
          verify(() => logger.err(any(that: contains('dart pub global activate patrol_cli 4.8.0')))).called(1);
          verifyNever(dartRun);
          verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
        });

        test('reports a patrol_cli bundler failure without building', () async {
          activatePatrolCli();
          when(dartRun).thenAnswer((_) async => _result('', exitCode: 255, stderr: 'Could not resolve patrol_cli'));

          final result = await runDefault();

          expect(result, ExitCode.software.code);
          verify(() => logger.err(any(that: allOf(contains('exit 255'), contains('Could not resolve patrol_cli')))))
              .called(1);
          verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
        });
      });

      test('fails when the bundle is missing the generated markers', () async {
        File(
          p.join(appDir.path, 'patrol_test', 'test_bundle.dart'),
        ).writeAsStringSync('// a bundle with no markers');

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('missing the')))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
      });
    });

    group('build', () {
      test('runs flutter config-only then build-for-testing', () async {
        await runDefault();

        verify(
          () => shell.stubbedRun(
            any(
              that: allOf(
                // Flutter's SPM integration evaluates Patrol's Package.swift with the environment.
                startsWith('env PATROL_ENABLED=1 '),
                contains('flutter build ios --config-only --profile'),
                contains("--target='patrol_test/$iosPatrolTestBundleFile'"),
                contains('--dart-define=LT_PROXY=true'),
                contains('--dart-define=E2E_TEST_BRIDGE=true'),
                contains("--dart-define=PATROL_APP_BUNDLE_ID='$_bundleId'"),
                contains("'--dart-define=E2E_ENVIRONMENT=Dev'"),
              ),
            ),
            workingDirectory: appDir.path,
          ),
        ).called(1);
        verify(
          () => shell.stubbedRun(
            any(
              that: allOf([
                startsWith('env PATROL_ENABLED=1 xcodebuild build-for-testing'),
                contains(r"FRAMEWORK_SEARCH_PATHS='$(inherited) $(PLATFORM_DIR)/Developer/Library/Frameworks'"),
                contains(r"LIBRARY_SEARCH_PATHS='$(inherited) $(PLATFORM_DIR)/Developer/usr/lib'"),
                contains(r"OTHER_LDFLAGS='$(inherited) -weak-lXCTestSwiftSupport'"),
                contains('SWIFT_ACTIVE_COMPILATION_CONDITIONS'),
                contains('PATROL_ENABLED'),
                contains('PATROL_TARGET_BUNDLE_ID=$_bundleId'),
                contains('CODE_SIGNING_ALLOWED=NO'),
              ]),
            ),
            workingDirectory: iosDir.path,
          ),
        ).called(1);
      });

      test('fails when the bundle id cannot be read from the project', () async {
        when(
          () => shell.stubbedRun(any(that: contains('-showBuildSettings'))),
        ).thenAnswer((_) async => _result('NO BUNDLE ID HERE\n'));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('Could not read PRODUCT_BUNDLE_IDENTIFIER')))).called(1);
      });

      test('fails when the flutter config-only build fails', () async {
        when(
          () => shell.stubbedRun(any(that: contains('flutter build ios'))),
        ).thenAnswer((_) async => _result('', exitCode: 70));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('flutter build ios --config-only failed')))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });

      group('stale Swift module caches', () {
        late String derived;
        late List<List<String>> trashed;
        var trashExit = 0;

        void podsWere(String? digest) {
          derived = p.join(iosDir.path, 'build', 'xcui-lt');
          for (final cache in [
            'Build/Intermediates.noindex/SwiftExplicitPrecompiledModules',
            'ModuleCache.noindex',
            'SourcePackages',
          ]) {
            Directory(p.join(derived, cache)).createSync(recursive: true);
          }
          if (digest != null) {
            File(p.join(derived, 'mplatrol-pods.digest')).writeAsStringSync(digest);
          }
        }

        String digestAfterRun() => File(p.join(derived, 'mplatrol-pods.digest')).readAsStringSync();

        setUp(() {
          trashed = [];
          trashExit = 0;
          File(p.join(iosDir.path, 'Podfile.lock')).writeAsStringSync('VisaPushProvisioning (1.3.0)');
          File(p.join(appDir.path, '.flutter-plugins-dependencies'))
              .writeAsStringSync('{"plugins":{"ios":[{"name":"visa_v2"}]},"date_created":"now"}');
          when(() =>
                  shell.runArgs(any(), any(), throwOnError: any(named: 'throwOnError'), silent: any(named: 'silent')))
              .thenAnswer((invocation) async {
            final args = invocation.positionalArguments[1] as List<String>;
            if (invocation.positionalArguments[0] == 'trash') {
              trashed.add(args);
              return _result('', exitCode: trashExit);
            }
            return _result('0\t${args.last}\n');
          });
        });

        // Regression: r12 cyberdyne linked against Visa SDK 1.2.0 modules after its plugin switched to SDK 1.3.0.
        test('go to the Trash before the build when the pods changed', () async {
          podsWere('digest-of-visa-1.2.0');

          await runDefault();

          expect(trashed.single, [
            p.join(derived, 'Build/Intermediates.noindex/SwiftExplicitPrecompiledModules'),
            p.join(derived, 'ModuleCache.noindex'),
            p.join(derived, 'SourcePackages'),
          ]);
          verify(() => logger.info('[ios-build] pods changed since the last build; cleared stale Swift module caches'))
              .called(1);
          expect(digestAfterRun(), isNot('digest-of-visa-1.2.0'));
        });

        // Regression 2026-10-14: DerivedData resolved before PATROL_ENABLED was exported kept Patrol's SPM
        // graph without XCTest, so PatrolImpl.o failed to link on XCUIApplication. The digest such a build
        // wrote (same Podfile.lock and plugin set, no schema token) must clear the caches once.
        test('are cleared once for builds made before PATROL_ENABLED was exported', () async {
          final preFix = (FingerprintBuilder()
                ..addString('VisaPushProvisioning (1.3.0)')
                ..addString(jsonEncode({
                  'ios': [
                    {'name': 'visa_v2'}
                  ]
                })))
              .finish();
          podsWere(preFix);

          await runDefault();

          expect(trashed.single, contains(p.join(derived, 'SourcePackages')));
          final current = digestAfterRun();
          expect(current, isNot(preFix));
          trashed.clear();
          await runDefault();
          expect(trashed, isEmpty, reason: 'unchanged inputs must not clear again');
        });

        test('stay when neither the pods nor the plugin set changed, whatever the plugin file date', () async {
          podsWere(null);
          await runDefault();
          final digest = digestAfterRun();
          trashed.clear();
          File(p.join(appDir.path, '.flutter-plugins-dependencies'))
              .writeAsStringSync('{"plugins":{"ios":[{"name":"visa_v2"}]},"date_created":"later"}');

          await runDefault();

          expect(trashed, isEmpty);
          expect(digestAfterRun(), digest);
        });

        test('that cannot go to the Trash only warn, and the next build tries again', () async {
          podsWere('digest-of-visa-1.2.0');
          trashExit = 1;

          await runDefault();

          verify(() => logger.warn(any(
              that: startsWith('[ios-build] pods changed since the last build, but the '
                  'stale Swift module caches could not go to the Trash')))).called(1);
          expect(digestAfterRun(), 'digest-of-visa-1.2.0');
          verify(() => shell.stubbedRun(any(that: contains('build-for-testing')))).called(1);
        });
      });

      test('fails when build-for-testing fails', () async {
        when(
          () => shell.stubbedRun(any(that: contains('build-for-testing'))),
        ).thenAnswer((_) async => _result('', exitCode: 65));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('build-for-testing failed')))).called(1);
      });
    });

    group('build name', () {
      // Per-test builds suffix the build name with the test description so the
      // dashboard shows the real test name; the fixture has one test ("sample
      // test").
      test('derives the build name from the short git sha', () async {
        await runDefault();

        verify(() => ltTrigger(body: containsPair('build', 'PatrolIOS-abc1234 - sample test'))).called(1);
      });

      test('falls back to "local" when git rev-parse returns nothing', () async {
        when(() => shell.stubbedRun(any(that: contains('git rev-parse')))).thenAnswer((_) async => _result('\n'));

        await runDefault();

        verify(() => ltTrigger(body: containsPair('build', 'PatrolIOS-local - sample test'))).called(1);
      });

      test('uses LT_BUILD_NAME from env and skips git rev-parse', () async {
        final env = envWithProfile({'LT_BUILD_NAME': 'custom-build'});

        await runDefault(env: env);

        verify(() => ltTrigger(body: containsPair('build', 'custom-build - sample test'))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('git rev-parse'))));
      });
    });

    group('native assets', () {
      void writeManifest(String json) {
        File(p.join(productsDir.path, 'Runner.app', 'Frameworks', 'App.framework', 'flutter_assets',
            'NativeAssetsManifest.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(json);
      }

      const mapped = '{"native-assets":{"ios_arm64":'
          '{"package:objective_c/objective_c.dylib":["absolute","objective_c.framework/objective_c"]}}}';

      void writeObjectiveC() =>
          File(p.join(productsDir.path, 'Runner.app', 'Frameworks', 'objective_c.framework', 'objective_c'))
            ..createSync(recursive: true)
            ..writeAsStringSync('binary');

      File stageAssetFramework() =>
          File(p.join(appDir.path, 'build', 'native_assets', 'ios', 'objective_c.framework', 'objective_c'))
            ..createSync(recursive: true);

      Map<String, FileSystemEntity> stageBuildState() => {
            'build': Directory(p.join(appDir.path, 'build'))..createSync(recursive: true),
            'iosBuild': File(p.join(appDir.path, 'ios', 'build', 'stale.o'))..createSync(recursive: true),
            'flutterBuild': Directory(p.join(appDir.path, '.dart_tool', 'flutter_build', 'abc'))
              ..createSync(recursive: true),
            'packageConfig': File(p.join(appDir.path, '.dart_tool', 'package_config.json'))
              ..createSync(recursive: true),
          };

      test('runs a full iOS clean when a simulator framework is found', () async {
        stageAssetFramework();
        final state = stageBuildState();
        when(() => runArgsMatch(exe: equals('vtool'))).thenAnswer((_) async => _result('platform IOSSIMULATOR'));

        await runDefault();

        expect(state['build']!.existsSync(), isFalse);
        expect(state['iosBuild']!.existsSync(), isFalse);
        expect(state['flutterBuild']!.existsSync(), isFalse);
        expect(state['packageConfig']!.existsSync(), isTrue);
      });

      test('cleans when only some build directories exist', () async {
        final stale = stageAssetFramework();
        when(() => runArgsMatch(exe: equals('vtool'))).thenAnswer((_) async => _result('platform IOSSIMULATOR'));

        await runDefault();

        expect(stale.existsSync(), isFalse);
      });

      test('leaves build state alone for device frameworks', () async {
        final kept = stageAssetFramework();
        final state = stageBuildState();
        File(p.join(kept.parent.path, 'Info.plist')).createSync();
        Directory(p.join(kept.parent.parent.path, 'empty.framework')).createSync();
        when(() => runArgsMatch(exe: equals('vtool'))).thenAnswer((_) async => _result('platform IOS'));

        await runDefault();

        expect(kept.existsSync(), isTrue);
        expect(state.values.every((e) => e.existsSync()), isTrue);
      });

      test('leaves build state alone when there are no native assets', () async {
        final state = stageBuildState();

        await runDefault();

        expect(state.values.every((e) => e.existsSync()), isTrue);
      });

      test('accepts device frameworks and manifests without ios assets', () async {
        writeManifest('{"native-assets":{}}');
        expect(await runDefault(), ExitCode.success.code);
        writeManifest(mapped);
        writeObjectiveC();
        when(() => runArgsMatch(exe: equals('vtool'))).thenAnswer((_) async => _result('platform IOS'));

        expect(await runDefault(), ExitCode.success.code);
      });

      test('fails when a listed framework is missing from the app', () async {
        writeManifest(mapped);

        expect(await runDefault(), ExitCode.software.code);
        verify(() => logger.err(any(that: contains('missing from')))).called(1);
      });

      test('fails when a listed framework was built for the simulator', () async {
        writeManifest(mapped);
        writeObjectiveC();
        when(() => runArgsMatch(exe: equals('vtool'))).thenAnswer((_) async => _result('platform IOSSIMULATOR'));

        expect(await runDefault(), ExitCode.software.code);
        verify(() => logger.err(any(that: contains('iOS simulator')))).called(1);
      });
    });

    group('resign', () {
      test('reads the xctest id, copies the profile, embeds frameworks, signs', () async {
        await runDefault();

        // The profile is copied to embedded.mobileprovision on disk.
        expect(
          File(p.join(productsDir.path, 'RunnerUITests-Runner.app', 'embedded.mobileprovision')).existsSync(),
          isTrue,
        );

        verify(() => runArgsMatch(exe: equals('plutil'), args: _hasArg('CFBundleIdentifier'))).called(1);
        // The one app framework is dittoed into the runner.
        verify(() => runArgsMatch(exe: equals('ditto'), args: _hasArg('Flutter.framework'))).called(1);
        // The runner .app is signed with entitlements.
        verify(() => runArgsMatch(exe: equals('codesign'), args: _signsRunnerApp)).called(1);
        verify(() => runArgsMatch(exe: equals('codesign'), args: _hasArg('--verify'))).called(1);
      });

      test('derives the signing identity when CODESIGN_IDENTITY is absent', () async {
        final env = envWithProfile()..remove('CODESIGN_IDENTITY');

        final result = await runDefault(env: env);

        expect(result, ExitCode.success.code);
        verify(codesign.developerIdentity).called(1);
      });

      test('fails when no signing identity can be derived', () async {
        when(codesign.developerIdentity).thenAnswer((_) async => null);
        final env = envWithProfile()..remove('CODESIGN_IDENTITY');

        final result = await runDefault(env: env);

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('No Apple Development signing identity')))).called(1);
      });

      test('derives the provisioning profile when none is supplied', () async {
        when(() => codesign.provisioningProfile(any(), team: any(named: 'team'))).thenAnswer((_) async => profilePath);
        final env = envWithProfile()..remove('LT_IOS_PROVISIONING_PROFILE');

        final result = await runDefault(env: env);

        expect(result, ExitCode.success.code);
        verify(() => codesign.provisioningProfile(any(), team: any(named: 'team'))).called(1);
      });

      test('fails when no provisioning profile can be derived', () async {
        when(() => codesign.provisioningProfile(any(), team: any(named: 'team'))).thenAnswer((_) async => null);
        final env = envWithProfile()..remove('LT_IOS_PROVISIONING_PROFILE');

        final result = await runDefault(env: env);

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('No provisioning profile')))).called(1);
      });

      test('fails when the xctest bundle id cannot be read', () async {
        when(() => runArgsMatch(exe: equals('plutil'))).thenAnswer((_) async => _result('', exitCode: 1));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('Could not read the RunnerUITests.xctest bundle id')))).called(1);
      });

      test('fails when codesigning the runner fails', () async {
        // The runner-signing call is the one whose bundle path is the runner
        // .app and carries entitlements; fail it specifically.
        when(
          () => runArgsMatch(exe: equals('codesign'), args: _signsRunnerApp),
        ).thenAnswer((_) async => _result('', exitCode: 1));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('codesign of the XCUITest runner failed')))).called(1);
      });

      test('fails when codesign verify fails', () async {
        when(
          () => runArgsMatch(exe: equals('codesign'), args: _hasArg('--verify')),
        ).thenAnswer((_) async => _result('', exitCode: 1));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('codesign --verify of the re-signed runner failed')))).called(1);
      });
    });

    group('packaging', () {
      test('packages both the app and the runner into IPAs', () async {
        await runDefault();

        verify(
          () => runArgsMatch(
            exe: equals('zip'),
            workingDirectory: equals('${p.join(productsDir.path, 'Runner.ipa')}.payload'),
          ),
        ).called(1);
        verify(
          () => runArgsMatch(
            exe: equals('zip'),
            workingDirectory: equals('${p.join(productsDir.path, 'RunnerUITests-Runner.ipa')}.payload'),
          ),
        ).called(1);
      });

      test('keeps IPA packaging status on progress spinners', () async {
        await runDefault();

        verify(() => logger.progress('Packaging Runner.ipa')).called(1);
        verify(() => logger.progress('Packaging RunnerUITests-Runner.ipa')).called(1);
        verifyNever(() => logger.info('[package] Runner.ipa'));
        verifyNever(() => logger.info('[package] RunnerUITests-Runner.ipa'));
      });

      test('fails when packaging an IPA fails', () async {
        when(() => runArgsMatch(exe: equals('zip'))).thenAnswer((_) async => _result('', exitCode: 1));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('Packaging')))).called(1);
      });

      test('fails when the ditto copy into the Payload dir fails', () async {
        // ditto does the recursive .app copy into Payload/. The embed-frameworks
        // ditto ignores its exit code, but a failed packaging copy must fail the
        // run before zip runs.
        when(() => runArgsMatch(exe: equals('ditto'))).thenAnswer((_) async => _result('', exitCode: 1));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('Staging')))).called(1);
        verifyNever(() => runArgsMatch(exe: equals('zip')));
      });
    });

    group('hyperexecute packaging', () {
      final sampleShard = IosTestShard(method: 'testASampleTest', description: 'sample test');
      final secondShard = IosTestShard(method: 'testBSecondTest', description: 'second test');

      test('IosHyperexecuteTestSuite stores its shard and bundle path', () {
        final suite = IosHyperexecuteTestSuite(shard: sampleShard, testSuitePath: '/tmp/RunnerUITests-Runner.ipa');

        expect(suite.shard, sampleShard);
        expect(suite.testSuitePath, '/tmp/RunnerUITests-Runner.ipa');
      });

      void addSecondTest() => File(
            p.join(appDir.path, 'patrol_test', 'b_test.dart'),
          ).writeAsStringSync("patrolTest('second test', (\$) async {});\n");

      Future<IosHyperexecuteArtifacts?> buildHyperexecute({
        required List<IosTestShard> shards,
        bool reuseLast = false,
        String? target = 'patrol_test/patrol_login_test.dart',
        String selectionCoordinatorUrl = '',
        Map<String, String>? env,
        PatrolSelectionPlan? selection,
      }) =>
          buildRunner().buildIosForHyperexecute(
            target: target,
            env: env ?? envWithProfile(),
            reuseLast: reuseLast,
            shards: shards,
            selection: selection,
            selectionCoordinatorUrl: selectionCoordinatorUrl,
          );

      test('builds one full XCUITest IPA for HyperExecute shards', () async {
        addSecondTest();

        final artifacts = await buildHyperexecute(shards: [sampleShard, secondShard], target: null);

        expect(artifacts, isNotNull);
        expect(artifacts!.appPath, p.join(productsDir.path, 'Runner.ipa'));
        expect(artifacts.testSuitePath, p.join(productsDir.path, 'RunnerUITests-Runner.ipa'));
        expect(artifacts.testSuites, isEmpty);
        verify(() => shell.stubbedRun(any(that: contains('build-for-testing')))).called(1);
        verify(
          () => runArgsMatch(
            exe: equals('zip'),
            workingDirectory: equals('${p.join(productsDir.path, 'Runner.ipa')}.payload'),
          ),
        ).called(1);
        verify(
          () => runArgsMatch(
            exe: equals('zip'),
            workingDirectory: equals('${p.join(productsDir.path, 'RunnerUITests-Runner.ipa')}.payload'),
          ),
        ).called(1);
        final swiftRunner = File(
          p.join(appDir.path, 'ios', 'RunnerUITests', 'RunnerUITests.swift'),
        ).readAsStringSync();
        expect(swiftRunner, contains('func testASampleTest()'));
        expect(swiftRunner, contains('func testBSecondTest()'));
      });

      test('rewrites stale local iOS DART_DEFINES before HyperExecute build', () async {
        final profileConfig = File(p.join(appDir.path, 'ios', 'Flutter', 'Profile.xcconfig'))
          ..createSync(recursive: true);
        profileConfig.writeAsStringSync(
          'DART_DEFINES=${_encodedDartDefines([
                'E2E_TEST_BRIDGE=true',
                'PATROL_HOST=127.0.0.1',
                'PATROL_APP_BUNDLE_ID=$_bundleId',
                'E2E_CREDENTIALS_URL=http://127.0.0.1:49782/e2e-credentials?token=old',
              ])}\n',
        );
        const credentialsUrl = 'http://localhost.lambdatest.com:49782/e2e-credentials?token=new';

        final artifacts = await buildRunner().buildIosForHyperexecute(
          target: 'patrol_test/patrol_login_test.dart',
          env: envWithProfile({e2eCredentialsUrlEnv: credentialsUrl}),
          shards: [sampleShard],
        );

        expect(artifacts, isNotNull);
        final defines = _readDartDefines(profileConfig);
        expect(defines.where((define) => define.startsWith('E2E_CREDENTIALS_URL=')), [
          'E2E_CREDENTIALS_URL=$credentialsUrl',
        ]);
        expect(defines, isNot(contains('PATROL_HOST=127.0.0.1')));
      });

      test('caches exact input and IPA-pair receipt after packaging', () async {
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        final receipt = jsonDecode(File(hyperexecuteInputsPath()).readAsStringSync()) as Map;
        expect(receipt['schema'], 3);
        expect(receipt['identity'],
            isA<String>().having((value) => value.isNotEmpty, 'nonempty input fingerprint', isTrue));
        expect((receipt['artifacts'] as Map).length, 2);
        expect(receipt.toString(), isNot(contains('E2E_CREDENTIALS_URL')));
      });

      group('per-user artifact cache', () {
        late Directory home;
        File record() => Directory(p.join(home.path, '.mplatrol', 'lt-artifacts')).listSync().whereType<File>().single;
        setUp(() {
          home = Directory.systemTemp.createTempSync('mplatrol_home');
          when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': home.path});
        });
        tearDown(() => home.deleteSync(recursive: true));

        test('records the upload and reuses it without building or uploading', () async {
          final fresh = await buildHyperexecute(shards: [sampleShard]);
          final saved = jsonDecode(record().readAsStringSync()) as Map;
          expect(saved, {'schema': 1, 'identity': isNotEmpty, 'app': fresh!.appId, 'test': fresh.testSuiteAppId});
          File(hyperexecuteInputsPath()).deleteSync();

          final reused = await buildHyperexecute(shards: [sampleShard]);

          expect([reused!.appId, reused.testSuiteAppId], [fresh.appId, fresh.testSuiteAppId]);
          verify(() => shell.stubbedRun(any(that: contains('build-for-testing')))).called(1);
          verify(ltUpload).called(2);
          verify(() => logger.info(any(
              that: allOf(startsWith('[artifact-cache] hit: build identity '),
                  contains('skipping the iOS build, package and upload'))))).called(1);
        });

        test('a lane that generated another runner reuses the record after preparing', () async {
          expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
          File(p.join(appDir.path, 'ios', 'RunnerUITests', 'RunnerUITests.swift'))
              .writeAsStringSync('// another tenant selection');

          expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);

          verify(() => shell.stubbedRun(any(that: contains('build-for-testing')))).called(1);
          verify(ltUpload).called(2);
          verify(() => logger.info(any(that: startsWith('[artifact-cache] hit: ')))).called(1);
        });

        for (final damage in ['malformed', 'old']) {
          test('an $damage record is a miss with the reason', () async {
            expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
            File(hyperexecuteInputsPath()).deleteSync();
            if (damage == 'malformed') {
              record().writeAsStringSync('{"schema": 1, "app": ""}');
            } else {
              record().setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
            }

            expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);

            verify(() => shell.stubbedRun(any(that: contains('build-for-testing')))).called(2);
            verify(() => logger.info(any(
                that: allOf(
                    startsWith('[artifact-cache] miss: the upload recorded for '),
                    contains(damage == 'old' ? ' is 8 days old' : ' is malformed'),
                    endsWith('; building and uploading the iOS pair'))))).called(2);
          });
        }
      });

      test('retries a failed upload and succeeds on a later attempt', () async {
        // First attempt dies in transport (synthetic 599), second is clean.
        var call = 0;
        when(ltUpload).thenAnswer(
          (_) async => call++ == 0 ? http.Response('transport failed', 599) : http.Response(_ltUploadAppOk, 200),
        );

        final artifacts = await buildHyperexecute(shards: [sampleShard]);

        expect(artifacts, isNotNull);
        // App IPA: 1 failed + 1 clean attempt; test-suite IPA: 1 clean.
        verify(ltUpload).called(3);
      });

      test('fails when uploads never succeed', () async {
        when(ltUpload).thenAnswer((_) async => http.Response('upstream 502', 502));

        final artifacts = await buildHyperexecute(shards: [sampleShard]);

        expect(artifacts, isNull);
        verify(() => logger.err(any(that: contains('failed after 6 attempts')))).called(1);
        verify(() => logger.info(any(that: startsWith('lesson lambdaTestUpload (observed 1): ')))).called(1);
      });

      test('--reuse-last fails when the full runner IPA is missing', () async {
        addSecondTest();
        final fileSystem = getDep<FileSystem>();
        when(() => fileSystem.fileExistsSync(any())).thenAnswer((invocation) {
          final path = invocation.positionalArguments.first as String;
          return p.basename(path) == 'Runner.ipa';
        });

        final artifacts = await buildHyperexecute(shards: [sampleShard, secondShard], reuseLast: true, target: null);

        expect(artifacts, isNull);
        verify(
          () => logger.err(
            any(that: allOf(contains('missing HyperExecute IPA(s)'), contains('RunnerUITests-Runner.ipa'))),
          ),
        ).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
      });

      for (final explicit in [false, true]) {
        test('unchanged compiled pair reuses without hidden build: explicit=$explicit', () async {
          expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
          clearInteractions(shell);
          clearInteractions(ltHttp);
          expect(await buildHyperexecute(shards: [sampleShard], reuseLast: explicit), isNotNull);
          verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
          verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
          verifyNever(() => runArgsMatch(exe: equals('zip')));
          verify(ltUpload).called(2);
        });
      }
      for (final value in [null, 'stale-digest']) {
        test('missing or malformed compiled identity is refused: $value', () async {
          expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
          final file = File(hyperexecuteInputsPath());
          final receipt = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          receipt['identity'] = value;
          file.writeAsStringSync(jsonEncode(receipt));
          clearInteractions(shell);
          clearInteractions(ltHttp);
          expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
          verifyNever(ltUpload);
          verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
        });
      }
      test('legacy metadata-only receipt cannot authorize explicit reuse', () async {
        File(hyperexecuteInputsPath()).writeAsStringSync(hyperexecuteInputsJson());
        File(p.join(productsDir.path, 'RunnerUITests-Runner.ipa')).writeAsStringSync('old');
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
        verifyNever(ltUpload);
      });
      test('compiled coordinator URL requires an exact endpoint, including port', () async {
        expect(await buildHyperexecute(shards: [sampleShard], selectionCoordinatorUrl: 'http://localhost:1234/assign'),
            isNotNull);
        clearInteractions(shell);
        expect(
            await buildHyperexecute(
                shards: [sampleShard], reuseLast: true, selectionCoordinatorUrl: 'http://localhost:1234/assign'),
            isNotNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
        expect(
            await buildHyperexecute(
                shards: [sampleShard], reuseLast: true, selectionCoordinatorUrl: 'http://localhost:1235/assign'),
            isNull);
      });

      group('SDK selection identity', () {
        void writeRepoFile(String relative, String content) => File(p.join(appDir.path, relative))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

        void writeRequirements({required String registrationNote}) {
          writeRepoFile('.flutter-plugins-dependencies', '{"plugins":{"android":[],"ios":[]}}');
          writeRepoFile('pubspec.lock', 'packages: {}');
          writeRepoFile('lib/core/feature_registrations.dart', '// core build\n');
          writeRepoFile(
              patrolSdkRequirementsPath,
              jsonEncode({
                'schema': 1,
                'capabilities': <String, Object?>{},
                'unresolvedRegistrations': <Object?>[],
                'note': registrationNote,
                'tests': [
                  {
                    'file': 'patrol_test/patrol_login_test.dart',
                    'descriptions': ['sample test'],
                    'platforms': ['ios'],
                    'requires': <Object?>[],
                    'coverage': 'journey',
                  },
                ],
              }));
        }

        PatrolSelectionPlan planSelection() =>
            planPatrolSdkSelection(appDir.path, platform: 'ios', target: 'patrol_test/patrol_login_test.dart');

        Future<String> compiledIdentity(PatrolSelectionPlan? selection) async {
          expect(await buildHyperexecute(shards: [sampleShard], selection: selection), isNotNull);
          final receipt = jsonDecode(File(hyperexecuteInputsPath()).readAsStringSync()) as Map;
          return receipt['identity'] as String;
        }

        test('compiled-pair identity follows the SDK selection digests', () async {
          writeRequirements(registrationNote: 'first');
          final first = planSelection();
          final withoutSelection = await compiledIdentity(null);
          final withFirst = await compiledIdentity(first);
          expect(withFirst, isNot(withoutSelection));
          expect(await compiledIdentity(planSelection()), withFirst);

          writeRequirements(registrationNote: 'second');
          final second = planSelection();
          expect(second.requirementsDigest, isNot(first.requirementsDigest));
          expect(await compiledIdentity(second), isNot(withFirst));
        });
      });

      Directory seedHePackage() {
        final root = Directory(p.join(appDir.path, 'third_party', 'native_sdk'));
        for (final input in ['lib/sdk.dart', 'ios/Classes/sdk.m', 'assets/sdk.bin']) {
          File(p.join(root.path, input))
            ..createSync(recursive: true)
            ..writeAsStringSync('original');
        }
        File(p.join(root.path, 'pubspec.yaml'))
            .writeAsStringSync('name: native_sdk\nflutter:\n  assets:\n    - assets/sdk.bin\n');
        File(p.join(appDir.path, '.dart_tool', 'package_config.json')).writeAsStringSync(jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'native_sdk', 'rootUri': root.uri.toString(), 'packageUri': 'lib/'},
          ]
        }));
        return root;
      }

      test('whole-byte source freshness catches same-size edits with restored mtime', () async {
        final source = File(p.join(appDir.path, 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('before');
        final time = source.lastModifiedSync();
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        source.writeAsStringSync('after!');
        source.setLastModifiedSync(time);
        clearInteractions(shell);
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });
      test('build outputs do not contaminate unchanged source reuse', () async {
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        File(p.join(iosDir.path, 'build', 'temporary.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('output');
        clearInteractions(shell);
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });
      test('fresh runtime payload keeps reuse only with identical compiled environment and URL', () async {
        final env = envWithProfile({e2eCredentialsUrlEnv: 'http://localhost:1234/creds?token=one'});
        expect(await buildHyperexecute(shards: [sampleShard], env: env), isNotNull);
        final credentials = File(p.join(appDir.path, defaultE2eDartDefineFile));
        credentials.writeAsStringSync(jsonEncode({
          'E2E_ENVIRONMENT': 'Dev',
          'E2E_USERNAME': 'fresh-user',
          'E2E_PASSWORD': 'fresh-secret',
        }));
        clearInteractions(shell);
        expect(await buildHyperexecute(shards: [sampleShard], env: env), isNotNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
        credentials.writeAsStringSync('{"E2E_ENVIRONMENT":"different"}');
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true, env: env), isNull);
      });
      for (final location in ['source JSON', 'declared asset']) {
        test('$location cannot be excluded as a runtime credential payload', () async {
          final path = location == 'source JSON'
              ? p.join(appDir.path, 'lib', 'configuration.json')
              : p.join(appDir.path, defaultE2eDartDefineFile);
          final file = File(path)..createSync(recursive: true);
          file.writeAsStringSync('{"E2E_ENVIRONMENT":"Dev","feature":"before"}');
          if (location == 'declared asset') {
            File(p.join(appDir.path, 'pubspec.yaml'))
                .writeAsStringSync('name: app\nflutter:\n  assets:\n    - integration_test/\n');
          }
          final env = envWithProfile({e2eDartDefineFileEnv: path});
          expect(await buildHyperexecute(shards: [sampleShard], env: env), isNotNull);
          file.writeAsStringSync('{"E2E_ENVIRONMENT":"Dev","feature":"after!"}');
          clearInteractions(shell);
          expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true, env: env), isNull);
          verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
        });
      }
      for (final explicit in [false, true]) {
        for (final drift in [
          'app Dart',
          'test Dart',
          'native SDK',
          'package Dart',
          'package native',
          'package asset',
          'lockfile',
          'generated Swift',
          'plugin registrant',
          'app IPA',
          'test IPA'
        ]) {
          test('$drift drift never reuses stale pair: explicit=$explicit', () async {
            final dependency = seedHePackage();
            expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
            final path = switch (drift) {
              'app Dart' => p.join(appDir.path, 'lib', 'main.dart'),
              'test Dart' => p.join(appDir.path, 'patrol_test', 'patrol_login_test.dart'),
              'native SDK' => p.join(iosDir.path, 'Pods', 'Vendor', 'source.m'),
              'package Dart' => p.join(dependency.path, 'lib', 'sdk.dart'),
              'package native' => p.join(dependency.path, 'ios', 'Classes', 'sdk.m'),
              'package asset' => p.join(dependency.path, 'assets', 'sdk.bin'),
              'lockfile' => p.join(appDir.path, 'pubspec.lock'),
              'generated Swift' => p.join(iosDir.path, 'RunnerUITests', 'RunnerUITests.swift'),
              'plugin registrant' => p.join(iosDir.path, 'Runner', 'GeneratedPluginRegistrant.m'),
              'app IPA' => p.join(productsDir.path, 'Runner.ipa'),
              _ => p.join(productsDir.path, 'RunnerUITests-Runner.ipa'),
            };
            File(path)
              ..createSync(recursive: true)
              ..writeAsStringSync('// drift\n', mode: FileMode.append);
            clearInteractions(shell);
            clearInteractions(ltHttp);
            final result = await buildHyperexecute(shards: [sampleShard], reuseLast: explicit);
            if (explicit) {
              expect(result, isNull);
              verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
              verifyNever(ltUpload);
            } else {
              expect(result, isNotNull);
              verify(() => shell.stubbedRun(any(that: contains('build-for-testing')))).called(1);
            }
          });
        }
      }
      for (final change in ['credential port', 'credential token', 'compiler']) {
        test('$change invalidates compiled inputs', () async {
          final env = envWithProfile({e2eCredentialsUrlEnv: 'http://localhost:1234/creds?token=one'});
          expect(await buildHyperexecute(shards: [sampleShard], env: env), isNotNull);
          env[e2eCredentialsUrlEnv] = change == 'credential port'
              ? 'http://localhost:1235/creds?token=one'
              : 'http://localhost:1234/creds?token=two';
          if (change == 'compiler') {
            env[e2eCredentialsUrlEnv] = 'http://localhost:1234/creds?token=one';
            env['DEVELOPER_DIR'] = '/different/Xcode';
          }
          clearInteractions(shell);
          expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true, env: env), isNull);
          verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
        });
      }
      for (final phase in ['build', 'upload']) {
        test('source drift during $phase cannot publish reusable current artifacts', () async {
          final source = File(p.join(appDir.path, 'lib', 'main.dart'))
            ..createSync(recursive: true)
            ..writeAsStringSync('before');
          if (phase == 'build') {
            when(() => shell.stubbedRun(any(that: contains('build-for-testing')))).thenAnswer((_) async {
              source.writeAsStringSync('after');
              createBuildProductsFixture();
              return _result('');
            });
          } else {
            when(ltUpload).thenAnswer((_) async {
              source.writeAsStringSync('after');
              return http.Response(_ltUploadAppOk, 200);
            });
          }
          expect(await buildHyperexecute(shards: [sampleShard]), isNull);
          verify(() => logger.err(any(that: contains('changed during $phase')))).called(1);
          if (phase == 'build') {
            expect(File(hyperexecuteInputsPath()).existsSync(), isFalse);
            verifyNever(ltUpload);
          }
        });
      }
      for (final resolution in ['missing', 'malformed', 'unversioned', 'remote', 'missing root']) {
        test('unknown $resolution dependency inputs refuse build and reuse', () async {
          final config = File(p.join(appDir.path, '.dart_tool', 'package_config.json'));
          if (resolution == 'missing') {
            config.deleteSync();
          } else if (resolution == 'malformed') {
            config.writeAsStringSync('{private-invalid-json');
          } else if (resolution == 'unversioned') {
            config.writeAsStringSync(jsonEncode({'packages': []}));
          } else {
            config.writeAsStringSync(jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'bad',
                  'rootUri': resolution == 'remote' ? 'https://example.test/pkg/' : '/missing/native/package/',
                  'packageUri': 'lib/'
                },
              ]
            }));
          }
          expect(await buildHyperexecute(shards: [sampleShard]), isNull);
          verifyNever(ltUpload);
          verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
        });
      }

      Future<void> expectPrepareRefused({List<IosTestShard>? shards, Map<String, String>? env}) async {
        expect(await buildHyperexecute(shards: shards ?? [sampleShard], env: env), isNull);
        verify(() => logger.err(any(that: contains('Preparing iOS HyperExecute IPAs failed (StateError)')))).called(1);
        verifyNever(ltUpload);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      }

      void writePackageConfig(List<Map<String, Object?>> packages) =>
          File(p.join(appDir.path, '.dart_tool', 'package_config.json'))
              .writeAsStringSync(jsonEncode({'configVersion': 2, 'packages': packages}));

      test('missing app pubspec refuses build and reuse', () async {
        File(p.join(appDir.path, 'pubspec.yaml')).deleteSync();
        await expectPrepareRefused();
      });
      test('non-JSON runtime credential input refuses build', () async {
        final path = p.join(appDir.path, 'credentials.txt');
        File(path).writeAsStringSync('E2E_USERNAME=user');
        await expectPrepareRefused(env: envWithProfile({e2eDartDefineFileEnv: path}));
      });
      test('supplied shards that differ from the producer selection refuse build', () async {
        expect(await buildHyperexecute(shards: [secondShard]), isNull);
        verify(() => logger.err(any(that: contains('Selected iOS identities do not match producer inputs')))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });
      test('duplicate resolved package identity refuses build', () async {
        final root = seedHePackage();
        final package = {'name': 'native_sdk', 'rootUri': root.uri.toString(), 'packageUri': 'lib/'};
        writePackageConfig([package, package]);
        await expectPrepareRefused();
      });
      for (final source in ['../escape/', '/absolute/lib/']) {
        test('package source "$source" outside its root refuses build', () async {
          final root = seedHePackage();
          writePackageConfig([
            {'name': 'native_sdk', 'rootUri': root.uri.toString(), 'packageUri': source},
          ]);
          await expectPrepareRefused();
        });
      }
      for (final (name, pubspec) in [
        ('non-map pubspec', '- not\n- a map\n'),
        ('non-map flutter section', 'name: native_sdk\nflutter: assets\n'),
        ('parent-relative asset', 'name: native_sdk\nflutter:\n  assets:\n    - ../outside.bin\n'),
        ('absolute asset', 'name: native_sdk\nflutter:\n  assets:\n    - /etc/hosts\n'),
      ]) {
        test('package with $name refuses build', () async {
          final root = seedHePackage();
          File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(pubspec);
          await expectPrepareRefused();
        });
      }
      test('package without a pubspec still fingerprints its sources', () async {
        final root = seedHePackage();
        File(p.join(root.path, 'pubspec.yaml')).deleteSync();
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        File(p.join(root.path, 'lib', 'sdk.dart')).writeAsStringSync('changed');
        clearInteractions(shell);
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });
      test('declared font asset drift never reuses a stale pair', () async {
        final font = File(p.join(appDir.path, 'fonts', 'app.ttf'))
          ..createSync(recursive: true)
          ..writeAsStringSync('font-v1');
        File(p.join(appDir.path, 'pubspec.yaml'))
            .writeAsStringSync('name: app\nflutter:\n  fonts:\n    - family: AppFont\n'
                '      fonts:\n        - asset: fonts/app.ttf\n');
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        clearInteractions(shell);
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNotNull);
        font.writeAsStringSync('font-v2');
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });
      test('symlinked source input fingerprints its target bytes', () async {
        final target = File(p.join(appDir.parent.path, 'shared', 'feature.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('before');
        Link(p.join(appDir.path, 'lib', 'feature.dart')).createSync(target.path, recursive: true);
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        target.writeAsStringSync('after!');
        clearInteractions(shell);
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });
      test('cyclic directory link in compiled inputs refuses build', () async {
        final lib = Directory(p.join(appDir.path, 'lib'))..createSync();
        Link(p.join(lib.path, 'loop')).createSync(lib.path);
        await expectPrepareRefused();
      });
      test('unsupported file type in compiled inputs refuses build', () async {
        final lib = Directory(p.join(appDir.path, 'lib'))..createSync();
        final fifo = Process.runSync('mkfifo', [p.join(lib.path, 'pipe')]);
        expect(fifo.exitCode, 0, reason: '${fifo.stderr}');
        await expectPrepareRefused();
      });
      test('compiler environment change between receipt check and upload refuses upload', () async {
        expect(await buildHyperexecute(shards: [sampleShard]), isNotNull);
        clearInteractions(ltHttp);
        var calls = 0;
        when(() => getDep<PlatformWrapper>().environment).thenAnswer((_) => calls++ == 0
            ? const {'CODESIGN_TEAM': 'TEAMID1234'}
            : const {'CODESIGN_TEAM': 'TEAMID1234', 'DEVELOPER_DIR': '/changed/Xcode'});
        expect(await buildHyperexecute(shards: [sampleShard], reuseLast: true), isNull);
        verify(() => logger.err(any(that: contains('changed before upload')))).called(1);
        verifyNever(ltUpload);
      });

      test('bundles only the targetRegex selection under file-basename groups', () async {
        addSecondTest();

        final artifacts = await buildRunner().buildIosForHyperexecute(
          target: null,
          targetRegex: 'sample',
          env: envWithProfile(),
          shards: [sampleShard],
        );

        expect(artifacts, isNotNull);
        verify(() => logger.info('[bundle] $iosPatrolTestBundleFile -> patrol_login_test')).called(1);
        final bundle = File(p.join(appDir.path, 'patrol_test', iosPatrolTestBundleFile)).readAsStringSync();
        expect(bundle, contains("group('patrol_login_test'"));
        expect(bundle, isNot(contains('b_test')));
        expect(bundle, isNot(contains('mplatrol_filtered_test')));
      });

      // Regression: `lt-all --target` runs this build concurrently with the
      // Android arm, whose `patrol build android` regenerates Patrol's shared
      // test_bundle.dart around its mplatrol_filtered_test wrapper. iOS used to
      // compile that shared file, so Dart reported "mplatrol_filtered_test <file>
      // <description>" names the verdict rejected, and iOS deleted Android's
      // wrapper mid-build.
      test('lt-all: iOS compiles its own bundle while Android rewrites the shared one', () async {
        final testDir = p.join(appDir.path, 'patrol_test');
        const androidBundle = "group('mplatrol_filtered_test', () {});";
        final androidWrapper = File(p.join(testDir, 'mplatrol_filtered_test.dart'))..writeAsStringSync('// android');
        String? compiledTarget;
        when(() => shell.stubbedRun(any(that: contains('flutter build ios')))).thenAnswer((invocation) async {
          final script = invocation.positionalArguments.first as String;
          compiledTarget = RegExp("--target='([^']+)'").firstMatch(script)![1];
          return _result('');
        });
        when(() => shell.stubbedRun(any(that: contains('build-for-testing')))).thenAnswer((_) async {
          File(p.join(testDir, 'test_bundle.dart')).writeAsStringSync(androidBundle);
          return _result('');
        });

        final artifacts = await buildHyperexecute(shards: [sampleShard]);

        expect(artifacts, isNotNull);
        final compiled = File(p.join(appDir.path, compiledTarget!)).readAsStringSync();
        expect(compiled, contains("group('patrol_login_test', () { patrol_login_test.main(); });"));
        expect(compiled, isNot(contains('mplatrol_filtered_test')));
        expect(androidWrapper.readAsStringSync(), '// android');
        expect(File(p.join(testDir, 'test_bundle.dart')).readAsStringSync(), androidBundle);
      });
    });

    group('lambdatest upload', () {
      test('uploads the app + test IPAs directly and uses the returned app id', () async {
        await runDefault();

        verify(
          () => ltUpload(
            url: contains('app/upload/realDevice'),
            fields: containsPair('name', anything),
            filePath: endsWith('.ipa'),
          ),
        ).called(2);
        // The app id from the upload must be forwarded into the trigger payload.
        verify(() => ltTrigger(body: containsPair('app', 'lt://APP_ID'))).called(1);
      });

      test('keeps LambdaTest upload status on progress spinners', () async {
        await runDefault();

        verify(() => logger.progress('Uploading Runner.ipa to LambdaTest')).called(1);
        verify(() => logger.progress('Uploading RunnerUITests-Runner.ipa to LambdaTest')).called(1);
        verifyNever(() => logger.info(any(that: contains('[upload] Runner.ipa -> LambdaTest'))));
        verifyNever(() => logger.info(any(that: contains('[upload] RunnerUITests-Runner.ipa -> LambdaTest'))));
      });

      test('accepts test_url as the id when app_url is absent', () async {
        when(ltUpload).thenAnswer((_) async => http.Response('{"test_url": "lt://TEST_ID"}', 200));

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        verify(() => ltTrigger(body: containsPair('app', 'lt://TEST_ID'))).called(1);
      });

      test('fails when the LambdaTest upload request throws', () async {
        when(ltUpload).thenThrow(Exception('network'));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('LambdaTest iOS run failed')))).called(1);
      });

      test(
          'fails after retries when the upload keeps returning an error '
          'status', () async {
        when(ltUpload).thenAnswer((_) async => http.Response('upstream 502', 502));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        // 6 attempts for the first (app) IPA and 6 more in its one
        // infrastructure retry, then the runner gives up.
        verify(ltUpload).called(12);
        verify(() =>
                logger.err(any(that: contains('LambdaTest upload of PatrolIOS-abc1234-app failed after 6 attempts'))))
            .called(1);
        verify(() => logger.info(any(that: startsWith('lesson lambdaTestUpload (observed 1): ')))).called(1);
      });

      test('retries, then fails, when the LambdaTest upload returns no id', () async {
        when(ltUpload).thenAnswer((_) async => http.Response('{"other": "value"}', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(ltUpload).called(12);
        verify(() => logger.err(any(that: contains('failed after 6 attempts (HTTP 200): {"other": "value"}'))))
            .called(1);
      });

      test('retries, then fails, when the LambdaTest upload returns non-JSON', () async {
        when(ltUpload).thenAnswer((_) async => http.Response('<html>502</html>', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('failed after 6 attempts (HTTP 200): <html>502</html>')))).called(1);
      });

      test('a refused upload fails at once and is no LambdaTest failure', () async {
        when(ltUpload).thenAnswer((_) async => http.Response('{"message": "Unauthorized"}', 401));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(ltUpload).called(1);
        verify(() => logger.err('LambdaTest refused the upload of PatrolIOS-abc1234-app (HTTP 401): '
            '{"message": "Unauthorized"}')).called(1);
        verifyNever(() => logger.info(any(that: startsWith('lesson lambdaTestUpload'))));
      });
    });

    group('trigger', () {
      test('omits tunnel fields when the tunnel name is empty', () async {
        stubTunnel(name: '');

        await runDefault();

        verify(
          () => ltTrigger(
            body: predicate<Map<String, dynamic>>(
              (body) => !body.containsKey('tunnelName'),
              'triggers without tunnel fields',
            ),
          ),
        ).called(1);
      });

      test('includes the tunnel + idle timeout when set', () async {
        await runDefault(idleTimeoutSeconds: 300);

        verify(
          () => ltTrigger(
            body: allOf(
              containsPair('tunnel', true),
              containsPair('tunnelName', _tunnelName),
              containsPair('idleTimeout', 300),
            ),
          ),
        ).called(1);
      });

      test('accepts a buildId returned as a list', () async {
        when(ltTrigger).thenAnswer((_) async => http.Response('{"buildId": ["BID-FROM-LIST", "BID-2"]}', 200));

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        verify(() => ltPoll(url: contains('builds/BID-FROM-LIST'))).called(1);
      });

      test('fails when the trigger request throws', () async {
        when(ltTrigger).thenThrow(Exception('network'));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('LambdaTest iOS run failed')))).called(1);
      });

      test('fails when the trigger returns an error status', () async {
        when(ltTrigger).thenAnswer((_) async => http.Response('bad request', 400));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('Triggering the XCUITest run failed')))).called(1);
      });

      test('fails when the trigger response is non-JSON', () async {
        when(ltTrigger).thenAnswer((_) async => http.Response('not json', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('non-JSON response')))).called(1);
      });

      test('fails when the trigger response has an empty buildId list', () async {
        when(ltTrigger).thenAnswer((_) async => http.Response('{"buildId": []}', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('No buildId')))).called(1);
      });

      test('fails when the trigger response has a null buildId', () async {
        when(ltTrigger).thenAnswer((_) async => http.Response('{"buildId": null}', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('No buildId')))).called(1);
      });
    });

    group('poll', () {
      group('native XCTest evidence', () {
        for (final mutation in [
          'missing',
          'wrong class',
          'wrong method',
          'skipped',
          'failed',
          'unfinished',
          'duplicate',
          'missing completion',
          'failed completion',
          'restart after completion',
          'runtime skip',
          'wrong count',
        ]) {
          test('$mutation cannot pass a provider-green build', () async {
            final identity = iosTestShards(appDir.path).single.onlyTesting;
            final parts = identity.split('/');
            final valid = _nativeXCTestLog(identity);
            final log = switch (mutation) {
              'missing' => '',
              'wrong class' => valid.replaceAll(parts[0], 'OtherTests'),
              'wrong method' => valid.replaceAll(parts[1], 'testOtherJourney'),
              'skipped' => valid.replaceFirst('passed (2.0', 'skipped (2.0'),
              'failed' => valid.replaceFirst('passed (2.0', 'failed (2.0'),
              'unfinished' => valid.split('\n').first,
              'duplicate' => '${valid.split("\n")[1]}\n$valid',
              'missing completion' => valid.split('\n').take(2).join('\n'),
              'failed completion' => valid.replaceFirst("' passed at", "' failed at"),
              'restart after completion' => valid + valid.split('\n').first,
              'runtime skip' => '$valid\nMPLATROL_TEST_SKIPPED missing_credentials',
              _ => valid.replaceFirst('Executed 1 test', 'Executed 2 tests'),
            };
            when(() => ltPoll(url: contains('/log/instrumentation'))).thenAnswer((_) async => http.Response(log, 200));
            expect(await runDefault(), ExitCode.software.code);
            verifyNever(() => logger.success(any(that: contains('passed'))));
            if (mutation == 'missing') {
              verify(() => logger.err(any(
                    that: contains('native XCTest results do not exhaust selected identities'),
                  ))).called(1);
            }
            if (mutation == 'skipped') {
              verify(() => logger.err(any(
                    that: contains('native XCTest skipped, failed, duplicated or did not finish'),
                  ))).called(1);
            }
          });
        }
        for (final status in [403, 404, 503]) {
          test('native log HTTP $status is fetched once and cannot pass', () async {
            when(() => ltPoll(url: contains('/log/instrumentation')))
                .thenAnswer((_) async => http.Response('unavailable', status));
            expect(await runDefault(), ExitCode.software.code);
            verify(() => ltPoll(url: contains('/log/instrumentation'))).called(1);
            verify(() => logger.err(any(
                  that: contains('Native evidence GET failed (HTTP $status)'),
                ))).called(1);
          });
        }
        for (final mutation in ['missing', 'wrong build', 'skipped', 'unfinished', 'partial', 'miscounted']) {
          test('$mutation session evidence cannot pass', () async {
            final session = <String, Object>{
              'session_id': 'SID-BID-1',
              'build_id': 'BID-1',
              'status_ind': 'passed',
            };
            if (mutation == 'wrong build') {
              session['build_id'] = 'OTHER-BUILD';
            }
            if (mutation == 'skipped') {
              session['status_ind'] = 'skipped';
            }
            if (mutation == 'unfinished') {
              session['status_ind'] = 'running';
            }
            when(() => ltPoll(url: contains('/sessions?build_id='))).thenAnswer(
              (_) async => http.Response(
                  jsonEncode({
                    'data': mutation == 'missing' ? [] : [session],
                    if (mutation == 'partial') 'metadata': {'hasmore': true, 'total': 2},
                    if (mutation == 'miscounted') 'metadata': {'hasmore': false, 'total': 2},
                  }),
                  200),
            );
            expect(await runDefault(), ExitCode.software.code);
            verifyNever(() => logger.success(any(that: contains('passed'))));
            if (mutation == 'missing') {
              verify(() => logger.err(any(
                    that: contains('Current build native session inventory is incomplete'),
                  ))).called(1);
            }
            if (mutation == 'partial' || mutation == 'miscounted') {
              verify(() => logger.err(any(that: contains('Native session pagination is incomplete or malformed'))))
                  .called(1);
            }
          });
        }
        test('complete session pagination metadata with an exact total can pass', () async {
          when(() => ltPoll(url: contains('/sessions?build_id='))).thenAnswer(
            (_) async => http.Response(
                jsonEncode({
                  'data': [
                    {'session_id': 'SID-BID-1', 'status_ind': 'passed'},
                  ],
                  'metadata': {'hasmore': false, 'total': 1},
                }),
                200),
          );
          expect(await runDefault(), ExitCode.success.code);
        });
        for (final phase in ['trigger', 'native log', 'native JSON']) {
          test('$phase failure logs exclude external secrets and URLs', () async {
            const secret = 'PRIVATE_AUTH_TOKEN';
            const url = 'https://user:PRIVATE_AUTH_TOKEN@example.test/private';
            if (phase == 'trigger') {
              when(ltTrigger).thenThrow(http.ClientException(secret, Uri.parse(url)));
            } else if (phase == 'native log') {
              when(() => ltPoll(url: contains('/log/instrumentation')))
                  .thenThrow(http.ClientException(secret, Uri.parse(url)));
            } else {
              when(() => ltPoll(url: contains('/sessions?build_id=')))
                  .thenAnswer((_) async => http.Response('$secret $url', 200));
            }
            expect(await runDefault(), ExitCode.software.code);
            final messages = verify(() => logger.err(captureAny())).captured.join('\n');
            expect(messages, isNot(contains(secret)));
            expect(messages, isNot(contains(url)));
            expect(messages, contains(phase == 'native JSON' ? 'FormatException' : 'ClientException'));
          });
        }
        for (final value in <Object?>[
          28216933,
          '28216933',
          '028216933',
          28216934,
          '28216934',
          28216933.0,
          '2.8216933e7',
          '28216933.0',
          ' 28216933',
          '28216933\n',
          0,
          -1,
          null,
          true,
        ]) {
          test('build identity ${value.runtimeType}: $value is exact and typed', () async {
            when(ltTrigger).thenAnswer((_) async => http.Response(
                  '{"buildId":"28216933"}',
                  200,
                ));
            when(() => ltPoll(url: contains('/sessions?build_id='))).thenAnswer(
              (_) async => http.Response(
                  jsonEncode({
                    'data': [
                      {'session_id': 'SID-28216933', 'build_id': value, 'status_ind': 'passed'},
                    ]
                  }),
                  200),
            );
            final valid =
                value is int && value == 28216933 || value is String && ['28216933', '028216933'].contains(value);
            expect(await runDefault(), valid ? 0 : ExitCode.software.code);
          });
        }
        for (final mutation in [
          'none',
          'missing completion',
          'skipped',
          'wrong identity',
          'coordinator identity',
        ]) {
          test('actual XCTest barrier/ANSI/CRLF projection: $mutation', () async {
            File(p.join(appDir.path, 'patrol_test', 'patrol_login_test.dart'))
                .writeAsStringSync("patrolTest('shard 01', (\$) async {});\n");
            final identity = iosTestShards(appDir.path).single.onlyTesting;
            expect(identity, 'LoginE2ETests/testAShard01');
            final method = identity.split('/').last;
            var log = "Test Suite 'Selected tests' started at 2026-09-30 13:17:38.247.\n"
                "Test Suite 'RunnerUITests.xctest' started at 2026-09-30 13:17:38.248.\n"
                "XCTestOutputBarrierTest Suite 'LoginE2ETests' started at "
                '2026-09-30 13:17:38.248.\n'
                "XCTestOutputBarrierTest Case '-[RunnerUITests.LoginE2ETests $method]' started.\n"
                "Test Case '-[RunnerUITests.LoginE2ETests $method]' passed (62.769 seconds).\n"
                "XCTestOutputBarrierTest Suite 'LoginE2ETests' passed at "
                '2026-09-30 13:18:41.018.\n'
                '\t Executed 1 test, with 0 failures (0 unexpected) in 62.769 (62.771) seconds\n'
                "XCTestOutputBarrierTest Suite 'RunnerUITests.xctest' passed at "
                '2026-09-30 13:18:41.020.\n'
                '\t Executed 1 test, with 0 failures (0 unexpected) in 62.769 (62.773) seconds\n'
                "XCTestOutputBarrierTest Suite 'Selected tests' passed at "
                '2026-09-30 13:18:41.023.\n'
                '\t Executed 1 test, with 0 failures (0 unexpected) in 62.769 (62.776) seconds\n';
            if (mutation == 'missing completion') {
              log = log.replaceFirst(
                RegExp(r"XCTestOutputBarrierTest Suite 'LoginE2ETests' passed[^\n]*\n"),
                '',
              );
            } else if (mutation == 'skipped') {
              log = log.replaceFirst('passed (62.769', 'skipped (62.769');
            } else if (mutation == 'wrong identity') {
              log = log.replaceAll(method, 'testOtherJourney');
            } else if (mutation == 'coordinator identity') {
              log = log.replaceAll(method, 'testShard01');
            }
            log = log.split('\n').map((line) => '\x1B[32m$line\x1B[0m').join('\r\n');
            when(() => ltPoll(url: contains('/log/instrumentation'))).thenAnswer((_) async => http.Response(log, 200));
            expect(await runDefault(), mutation == 'none' ? 0 : ExitCode.software.code);
          });
        }
        test('module-qualified XCTest class preserves exact selected identity', () async {
          final identity = iosTestShards(appDir.path).single.onlyTesting;
          final log = _nativeXCTestLog(identity).replaceAll(
            'LoginE2ETests',
            'RunnerUITests.LoginE2ETests',
          );
          when(() => ltPoll(url: contains('/log/instrumentation'))).thenAnswer((_) async => http.Response(log, 200));
          expect(await runDefault(), ExitCode.success.code);
        });
      });
      test('returns success when the run reaches a passing status', () async {
        final result = await runDefault();

        expect(result, ExitCode.success.code);
        verify(() => logger.success(any(that: contains('passed')))).called(1);
      });

      test('returns success when the run reaches "completed"', () async {
        when(() => ltPoll(url: contains('/builds/')))
            .thenAnswer((_) async => http.Response('{"data": {"status_ind": "completed"}}', 200));

        final result = await runDefault();

        expect(result, ExitCode.success.code);
      });

      test('lower-cases status_ind so an upper-case PASSED is a pass', () async {
        when(() => ltPoll(url: contains('/builds/')))
            .thenAnswer((_) async => http.Response('{"data": {"status_ind": "PASSED"}}', 200));

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        verify(() => logger.success(any(that: contains('passed')))).called(1);
      });

      test('lower-cases status_ind so an upper-case FAILED is terminal', () async {
        when(() => ltPoll(url: contains('/builds/')))
            .thenAnswer((_) async => http.Response('{"data": {"status_ind": "FAILED"}}', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('did not pass')))).called(1);
      });

      test('returns a failure exit when the run fails', () async {
        when(() => ltPoll(url: contains('/builds/')))
            .thenAnswer((_) async => http.Response('{"data": {"status_ind": "failed"}}', 200));

        final result = await runDefault();

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('did not pass')))).called(1);
      });

      test('keeps polling past a non-terminal status until terminal', () async {
        var calls = 0;
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async {
          calls++;
          return calls == 1
              ? http.Response('{"data": {"status_ind": "running"}}', 200)
              : http.Response(_passBuild, 200);
        });

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        expect(calls, greaterThanOrEqualTo(2));
      });

      test('treats a thrown poll error as not-yet-terminal', () async {
        var calls = 0;
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async {
          calls++;
          if (calls == 1) {
            throw Exception('transient timeout');
          }
          return http.Response(_passBuild, 200);
        });

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        expect(calls, greaterThanOrEqualTo(2));
      });

      test('treats a non-JSON poll body as not-yet-terminal', () async {
        var calls = 0;
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async {
          calls++;
          return calls == 1 ? http.Response('<html>502</html>', 200) : http.Response(_passBuild, 200);
        });

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        expect(calls, greaterThanOrEqualTo(2));
      });

      test('treats a JSON array poll body as not-yet-terminal', () async {
        var calls = 0;
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async {
          calls++;
          return calls == 1 ? http.Response('[]', 200) : http.Response(_passBuild, 200);
        });

        final result = await runDefault();

        expect(result, ExitCode.success.code);
      });

      test('treats a missing data object as not-yet-terminal', () async {
        var calls = 0;
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async {
          calls++;
          return calls == 1 ? http.Response('{"data": "oops"}', 200) : http.Response(_passBuild, 200);
        });

        final result = await runDefault();

        expect(result, ExitCode.success.code);
      });

      test('treats a missing/blank status_ind as not-yet-terminal', () async {
        var calls = 0;
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((_) async {
          calls++;
          return calls == 1 ? http.Response('{"data": {"status_ind": ""}}', 200) : http.Response(_passBuild, 200);
        });

        final result = await runDefault();

        expect(result, ExitCode.success.code);
      });

      test('fails when a per-test build never reaches a terminal status', () async {
        when(() => ltPoll(url: contains('/builds/')))
            .thenAnswer((_) async => http.Response('{"data": {"status_ind": "running"}}', 200));

        final result = await runDefault();

        // A stuck per-test build is aggregated as a failed run (software); the
        // poller still logs the never-terminal reason.
        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('did not reach a terminal status')))).called(1);
      });

      test(
          'sizes the poll budget from queueTimeout + idleTimeout when the poll '
          'delay is non-zero', () async {
        // A non-zero poll delay drives the budget through the real
        // attempts = ceil((queueTimeout + idleTimeout + margin) / delay)
        // path (not the zero-delay floor). A terminal-on-first-poll status
        // returns before any wait actually elapses.
        final result = await runDefault(pollDelay: const Duration(seconds: 1));

        expect(result, ExitCode.success.code);
        verify(() => logger.success(any(that: contains('passed')))).called(1);
      });
    });

    group('cache', () {
      test('caches the per-test app + test ids after a normal run', () async {
        final fileSystem = getDep<FileSystem>();
        when(
          () => fileSystem.writeAsStringSync(
            filePath: any(named: 'filePath'),
            newContent: any(named: 'newContent'),
          ),
        ).thenReturn(null);

        final result = await runDefault();

        expect(result, ExitCode.success.code);
        // The fixture has one test, so a normal run is one per-test build; its
        // ids + name are written to the per-test cache (lt-last-pertest.json),
        // NOT the single-build lt-last.json. The happy-path upload returns
        // app_url 'lt://APP_ID' for both the app and the test register.
        verify(
          () => fileSystem.writeAsStringSync(
            filePath: any(named: 'filePath', that: endsWith('lt-last-pertest.json')),
            newContent: any(
              named: 'newContent',
              that: allOf(contains('lt://APP_ID'), contains('"name":"sample test"')),
            ),
          ),
        ).called(1);
        // The single-build cache is left untouched on the per-test path.
        verifyNever(
          () => fileSystem.writeAsStringSync(
            filePath: any(named: 'filePath', that: endsWith('lt-last.json')),
            newContent: any(named: 'newContent'),
          ),
        );
      });
    });

    group('per-test builds', () {
      /// Adds a second Patrol test file so a whole-suite run discovers two
      /// shards (the setUp fixture already wrote patrol_login_test.dart with
      /// 'sample test').
      void addSecondTest() => File(
            p.join(appDir.path, 'patrol_test', 'b_test.dart'),
          ).writeAsStringSync("patrolTest('second test', (\$) async {});\n");

      /// Routes each trigger to a distinct buildId so per-build polls can be
      /// stubbed independently. Returns them in trigger order.
      List<String> stubDistinctTriggers() {
        final ids = <String>[];
        when(ltTrigger).thenAnswer((invocation) async {
          final id = 'BID-${ids.length + 1}';
          ids.add(id);
          rememberNativeIdentity(id, invocation);
          return http.Response('{"buildId": "$id"}', 200);
        });
        return ids;
      }

      test('builds one per test, uploads the app once, triggers each by name', () async {
        addSecondTest();

        final result = await runDefault(target: null);

        expect(result, ExitCode.success.code);
        // Two builds → the test .ipa is built+signed+uploaded twice, but the
        // byte-identical app .ipa is uploaded ONCE and reused: 1 app + 2 test
        // uploads = 3 LambdaTest uploads.
        verify(() => ltUpload(url: contains('app/upload/realDevice'))).called(3);
        // One trigger per test, each named after its description and isolating
        // its test via the literal target class. (mocktail consumes verified
        // calls, so each name is asserted exactly once with its only-testing.)
        verify(
          () => ltTrigger(
            body: allOf(
              containsPair('build', 'PatrolIOS-abc1234 - sample test'),
              containsPair('only-testing', ['RunnerUITests']),
            ),
          ),
        ).called(1);
        verify(
          () => ltTrigger(
            body: allOf(
              containsPair('build', 'PatrolIOS-abc1234 - second test'),
              containsPair('only-testing', ['RunnerUITests']),
            ),
          ),
        ).called(1);
      });

      test('regenerates RunnerUITests to one test per build', () async {
        addSecondTest();

        await runDefault(target: null);

        // The generated runner ends with whichever test was built last; across
        // the run each build held exactly one Swift test method. Assert the file
        // on disk has a single generated method (the last build's).
        final runner = File(
          p.join(appDir.path, 'ios', 'RunnerUITests', 'RunnerUITests.swift'),
        ).readAsStringSync();
        final methodCount = RegExp('  func test[A-Z]').allMatches(runner).length;
        expect(methodCount, 1);
      });

      test('caches every per-test build (app once, all tests)', () async {
        final fileSystem = getDep<FileSystem>();
        when(
          () => fileSystem.writeAsStringSync(
            filePath: any(named: 'filePath'),
            newContent: any(named: 'newContent'),
          ),
        ).thenReturn(null);
        addSecondTest();

        await runDefault(target: null);

        verify(
          () => fileSystem.writeAsStringSync(
            filePath: any(named: 'filePath', that: endsWith('lt-last-pertest.json')),
            newContent: any(
              named: 'newContent',
              that: allOf(contains('"name":"sample test"'), contains('"name":"second test"')),
            ),
          ),
        ).called(1);
      });

      test('fails and names the failing test when one per-test build fails', () async {
        addSecondTest();
        final ids = stubDistinctTriggers();
        // iOS runner ordering puts the happy login shard first. Fail only that
        // build's poll; the other stays passing.
        when(() => ltPoll(url: contains('/builds/'))).thenAnswer((invocation) async {
          final url = invocation.positionalArguments.first as String;
          final failing = ids.isNotEmpty && url.contains(ids[0]);
          return http.Response(failing ? '{"data": {"status_ind": "failed"}}' : _passBuild, 200);
        });

        final result = await runDefault(target: null);

        expect(result, ExitCode.software.code);
        // The aggregate line + the named failing test are both logged.
        verify(() => logger.err(any(that: contains('❌ sample test')))).called(1);
        verify(() => logger.info(any(that: contains('1/2 passed')))).called(1);
      });

      test('bundles the targetRegex selection for each per-test build', () async {
        final result = await buildRunner().run(
          target: 'patrol_test/patrol_login_test.dart',
          targetRegex: 'sample',
          devices: const ['iPhone 17 Pro-26'],
          idleTimeoutSeconds: 240,
          env: envWithProfile(),
        );

        expect(result, ExitCode.success.code);
        verify(() => logger.info('[bundle] $iosPatrolTestBundleFile -> patrol_login_test'))
            .called(greaterThanOrEqualTo(1));
        expect(File(p.join(appDir.path, 'patrol_test', 'mplatrol_filtered_test.dart')).existsSync(), isFalse);
      });
    });

    group('whole-suite fallback (no discovered tests)', () {
      /// Replaces the Patrol fixture with an empty selection.
      void emptyFixtureTest() => File(
            p.join(appDir.path, 'patrol_test', 'patrol_login_test.dart'),
          ).writeAsStringSync('void main() {}\n');

      test('empty selection refuses build, upload and dispatch', () async {
        emptyFixtureTest();

        final result = await runDefault(target: null);

        expect(result, ExitCode.unavailable.code);
        verify(() => logger.err(any(that: contains('No selected XCTest identities')))).called(1);
        verifyNever(ltUpload);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
        verifyNever(
          () => ltHttp.postJson(
            any(that: contains('xcui/build')),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
          ),
        );
      });

      test('--reuse-last refuses a whole-suite cache without selected identities', () async {
        final fileSystem = getDep<FileSystem>();
        emptyFixtureTest();
        when(() => fileSystem.fileExistsSync(cachePath())).thenReturn(true);
        when(() => fileSystem.readAsStringSync(cachePath())).thenReturn(jsonEncode({
          'app': 'lt://APP_ID',
          'test': 'lt://TEST_ID',
          'nativeGenerator': iosPatrolGeneratorIdentity(),
        }));

        final result = await runDefault(reuseLast: true, target: null);

        expect(result, ExitCode.unavailable.code);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
        verifyNever(ltTrigger);
        verifyNever(ltUpload);
      });
    });

    group('reuse-last', () {
      for (final identity in [null, 'previous-templatrole-digest', '7765c8983e04905c']) {
        test('per-test reuse rejects missing or stale generator: $identity', () async {
          final fileSystem = getDep<FileSystem>();
          when(() => fileSystem.fileExistsSync(perTestCachePath())).thenReturn(true);
          final cache = jsonDecode(perTestCacheJson()) as Map<String, dynamic>;
          final inputs = cache['inputs'] as Map<String, dynamic>;
          if (identity == null) {
            inputs.remove('nativeGenerator');
          } else {
            inputs['nativeGenerator'] = identity;
          }
          when(() => fileSystem.readAsStringSync(perTestCachePath())).thenReturn(jsonEncode(cache));
          expect(await runDefault(reuseLast: true), ExitCode.usage.code);
          verifyNever(ltTrigger);
          verifyNever(ltUpload);
        });
      }
      test('reuses the per-test cache and skips build + upload', () async {
        final fileSystem = getDep<FileSystem>();
        when(() => fileSystem.fileExistsSync(perTestCachePath())).thenReturn(true);
        when(() => fileSystem.readAsStringSync(perTestCachePath())).thenReturn(perTestCacheJson());

        final result = await runDefault(reuseLast: true);

        expect(result, ExitCode.success.code);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
        verifyNever(ltUpload);
        // The cached app/test ids + the test name drive the one per-test build.
        verify(
          () => ltTrigger(
            body: allOf(
              containsPair('app', 'lt://APP_ID'),
              containsPair('testSuite', 'lt://TEST_ID'),
              containsPair('build', 'PatrolIOS-abc1234 - sample test'),
              containsPair('only-testing', ['RunnerUITests']),
            ),
          ),
        ).called(1);
      });

      test('reused per-test inventory that names other tests refuses dispatch', () async {
        final fileSystem = getDep<FileSystem>();
        when(() => fileSystem.fileExistsSync(perTestCachePath())).thenReturn(true);
        when(() => fileSystem.readAsStringSync(perTestCachePath())).thenReturn(perTestCacheJson(tests: const [
          {'id': 'lt://TEST_ID', 'name': 'renamed test'},
        ]));

        expect(await runDefault(reuseLast: true), ExitCode.unavailable.code);
        verify(() => logger.err(any(that: contains('Cached iOS test inventory does not match')))).called(1);
        verifyNever(ltTrigger);
      });

      test('returns usage when there is no per-test cache', () async {
        final fileSystem = getDep<FileSystem>();
        when(() => fileSystem.fileExistsSync(perTestCachePath())).thenReturn(false);

        final result = await runDefault(reuseLast: true);

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('no per-test LambdaTest cache')))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
      });

      test('returns usage when the per-test cache is empty/invalid', () async {
        final fileSystem = getDep<FileSystem>();
        when(() => fileSystem.fileExistsSync(perTestCachePath())).thenReturn(true);
        when(() => fileSystem.readAsStringSync(perTestCachePath())).thenReturn(perTestCacheJson(tests: const []));

        final result = await runDefault(reuseLast: true);

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('empty or invalid')))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
      });

      test('returns usage when the per-test cache is stale', () async {
        final fileSystem = getDep<FileSystem>();
        when(() => fileSystem.fileExistsSync(perTestCachePath())).thenReturn(true);
        when(
          () => fileSystem.readAsStringSync(perTestCachePath()),
        ).thenReturn('{"app":"lt://APP_ID","tests":[{"id":"lt://TEST_ID","name":"sample test"}]}');

        final result = await runDefault(reuseLast: true);

        expect(result, ExitCode.usage.code);
        verify(() => logger.err(any(that: contains('older')))).called(1);
        verifyNever(() => shell.stubbedRun(any(that: contains('flutter build ios'))));
      });
    });

    // The reusable local-build units `mplatrol build` calls (the LambdaTest
    // `run` path exercises them indirectly; these drive them directly).
    group('buildIosConfigOnly', () {
      test('runs flutter config-only and returns the read-back bundle id', () async {
        final bundleId = await buildRunner().buildIosConfigOnly(target: 'patrol_test/patrol_login_test.dart');

        expect(bundleId, _bundleId);
        verify(() => shell.stubbedRun(any(that: contains('flutter build ios --config-only --profile')))).called(1);
        // It must NOT run xcodebuild — that is the separate phase-2 step.
        verifyNever(() => shell.stubbedRun(any(that: contains('build-for-testing'))));
      });

      test('returns null (after logging) when the bundle id cannot be read', () async {
        when(
          () => shell.stubbedRun(any(that: contains('-showBuildSettings'))),
        ).thenAnswer((_) async => _result('NO BUNDLE ID HERE\n'));

        final bundleId = await buildRunner().buildIosConfigOnly(target: 'patrol_test/patrol_login_test.dart');

        expect(bundleId, isNull);
        verify(() => logger.err(any(that: contains('Could not read PRODUCT_BUNDLE_IDENTIFIER')))).called(1);
      });

      test('returns null (after logging) when the flutter build fails', () async {
        when(
          () => shell.stubbedRun(any(that: contains('flutter build ios'))),
        ).thenAnswer((_) async => _result('', exitCode: 70));

        final bundleId = await buildRunner().buildIosConfigOnly(target: 'patrol_test/patrol_login_test.dart');

        expect(bundleId, isNull);
        verify(() => logger.err(any(that: contains('flutter build ios --config-only failed')))).called(1);
      });
    });

    group('buildIosForTesting', () {
      test('runs build-for-testing and returns success', () async {
        final result = await buildRunner().buildIosForTesting(bundleId: _bundleId);

        expect(result, ExitCode.success.code);
        verify(
          () => shell.stubbedRun(
            any(that: allOf(contains('build-for-testing'), contains('PATROL_TARGET_BUNDLE_ID=$_bundleId'))),
          ),
        ).called(1);
      });

      test('returns software (after logging) when xcodebuild fails', () async {
        when(
          () => shell.stubbedRun(any(that: contains('build-for-testing'))),
        ).thenAnswer((_) async => _result('', exitCode: 65));

        final result = await buildRunner().buildIosForTesting(bundleId: _bundleId);

        expect(result, ExitCode.software.code);
        verify(() => logger.err(any(that: contains('build-for-testing failed')))).called(1);
      });
    });
  });
}
