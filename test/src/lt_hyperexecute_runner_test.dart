import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/ci_report/ci_report.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:mplatrol/src/it_leg_dir.dart';
import 'package:mplatrol/src/it_run_stop.dart';
import 'package:mplatrol/src/lt_android_runner.dart';
import 'package:mplatrol/src/lt_app_upload.dart';
import 'package:mplatrol/src/lt_diagnostics.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_hyperexecute_runner.dart';
import 'package:mplatrol/src/lt_hyperexecute_stall_watchdog.dart';
import 'package:mplatrol/src/lt_ios_runner.dart';
import 'package:mplatrol/src/lt_run_support.dart';
import 'package:mplatrol/src/lt_session_artifacts.dart';
import 'package:mplatrol/src/lt_slot_budget.dart';
import 'package:mplatrol/src/lt_user_session_cap.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _androidEnv = {
  'LT_USERNAME': 'user',
  'LT_ACCESS_KEY': 'key',
  'LT_BIN': '/Users/test/Downloads/LT',
  'LT_BUILD_NAME': 'android-build',
};

Directory _createRepoWithTests() {
  final repo = Directory.systemTemp.createTempSync();
  final patrolDir = Directory(p.join(repo.path, 'patrol_test'))..createSync(recursive: true);
  File(
    p.join(patrolDir.path, 'patrol_login_test.dart'),
  ).writeAsStringSync("patrolTest('first test', (\$) async {});\n");
  File(
    p.join(patrolDir.path, 'login_faults_test.dart'),
  ).writeAsStringSync("patrolTest('second test', (\$) async {});\n");
  return repo;
}

void _stubRepo(Directory repo) {
  _nativeVerdictFixtureRepo = repo.path;
  _seedCoreArtifactRequirements(repo);
  if (discoverPatrolTestFiles(repo.path).isNotEmpty) {
    generateAndroidPatrolRunner(repo.path);
  }
  when(() => getDep<LtAndroidRunner>().buildUploadAndroid(
        repo: any(named: 'repo'),
        tenant: any(named: 'tenant'),
        target: any(named: 'target'),
        buildName: any(named: 'buildName'),
        auth: any(named: 'auth'),
        env: any(named: 'env'),
        reuseLast: any(named: 'reuseLast'),
        targetRegex: any(named: 'targetRegex'),
        sdk: any(named: 'sdk'),
      )).thenAnswer((invocation) async {
    final target = invocation.namedArguments[#target] as String?;
    final targetRegex = invocation.namedArguments[#targetRegex] as String?;
    final sdk = invocation.namedArguments[#sdk] as String?;
    final selection =
        planPatrolSdkSelection(repo.path, platform: 'android', target: target, targetRegex: targetRegex, sdk: sdk);
    generateAndroidPatrolRunner(repo.path, target: target, targetRegex: targetRegex, sdk: sdk, selection: selection);
    return AndroidLtArtifacts(appId: 'lt://APP', testSuiteAppId: 'lt://TEST', selection: selection);
  });
  when(() => getDep<LtIosRunner>().buildIosForHyperexecute(
        target: any(named: 'target'),
        targetRegex: any(named: 'targetRegex'),
        sdk: any(named: 'sdk'),
        env: any(named: 'env'),
        reuseLast: any(named: 'reuseLast'),
        shards: any(named: 'shards'),
        selection: any(named: 'selection'),
        selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
      )).thenAnswer((invocation) async {
    _captureIosCoordinatorFixture(invocation);
    return _iosCoordinatorFixtureArtifacts();
  });
  final fileSystem = getDep<FileSystem>();
  when(
    () => fileSystem.getAppDirectory(
      throwIfNotFound: any(named: 'throwIfNotFound'),
      workingDir: any(named: 'workingDir'),
    ),
  ).thenReturn(repo);
  when(
    () => fileSystem.writeAsStringSync(
      filePath: any(named: 'filePath'),
      newContent: any(named: 'newContent'),
    ),
  ).thenAnswer((invocation) {
    final path = invocation.namedArguments[#filePath] as String;
    final content = invocation.namedArguments[#newContent] as String;
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  });
}

void _writePlanFixture(Directory repo, String relative, String value) {
  File(p.join(repo.path, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(value);
}

void _seedCoreArtifactRequirements(Directory repo) {
  final files = discoverPatrolTestFiles(repo.path);
  _writePlanFixture(repo, '.dart_tool/package_config.json', '{"configVersion":2,"packages":[]}');
  _writePlanFixture(repo, '.flutter-plugins-dependencies', '{"plugins":{"android":[],"ios":[]}}');
  _writePlanFixture(repo, 'pubspec.lock', 'packages: {}');
  _writePlanFixture(repo, 'lib/core/feature_registrations.dart', '// core build\n');
  _writePlanFixture(
      repo,
      patrolSdkRequirementsPath,
      jsonEncode({
        'schema': 1,
        'capabilities': <String, Object?>{},
        'unresolvedRegistrations': <Object?>[],
        'tests': [
          for (final file in files)
            {
              'file': 'patrol_test/${file.basename}.dart',
              'descriptions': file.tests.map((test) => test.description).toList(),
              'platforms': ['android', 'ios', 'ios-simulator'],
              'requires': <Object?>[],
              'coverage': 'journey'
            },
        ],
      }));
}

/// Makes login_faults_test a PinnedSdk journey whose SDK the fixture app builds, so LambdaTest selects it.
void _markPinnedSdkJourney(Directory repo) {
  _writePlanFixture(
      repo,
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final name in ['example_pinnedsdk', 'pinnedsdk_flutter'])
            {'name': name, 'rootUri': '../', 'packageUri': 'lib/'},
        ],
      }));
  _writePlanFixture(
      repo,
      '.flutter-plugins-dependencies',
      jsonEncode({
        'plugins': {
          for (final platform in ['android', 'ios'])
            platform: [
              {'name': 'pinnedsdk_flutter', 'native_build': true}
            ],
        }
      }));
  _writePlanFixture(
      repo,
      'lib/core/feature_registrations.dart',
      '// BEGIN MPLATROL TAG: example_pinnedsdk_registration\n'
          'pinnedsdk.SdkRegistration();\n'
          '// END MPLATROL TAG: example_pinnedsdk_registration\n');
  final manifestFile = File(p.join(repo.path, patrolSdkRequirementsPath));
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
  manifest['certificatePinningSdks'] = ['pinnedsdk'];
  manifest['capabilities'] = {
    'pinnedsdk': {
      'packages': ['example_pinnedsdk', 'pinnedsdk_flutter'],
      'nativePlugins': {
        'android': ['pinnedsdk_flutter'],
        'ios': ['pinnedsdk_flutter']
      },
      'registrations': [
        {
          'source': 'lib/core/feature_registrations.dart',
          'tag': 'example_pinnedsdk_registration',
          'symbol': 'pinnedsdk.SdkRegistration()'
        }
      ]
    },
  };
  (manifest['tests'] as List)
      .cast<Map>()
      .singleWhere((test) => test['file'] == 'patrol_test/login_faults_test.dart')['requires'] = [
    ['pinnedsdk']
  ];
  manifestFile.writeAsStringSync(jsonEncode(manifest));
}

Directory _createExcludedSdkArtifactFixture() {
  final repo = _createRepoWithTests();
  addTearDown(() => repo.deleteSync(recursive: true));
  _writePlanFixture(
      repo, 'patrol_test/neutral_vendor_test.dart', "patrolTest('contact SDK journey', (\$) async {});\n");
  _stubRepo(repo);
  _writePlanFixture(
      repo,
      'lib/core/feature_registrations.dart',
      '// BEGIN MPLATROL TAG: vendor_registration\n'
          '// vendor.SdkRegistration();\n'
          '// END MPLATROL TAG: vendor_registration\n');
  final manifestFile = File(p.join(repo.path, patrolSdkRequirementsPath));
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
  manifest['capabilities'] = {
    'vendor': {
      'packages': ['vendor_api', 'vendor_plugin'],
      'nativePlugins': {
        'android': ['vendor_plugin'],
        'ios': ['vendor_plugin']
      },
      'registrations': [
        {
          'source': 'lib/core/feature_registrations.dart',
          'tag': 'vendor_registration',
          'symbol': 'vendor.SdkRegistration()'
        }
      ]
    },
  };
  final declaration = (manifest['tests'] as List)
      .singleWhere((dynamic test) => test['file'] == 'patrol_test/neutral_vendor_test.dart') as Map;
  declaration['requires'] = [
    ['vendor']
  ];
  manifestFile.writeAsStringSync(jsonEncode(manifest));
  return repo;
}

void _stubArtifactResult(AndroidLtArtifacts artifacts) {
  when(() => getDep<LtAndroidRunner>().buildUploadAndroid(
      repo: any(named: 'repo'),
      tenant: any(named: 'tenant'),
      target: any(named: 'target'),
      buildName: any(named: 'buildName'),
      auth: any(named: 'auth'),
      env: any(named: 'env'),
      reuseLast: any(named: 'reuseLast'),
      targetRegex: any(named: 'targetRegex'),
      sdk: any(named: 'sdk'))).thenAnswer((_) async => artifacts);
}

Future<int> _runArtifactPlanFixture({bool reuseLast = false}) =>
    LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null, devices: const ['Pixel 8-14'], idleTimeoutSeconds: 240, env: _androidEnv, reuseLast: reuseLast);

void _registerArtifactBoundSelectionTests() {
  for (final reuseLast in [false, true]) {
    test('artifact plan excludes actual SDK method before HE (reuse=$reuseLast)', () async {
      final repo = _createExcludedSdkArtifactFixture();
      final selection = planPatrolSdkSelection(repo.path, platform: 'android');
      expect(selection.selectedCount, 2);
      expect(selection.excluded.single.reason, 'SDK not built: vendor');
      final wrapper =
          retargetPatrolTestBundle(repo.path, target: null, targetRegex: null, sdk: null, selection: selection);
      generateAndroidPatrolRunner(repo.path, selection: selection);
      final artifacts = AndroidLtArtifacts(appId: 'lt://APP', testSuiteAppId: 'lt://TEST', selection: selection);
      _stubArtifactResult(artifacts);
      expect(File(p.join(repo.path, wrapper)).readAsStringSync(), isNot(contains('neutral_vendor_test')));
      expect(
          File(p.join(
                  repo.path,
                  'android/app/src/androidTest/java',
                  'mplatrol/e2e/'
                      '${androidPatrolTestClassName('neutral_vendor_test')}.java'))
              .existsSync(),
          isFalse);
      expect(artifacts.selectedNativeTests, hasLength(2));
      expect(await _runArtifactPlanFixture(reuseLast: reuseLast), ExitCode.success.code);
      final yaml = File(p.join(repo.path, '.mplatrol/hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, isNot(contains('neutral_vendor')));
    });
  }
  test('legacy IDs cannot fall back to source discovery or launch HE', () async {
    final repo = _createRepoWithTests();
    addTearDown(() => repo.deleteSync(recursive: true));
    _stubRepo(repo);
    _stubArtifactResult(AndroidLtArtifacts(appId: 'lt://APP', testSuiteAppId: 'lt://TEST'));
    expect(await _runArtifactPlanFixture(), ExitCode.unavailable.code);
    verifyNever(() => getDep<MplatrolShell>().runArgs(any(), any(),
        workingDirectory: any(named: 'workingDirectory'),
        throwOnError: any(named: 'throwOnError'),
        cancelOn: any(named: 'cancelOn')));
  });
  test('excluded native identity cannot be reconciled as selected coverage', () async {
    final repo = _createExcludedSdkArtifactFixture();
    final selection = planPatrolSdkSelection(repo.path, platform: 'android');
    generateAndroidPatrolRunner(repo.path, selection: selection);
    _stubArtifactResult(AndroidLtArtifacts(appId: 'lt://APP', testSuiteAppId: 'lt://TEST', selection: selection));
    _stubLtGet((url) {
      final sessions = _passedNativeSessions();
      (sessions['data'] as List).add({
        'sessionID': 'foreign-sdk',
        'taskID': 'task-current',
        'status': 'passed',
        'scenario_name': 'mplatrol.e2e.'
            '${androidPatrolTestClassName('neutral_vendor_test')}/'
            '${discoverPatrolTestFiles(repo.path).singleWhere((file) => file.basename == 'neutral_vendor_test').tests.single.method}'
      });
      sessions['metadata']['total'] = 3;
      return http.Response(jsonEncode(url.contains('/sessions?') ? sessions : _passedJob()), 200);
    }, includePassedJob: false);
    expect(await _runArtifactPlanFixture(), ExitCode.unavailable.code);
  });
}

PatrolSelectionPlan _malformedArtifactPlan(PatrolSelectionPlan plan, String kind) => PatrolSelectionPlan(
      repo: plan.repo,
      platform: kind == 'wrong platform' ? 'ios' : plan.platform,
      files: kind == 'empty'
          ? []
          : [
              ...plan.files,
              if (kind == 'duplicate identities') plan.files.first,
            ],
      excluded: plan.excluded,
      requirementsDigest: plan.requirementsDigest,
      capabilityDigest: plan.capabilityDigest,
      sourceDigests: {},
      coverage: plan.coverage,
    );

PatrolSelectionPlan _invalidArtifactPlan(Directory repo, String kind) {
  final plan = planPatrolSdkSelection(repo.path, platform: 'android');
  switch (kind) {
    case 'request changed':
      return planPatrolSdkSelection(repo.path, platform: 'android', target: 'patrol_test/patrol_login_test.dart');
    case 'source changed':
      File(p.join(repo.path, 'patrol_test/patrol_login_test.dart'))
          .writeAsStringSync('// changed after upload\n', mode: FileMode.append);
      return plan;
    case 'plan mutated':
      plan.files.first.tests.first.method = 'different_method';
      return plan;
    default:
      return _malformedArtifactPlan(plan, kind);
  }
}

void _registerIosSelectionRefusalTests() {
  test('iOS run refuses a missing Patrol target with a config exit before any build', () async {
    final repo = _createRepoWithTests();
    addTearDown(() => repo.deleteSync(recursive: true));
    _stubRepo(repo);

    final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: 'patrol_test/missing_test.dart',
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: _iosEnv);

    expect(result, ExitCode.config.code);
    verify(() => getDep<MplatrolLogger>()
        .err(any(that: allOf(startsWith('iOS SDK selection refused:'), contains('missing_test.dart'))))).called(1);
    verifyNever(() => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: any(named: 'target'),
          targetRegex: any(named: 'targetRegex'),
          sdk: any(named: 'sdk'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ));
  });
}

void _registerInvalidArtifactPlanTests() {
  for (final kind in [
    'wrong platform',
    'empty',
    'duplicate identities',
    'request changed',
    'source changed',
    'plan mutated'
  ]) {
    test('artifact plan refuses $kind before HE launch', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubArtifactResult(AndroidLtArtifacts(
          appId: 'lt://APP', testSuiteAppId: 'lt://TEST', selection: _invalidArtifactPlan(repo, kind)));
      expect(await _runArtifactPlanFixture(), ExitCode.unavailable.code);
      verifyNever(() => getDep<MplatrolShell>().runArgs(any(), any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn')));
      verify(() => getDep<MplatrolLogger>().err(any(that: startsWith('HyperExecute Android artifact plan refused:'))))
          .called(1);
    });
  }
}

void _stubLtGet(http.Response Function(String url) router, {bool includePassedJob = true}) {
  when(
    () => getDep<LtHttp>().get(
      any(),
      headers: any(named: 'headers'),
      timeout: any(named: 'timeout'),
    ),
  ).thenAnswer((invocation) async {
    final url = invocation.positionalArguments.single as String;
    if (includePassedJob && url.contains('/log/instrumentation')) {
      final names = _nativeVerdictFixtureNames();
      for (final (index, name) in names.indexed) {
        if (url.contains('/sessions/native-$index/')) {
          if (!_nativeVerdictFixtureAndroid) {
            return http.Response(_iosInstrumentationFixture(index), 200);
          }
          final identity = name.split('/');
          return http.Response(
              'INSTRUMENTATION_STATUS: class=${identity[0]}\n'
              'INSTRUMENTATION_STATUS: test=${identity[1]}\n'
              'INSTRUMENTATION_STATUS_CODE: 0\n'
              'INSTRUMENTATION_CODE: -1\n',
              200);
        }
      }
    }
    if (includePassedJob && url.startsWith(_providerJobUrl)) {
      return http.Response(jsonEncode(url.contains('/sessions?') ? _passedNativeSessions() : _passedJob()), 200);
    }
    final response = router(url);
    if (includePassedJob && !_nativeVerdictFixtureAndroid && response.body == '{}') {
      return _iosMobileFixture(url) ?? response;
    }
    return response;
  });
}

void _stubLtPatch(http.Response Function(String url, Map<String, dynamic> body) responder) {
  when(
    () => getDep<LtHttp>().patchJson(
      any(),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    ),
  ).thenAnswer((invocation) async => responder(
        invocation.positionalArguments.single as String,
        invocation.namedArguments[#body] as Map<String, dynamic>,
      ));
}

void _stubJobResult(int exitCode, String stdout, {bool includeJobLink = true}) {
  when(
    () => getDep<MplatrolShell>().runArgs(
      any(),
      any(),
      workingDirectory: any(named: 'workingDirectory'),
      throwOnError: any(named: 'throwOnError'),
      cancelOn: any(named: 'cancelOn'),
    ),
  ).thenAnswer((invocation) async {
    _captureNativeVerdictFixturePlatform(invocation);
    await _requestIosFixtureAssignments();
    return ProcessResultX.from(ProcessResult(0, exitCode, '$stdout${includeJobLink ? '\n$_jobLink' : ''}', ''));
  });
}

const _iosEnv = {
  'LT_USERNAME': 'user',
  'LT_ACCESS_KEY': 'key',
  'LT_BIN': '/Users/test/Downloads/LT',
};

const _currentJobId = '022fb1ed-8ddd-41e7-96ce-762dc738bc00';
const _otherJobId = 'cb4e4649-e6df-48d8-86b3-a8a1fa70019f';
const _providerJobUrl = 'https://api.hyperexecute.cloud/v2.0/job/$_currentJobId';
const _jobLink = 'Build Link: https://appautomation.lambdatest.com/build?jobid=$_currentJobId';

Map<String, dynamic> _passedJob() => {
      'status': 'success',
      'data': {
        'id': _currentJobId,
        'status': 'passed',
        'totalTests': 2,
        'taskCount': {'total': 1, 'passed': 1, 'completed': 0, 'failed': 0, 'stopped': 0},
        'tasks': [
          {'id': 'task-current', 'status': 'passed'}
        ],
      },
    };

Map<String, dynamic> _passedNativeSessions() => {
      'status': 'success',
      'data': [
        for (final (index, name) in _nativeVerdictFixtureNames().indexed)
          {'sessionID': 'native-$index', 'taskID': 'task-current', 'scenario_name': name, 'status': 'passed'},
      ],
      'metadata': {'total': _nativeVerdictFixtureNames().length, 'hasmore': false},
    };

String? _nativeVerdictFixtureRepo;
bool _nativeVerdictFixtureAndroid = false;
String? _iosCoordinatorFixtureUrl;
List<String> _iosCoordinatorFixtureSelected = [];
List<String> _iosCoordinatorFixtureDescriptions = [];
String _iosFixtureBuildName = 'ios-verdict';
List<String> _iosCoordinatorFixtureAssigned = [];
int? _iosCoordinatorFixtureRequestCount;
bool _iosCoordinatorFixtureRepeatSession = false;
String _iosCoordinatorFixtureSessionPrefix = 'fixture';

void _captureIosCoordinatorFixture(Invocation invocation) {
  _iosCoordinatorFixtureUrl = invocation.namedArguments[#selectionCoordinatorUrl] as String?;
  final shards = invocation.namedArguments[#shards] as List;
  _iosCoordinatorFixtureSelected = shards.map((dynamic shard) => shard.method as String).toList();
  _iosCoordinatorFixtureDescriptions = shards.map((dynamic shard) => shard.description as String).toList();
  final env = invocation.namedArguments[#env] as Map<String, String>;
  _iosFixtureBuildName = env['LT_BUILD_NAME'] ?? _iosFixtureBuildName;
}

IosHyperexecuteArtifacts _iosCoordinatorFixtureArtifacts() => IosHyperexecuteArtifacts(
      appPath: '/tmp/Runner.ipa',
      testSuitePath: '/tmp/RunnerUITests-Runner.ipa',
      appId: 'lt://APPIOS',
      testSuiteAppId: 'lt://TESTIOS',
      productsDir: '/tmp',
    );

Future<void> _requestIosFixtureAssignments() async {
  if (_nativeVerdictFixtureAndroid || _iosCoordinatorFixtureUrl == null) {
    return;
  }
  final uri = Uri.parse(_iosCoordinatorFixtureUrl!);
  if (uri.host != 'localhost.lambdatest.com') {
    return;
  }
  final count = _iosCoordinatorFixtureRequestCount ?? _iosCoordinatorFixtureSelected.length;
  final client = HttpClient();
  try {
    for (var index = 0; index < count; index++) {
      final key = _iosCoordinatorFixtureRepeatSession ? 0 : index;
      final request = await client.getUrl(Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: uri.port,
          path: '/assign',
          queryParameters: {'xctestSession': '$_iosCoordinatorFixtureSessionPrefix-$key'}));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      _iosCoordinatorFixtureAssigned.add(body['method'] as String);
    }
  } finally {
    client.close();
  }
}

void _captureNativeVerdictFixturePlatform(Invocation invocation) {
  final args = invocation.positionalArguments[1] as List<String>;
  _nativeVerdictFixtureAndroid = args.any((arg) => arg.endsWith('hyperexecute-lt-android.yaml'));
  if (!_nativeVerdictFixtureAndroid) {
    final config = args[args.indexOf('--config') + 1];
    _iosFixtureBuildName = RegExp('buildName: "([^"]+)"').firstMatch(File(config).readAsStringSync())![1]!;
  }
}

List<String> _nativeVerdictFixtureNames() {
  if (!_nativeVerdictFixtureAndroid) {
    final count = _iosCoordinatorFixtureSelected.isEmpty ? 2 : _iosCoordinatorFixtureSelected.length;
    return List.generate(count, (index) => iosCoordinatorShardOnlyTesting(index, count));
  }
  final root = Directory(p.join(_nativeVerdictFixtureRepo!, 'android/app/src/androidTest/java/mplatrol/e2e'));
  final names = <String>[];
  for (final file in root.listSync().whereType<File>()) {
    final className = p.basenameWithoutExtension(file.path);
    for (final method in RegExp(r'public void ([A-Za-z0-9_]+)\(').allMatches(file.readAsStringSync())) {
      names.add('mplatrol.e2e.$className/${method.group(1)}');
    }
  }
  return names;
}

Future<int> _runIosVerdictFixture({
  required Map<String, dynamic> job,
  Map<String, dynamic>? sessions,
  String output = _jobLink,
  int httpStatus = 200,
  String? rawBody,
  Map<String, dynamic> Function(String url)? sessionPage,
  int? shardCount,
  int? assignmentRequests,
  String Function(int index)? iosLog,
  int iosLogStatus = 200,
  List<Map<String, Object?>>? mobileSessions,
  Object buildId = 28216933,
  bool throwIosLog = false,
  int mobileStatus = 200,
  int? mobileSessionStatus,
  Map<String, Object?>? mobileMetadata,
  String? targetRegex,
}) async {
  final repo = _createRepoWithTests();
  addTearDown(() => repo.deleteSync(recursive: true));
  if (shardCount != null) {
    File(p.join(repo.path, 'patrol_test/login_faults_test.dart')).deleteSync();
    File(p.join(repo.path, 'patrol_test/patrol_login_test.dart')).writeAsStringSync(
        List.generate(shardCount, (index) => "patrolTest('case $index', (\$) async {});").join('\n'));
  }
  _stubRepo(repo);
  _iosCoordinatorFixtureRequestCount = assignmentRequests;
  _stubJobResult(0, output, includeJobLink: false);
  _stubLtGet((url) {
    if (url.startsWith(_providerJobUrl)) {
      return http.Response(
          rawBody ??
              jsonEncode(
                  url.contains('/sessions?') ? sessionPage?.call(url) ?? sessions ?? _passedNativeSessions() : job),
          httpStatus);
    }
    if (url.contains('/log/instrumentation')) {
      if (throwIosLog) {
        throw const SocketException('SECRET https://private.invalid/?token=HIDDEN');
      }
      final index = int.parse(RegExp(r'/native-(\d+)/').firstMatch(url)![1]!);
      return http.Response(iosLog?.call(index) ?? _iosInstrumentationFixture(index), iosLogStatus);
    }
    final mobile = _iosMobileFixture(url, sessions: mobileSessions, buildId: buildId, metadata: mobileMetadata);
    final sessionsUrl = url.contains('/sessions?build_id=');
    return mobile == null
        ? http.Response('{}', 200)
        : http.Response(mobile.body, sessionsUrl ? mobileSessionStatus ?? mobileStatus : mobileStatus);
  }, includePassedJob: false);
  final result = await LtHyperexecuteRunner(
    pollDelay: Duration.zero,
  ).runIos(
      target: null,
      targetRegex: targetRegex,
      devices: const ['iPhone 17 Pro-26'],
      idleTimeoutSeconds: 240,
      env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-verdict'});
  verify(() => getDep<MplatrolShell>().runArgs(any(), any(),
      workingDirectory: repo.path, throwOnError: false, cancelOn: any(named: 'cancelOn'))).called(1);
  return result;
}

/// Runs a provider-green iOS job over the already stubbed [repo].
Future<int> _runIosVerdictFixtureOnRepo(Directory repo) {
  _iosCoordinatorFixtureRequestCount = null;
  _stubJobResult(0, _jobLink, includeJobLink: false);
  _stubLtGet((url) => http.Response('{}', 200));
  return LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
      target: null,
      devices: const ['iPhone 17 Pro-26'],
      idleTimeoutSeconds: 240,
      env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-verdict'});
}

http.Response? _iosMobileFixture(String url,
    {List<Map<String, Object?>>? sessions, Object buildId = 28216933, Map<String, Object?>? metadata}) {
  if (url.contains('/builds?')) {
    return http.Response(
        jsonEncode({
          'data': [
            {'name': _iosFixtureBuildName, 'build_id': buildId}
          ]
        }),
        200);
  }
  if (url.contains('/sessions?build_id=')) {
    return http.Response(
        jsonEncode({
          'data': sessions ??
              [
                for (var i = 0; i < _iosCoordinatorFixtureSelected.length; i++)
                  {'session_id': 'native-$i', 'status_ind': 'passed', 'build_id': buildId}
              ],
          'metadata': metadata ?? {'hasmore': false, 'total': sessions?.length ?? _iosCoordinatorFixtureSelected.length}
        }),
        200);
  }
  return null;
}

String _iosFixtureDartName(String description) {
  final files = discoverPatrolTestFiles(_nativeVerdictFixtureRepo!);
  final file = files.singleWhere((file) => file.tests.any((test) => test.description == description));
  return '${file.basename} $description';
}

String _iosInstrumentationFixture(int index) =>
    _iosInstrumentationFixtureNamed(index, _iosFixtureDartName(_iosCoordinatorFixtureDescriptions[index]));

String _iosInstrumentationFixtureNamed(int index, String dartName) {
  final method = iosCoordinatorShardMethod(index, _iosCoordinatorFixtureSelected.length);
  final assigned = _iosCoordinatorFixtureSelected[index];
  return "XCTestOutputBarrierTest Suite 'LoginE2ETests' started at 2026-09-30 13:17:38.\n"
      "XCTestOutputBarrierTest Case '-[RunnerUITests.LoginE2ETests $method]' started.\n"
      '2026-09-30 Runner[1:2] PATROL_SELECTION_SOURCE source=coordinator '
      'method=$assigned attempt=1\n'
      '2026-09-30 Runner[1:2] PATROL_RESULT name=$dartName '
      'attempt=1 passed=true details=\n'
      "Test Case '-[RunnerUITests.LoginE2ETests $method]' passed (62.769 seconds).\n"
      "XCTestOutputBarrierTest Suite 'LoginE2ETests' passed at 2026-09-30 13:18:41.\n"
      '\t Executed 1 test, with 0 failures (0 unexpected) in 62.769 (62.771) seconds\n';
}

/// [log] as the JSON-lines instrumentation LambdaTest publishes for some iOS
/// devices (seen on iOS 16): one `outputReceived` record per output line.
String _iosJsonLinesLog(String log) => [
      for (final line in const LineSplitter().convert(log))
        jsonEncode({
          'fields.msg': '$line\n',
          'fields.time': 715441326840,
          'level': 'info',
          'msg': 'outputReceived:fromProcess:atTime:',
          'pid': 9645,
          'time': '2026-10-02T15:32:28Z',
        }),
    ].join('\n');

void _registerIosInstrumentationTests() {
  // Native verdicts prove selected execution, not SDK vendor identity. A real
  // journey must use its source-backed entry and feature-specific vendor UI;
  // background controllers or global SDK keys cannot establish that route.
  _registerIosBuildEvidenceTests();
  group('HE iOS active native instrumentation', () {
    test('actual coordinator barrier ANSI CRLF contract passes all selected Dart tests', () async {
      expect(
          await _runIosVerdictFixture(
              job: _passedJob(),
              iosLog: (index) =>
                  _iosInstrumentationFixture(index).split('\n').map((line) => '\x1B[32m$line\x1B[0m').join('\r\n')),
          0);
    });
    test('accepts a Dart result name carrying enclosing group segments', () async {
      expect(
          await _runIosVerdictFixture(
              job: _passedJob(),
              iosLog: (index) => _iosInstrumentationFixture(index)
                  .replaceFirst('name=patrol_login_test first test', 'name=patrol_login_test Login E2E first test')),
          0);
    });
    // Regression: filtered (targetRegex/sdk) runs expected the
    // "mplatrol_filtered_test " prefix of a wrapper iOS no longer compiles.
    test('filtered run expects the file-basename Dart names the iOS bundle reports', () async {
      expect(await _runIosVerdictFixture(job: _passedJob(), targetRegex: 'patrol_test'), 0);
    });
    test('filtered run still rejects a failed Dart result', () async {
      expect(
          await _runIosVerdictFixture(
              job: _passedJob(),
              targetRegex: 'patrol_test',
              iosLog: (index) => _iosInstrumentationFixture(index).replaceFirst('passed=true', 'passed=false')),
          ExitCode.unavailable.code);
    });
    final mutations = <String, String Function(String)>{
      'missing': (_) => '',
      'truncated': (log) => log.split("XCTestOutputBarrierTest Suite 'LoginE2ETests' passed").first,
      'foreign class': (log) => log.replaceAll('LoginE2ETests', 'OtherTests'),
      'direct alias': (log) => log.replaceAll('testShard01', 'testAFirstTest'),
      'failed case': (log) => log.replaceFirst('passed (62.769', 'failed (62.769'),
      'skipped case': (log) => log.replaceFirst('passed (62.769', 'skipped (62.769'),
      'expected failure': (log) => log.replaceFirst('passed (62.769', 'expected failure (62.769'),
      'zero counts': (log) => log.replaceFirst('Executed 1 test', 'Executed 0 tests'),
      'failure counts': (log) => log.replaceFirst('0 failures', '1 failure'),
      'outer suite failure': (log) => '$log'
          "Test Suite 'Selected tests' failed at 2026-09-30 13:18:42.\n",
      'outer expected failures': (log) => '$log'
          'Executed 1 test, with 1 expected failure (0 unexpected) in 1 seconds\n',
      'contradictory suite': (log) => '$log'
          "Test Suite 'LoginE2ETests' failed at 2026-09-30 13:18:42.\n",
      'trailing case': (log) => '$log'
          "Test Case '-[RunnerUITests.LoginE2ETests testShard01]' started.\n",
      'duplicate case': (log) => log.replaceFirst('passed (62.769 seconds).',
          "passed (62.769 seconds).\nTest Case '-[LoginE2ETests testShard01]' passed (1 seconds)."),
      'missing Dart completion': (log) => log.split('\n').where((line) => !line.contains('PATROL_RESULT ')).join('\n'),
      'foreign prefix same suffix': (log) =>
          log.replaceFirst('name=patrol_login_test first test', 'name=foreign patrol_login_test first test'),
      'wrong source group same description': (log) =>
          log.replaceFirst('name=patrol_login_test first test', 'name=login_faults_test first test'),
      'zero result attempt': (log) => log.replaceFirst('attempt=1 passed=true', 'attempt=0 passed=true'),
      'failed retry before positive completion': (log) => log.replaceFirst(
          'PATROL_RESULT ',
          'PATROL_RESULT name=patrol_login_test first test '
              'attempt=1 passed=false details=failed\nPATROL_RESULT '),
      'Dart failure': (log) => log.replaceFirst('passed=true', 'passed=false'),
      'filtered-wrapper Dart name': (log) => log.replaceFirst(
          'name=patrol_login_test first test', 'name=mplatrol_filtered_test patrol_login_test first test'),
      'wrong Dart result': (log) => log.replaceFirst('name=patrol_login_test first test', 'name=foreign journey'),
      'foreign assignment': (log) => log.replaceFirst('method=testAFirstTest', 'method=testOther'),
      'missing assignment': (log) => log.replaceFirst('PATROL_SELECTION_SOURCE', 'OTHER_SOURCE'),
      'runtime skip': (log) => '$log\nMPLATROL_TEST_SKIPPED reason=unsupported\n',
      'empty NoShard': (log) => '$log\nPATROL_SELECTION_NO_SHARD extra session\n',
    };
    for (final mutation in mutations.entries) {
      test('rejects ${mutation.key} despite provider green', () async {
        expect(
            await _runIosVerdictFixture(
                job: _passedJob(),
                iosLog: (index) =>
                    index == 0 ? mutation.value(_iosInstrumentationFixture(index)) : _iosInstrumentationFixture(index)),
            ExitCode.unavailable.code);
        verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.'));
      });
    }
    for (final status in [401, 403, 404, 599]) {
      test('missing native HTTP $status is nonpass without job retry', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), iosLogStatus: status), ExitCode.unavailable.code);
      });
    }
    for (final build in ['28216933', '028216933', 28216933, 'build-uuid', 0]) {
      test('uses actual numeric build identity $build', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), buildId: build),
            build == 'build-uuid' || build == 0 ? ExitCode.unavailable.code : 0);
      });
    }
    test('native transport exception is sanitized and nonpass', () async {
      expect(await _runIosVerdictFixture(job: _passedJob(), throwIosLog: true), ExitCode.unavailable.code);
      verifyNever(() => getDep<MplatrolLogger>().err(any(that: contains('HIDDEN'))));
    });
    test('another build session cannot certify current HE job', () async {
      expect(
          await _runIosVerdictFixture(job: _passedJob(), mobileSessions: [
            {'session_id': 'foreign', 'status_ind': 'passed', 'build_id': 28216933},
            {'session_id': 'native-1', 'status_ind': 'passed', 'build_id': 28216933},
          ]),
          ExitCode.unavailable.code);
    });
    test('two native shard passes cannot duplicate one selected Dart result', () async {
      expect(
          await _runIosVerdictFixture(
              job: _passedJob(),
              iosLog: (index) => _iosInstrumentationFixture(index).replaceAll('testBSecondTest', 'testAFirstTest')),
          ExitCode.unavailable.code);
    });
  });
}

void _registerIosBuildEvidenceTests() {
  group('HE iOS current native build binding', () {
    for (final status in [401, 403, 404, 599]) {
      test('build metadata HTTP $status cannot pass even with positive body', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), mobileStatus: status), ExitCode.unavailable.code);
      });
    }
    for (final status in [404, 503]) {
      test('current build session evidence HTTP $status cannot pass', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), mobileSessionStatus: status), ExitCode.unavailable.code);
        final messages = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>().join('\n');
        expect(messages, contains('iOS build session evidence GET returned HTTP $status'));
      });
    }
    for (final metadata in [
      {'hasmore': true, 'total': 2},
      {'hasmore': 'false', 'total': 2},
      {'hasmore': false, 'total': 3},
    ]) {
      test('incomplete or malformed native build pagination $metadata is nonpass', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), mobileMetadata: metadata), ExitCode.unavailable.code);
      });
    }
    for (final mismatch in ['foreign build', 'duplicate session', 'unpassed session']) {
      test('rejects $mismatch in current build inventory', () async {
        expect(
            await _runIosVerdictFixture(job: _passedJob(), mobileSessions: [
              {'session_id': 'native-0', 'status_ind': 'passed', 'build_id': 28216933},
              {
                'session_id': mismatch == 'duplicate session' ? 'native-0' : 'native-1',
                'status_ind': mismatch == 'unpassed session' ? 'failed' : 'passed',
                'build_id': mismatch == 'foreign build' ? 28216934 : 28216933
              },
            ]),
            ExitCode.unavailable.code);
      });
    }
    test('incidental NoShard prose is not a runtime skip', () async {
      expect(
          await _runIosVerdictFixture(
              job: _passedJob(),
              iosLog: (index) => '${_iosInstrumentationFixture(index)}guide says PATROL_SELECTION_NO_SHARD\n'),
          0);
    });
    test('malformed Dart result cannot be ignored as absent', () async {
      expect(
          await _runIosVerdictFixture(
              job: _passedJob(),
              iosLog: (index) => _iosInstrumentationFixture(index).replaceFirst('passed=true', 'passed=unknown')),
          ExitCode.unavailable.code);
    });
  });
}

void _registerHyperexecuteVerdictTests() {
  group('HyperExecute current-job native verdict', () {
    for (final status in ['stopped', 'cancelled', 'aborted', 'running', 'failed']) {
      test('CLI zero cannot pass provider job $status', () async {
        final job = _passedJob();
        job['data']['status'] = status;
        expect(await _runIosVerdictFixture(job: job), ExitCode.unavailable.code);
        verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.'));
      });
    }
    test('exact stopped iOS zero-execution tunnel-killed output is non-pass', () async {
      final job = _passedJob();
      job['data']['status'] = 'stopped';
      job['data']['taskCount'] = {'total': 1, 'completed': 0, 'stopped': 1, 'failed': 0};
      final result = await _runIosVerdictFixture(job: job, output: '''
$_jobLink
ERR::TUN::INT Tunnel errored: signal: killed
Test Execution Time: 0s
Pass test stage percentage: 0.00%
Failed Tasks: 0
''');
      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('status is stopped')))).called(1);
      verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.'));
    });
    for (final summary in ['Test Execution Time: 0s', 'Pass test stage percentage: 0.00%', 'Failed Tasks: 1']) {
      test('contradictory CLI summary is non-pass: $summary', () async {
        expect(
            await _runIosVerdictFixture(job: _passedJob(), output: '$_jobLink\n$summary'), ExitCode.unavailable.code);
      });
    }
    for (final status in ['running', 'stopped', 'skipped', 'failed', 'unknown']) {
      test('passed job cannot pass unpassed native test $status', () async {
        final sessions = _passedNativeSessions();
        sessions['data'][1]['status'] = status;
        expect(await _runIosVerdictFixture(job: _passedJob(), sessions: sessions), ExitCode.unavailable.code);
      });
    }
    test('passed exact job with two positive named native passes succeeds', () async {
      expect(await _runIosVerdictFixture(job: _passedJob()), ExitCode.success.code);
      verify(() =>
              getDep<LtHttp>().get(_providerJobUrl, headers: any(named: 'headers'), timeout: any(named: 'timeout')))
          .called(1);
      verify(() => getDep<LtHttp>().get('$_providerJobUrl/sessions?limit=20',
          headers: any(named: 'headers'), timeout: any(named: 'timeout'))).called(1);
      verify(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.')).called(1);
    });
    test('iOS failed session cannot be certified by a later provider pass', () async {
      final sessions = _passedNativeSessions();
      sessions['data']
          .add({...sessions['data'][0] as Map<String, String>, 'sessionID': 'failed-before-retry', 'status': 'failed'});
      sessions['metadata']['total'] = 3;
      expect(await _runIosVerdictFixture(job: _passedJob(), sessions: sessions), ExitCode.unavailable.code);
    });
  });
}

void _registerHyperexecuteEvidenceTests() {
  group('HyperExecute missing or mismatched evidence', () {
    for (final status in [401, 503, 599]) {
      test('provider HTTP $status is non-pass', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), httpStatus: status), ExitCode.unavailable.code);
      });
    }
    for (final body in ['not json', '{}', '{"data":[]}']) {
      test('malformed or missing job evidence is non-pass: $body', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), rawBody: body), ExitCode.unavailable.code);
      });
    }
    for (final kind in ['wrong job', 'no counts', 'zero tasks', 'incomplete tasks', 'zero tests', 'missing task IDs']) {
      test('rejects $kind', () async {
        final job = _passedJob();
        switch (kind) {
          case 'wrong job':
            job['data']['id'] = 'old-job';
          case 'no counts':
            job['data'].remove('taskCount');
          case 'zero tasks':
            job['data']['taskCount'] = {'total': 0, 'completed': 0};
          case 'incomplete tasks':
            job['data']['taskCount']['passed'] = 0;
          case 'zero tests':
            job['data']['totalTests'] = 0;
          case 'missing task IDs':
            job['data']['tasks'] = [];
        }
        expect(await _runIosVerdictFixture(job: job), ExitCode.unavailable.code);
      });
    }
    const otherJobId = '11111111-1111-1111-1111-111111111111';
    const ambiguousLink = 'Build Link: https://appautomation.lambdatest.com/build?jobid=$otherJobId';
    for (final output in ['completed successfully', '$_jobLink\n$ambiguousLink']) {
      test('missing or ambiguous CLI job ID is non-pass', () async {
        expect(await _runIosVerdictFixture(job: _passedJob(), output: output), ExitCode.unavailable.code);
      });
    }
  });
}

void _registerHyperexecuteNativeEvidenceTests() {
  group('HyperExecute exact native evidence', () {
    final nativeMutations = <String, void Function(Map<String, dynamic>)>{
      'zero sessions': (value) {
        value['data'] = [];
        value['metadata']['total'] = 0;
      },
      'missing test': (value) {
        value['data'].removeLast();
        value['metadata']['total'] = 1;
      },
      'foreign task': (value) {
        value['data'][1]['taskID'] = 'stale-job-task';
      },
      'blank test': (value) {
        value['data'][1]['scenario_name'] = '';
      },
      'missing session ID': (value) {
        value['data'][1].remove('sessionID');
      },
      'pagination': (value) {
        value['metadata']['hasmore'] = true;
      },
      'missing metadata': (value) {
        value.remove('metadata');
      },
      'count mismatch': (value) {
        value['metadata']['total'] = 3;
      },
      'duplicate test instead of missing test': (value) {
        value['data'][1]['scenario_name'] = value['data'][0]['scenario_name'];
      },
      'fuzzy test suffix is not the selected test': (value) {
        value['data'][1]['scenario_name'] = 'LoginE2ETests/testShard02Other';
      },
      'foreign selected test': (value) {
        value['data'][1]['scenario_name'] = 'UnrelatedTests/testPassed';
      },
    };
    for (final mutation in nativeMutations.entries) {
      test('rejects native evidence: ${mutation.key}', () async {
        final sessions = _passedNativeSessions();
        mutation.value(sessions);
        expect(await _runIosVerdictFixture(job: _passedJob(), sessions: sessions), ExitCode.unavailable.code);
      });
    }
  });
}

const _observedAndroidJobId = '4c2d9494-a6ea-4a94-a519-def2ad7f74b5';
const _observedAndroidTaskId = 'HYPL-1913856-1790740960014724780XRQ';
const _observedAndroidNativeName = 'mplatrol.e2e.PatrolLoginTest/reaches_accounts_after_credentials_MFA';

Map<String, dynamic> _observedPassedAndroidJob() => {
      'status': 'success',
      'data': {
        'id': _observedAndroidJobId,
        'status': 'passed',
        'totalTests': 1,
        'taskCount': {
          'aborted': 0,
          'cancelled': 0,
          'completed': 0,
          'failed': 0,
          'initiated': 0,
          'lambdaError': 0,
          'passed': 1,
          'queued': 0,
          'running': 0,
          'skipped': 0,
          'timeout': 0,
          'total': 1
        },
        'tasks': [
          {'id': _observedAndroidTaskId, 'status': 'passed'}
        ],
        'jobSummary': {'testStatusCount': null},
      },
    };

Future<int> _runObservedAndroidFixture(String name) async {
  final repo = Directory.systemTemp.createTempSync('observed_native_verdict');
  addTearDown(() => repo.deleteSync(recursive: true));
  File(p.join(repo.path, 'patrol_test/patrol_login_test.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync("patrolTest('reaches accounts after credentials + MFA', (\$) async {});");
  _stubRepo(repo);
  _stubJobResult(0, 'Build Link: https://appautomation.lambdatest.com/build?jobid=$_observedAndroidJobId',
      includeJobLink: false);
  _stubLtGet((url) {
    if (url.contains('/job/$_observedAndroidJobId/sessions?')) {
      return http.Response(
          jsonEncode({
            'status': 'success',
            'data': [
              {
                'sessionID': 'RMAA-AND-1913856-1790740985975461737PNO',
                'testID': 'RMAA-AND-1913856-1790740985975461737PNO',
                'taskID': _observedAndroidTaskId,
                'name': '',
                'scenario_name': name,
                'status': 'passed',
                'group_number': 1,
                'duration': '00:00:56'
              }
            ],
            'metadata': {'total': 1, 'cursor': '', 'hasmore': false}
          }),
          200);
    }
    if (url.endsWith('/job/$_observedAndroidJobId')) {
      return http.Response(jsonEncode(_observedPassedAndroidJob()), 200);
    }
    if (url.contains('/sessions/RMAA-AND-1913856-1790740985975461737PNO/'
        'log/instrumentation')) {
      final identity = _observedAndroidNativeName.split('/');
      return http.Response(
          'INSTRUMENTATION_STATUS: class=${identity[0]}\n'
          'INSTRUMENTATION_STATUS: test=${identity[1]}\n'
          'INSTRUMENTATION_STATUS_CODE: 0\nINSTRUMENTATION_CODE: -1\n',
          200);
    }
    return http.Response('{}', 200);
  }, includePassedJob: false);
  return LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
      target: 'patrol_test/patrol_login_test.dart',
      devices: const ['Pixel 8-14'],
      idleTimeoutSeconds: 123,
      env: _androidEnv);
}

void _registerObservedProviderTests() {
  test('actual redacted 4c2d passed native schema and generated Android identity passes', () async {
    expect(await _runObservedAndroidFixture(_observedAndroidNativeName), ExitCode.success.code);
  });
  test('actual passed job cannot substitute a foreign Android native identity', () async {
    expect(await _runObservedAndroidFixture('OtherTests/reaches_accounts_after_credentials_MFA'),
        ExitCode.unavailable.code);
  });
  test('native completed without observed passed schema is not accepted', () async {
    final job = _passedJob();
    job['data']['status'] = 'completed';
    expect(await _runIosVerdictFixture(job: job), ExitCode.unavailable.code);
  });
  test('iOS concrete method plus synthetic shard discovery is not executed-test count', () async {
    final job = _passedJob();
    job['data']['totalTests'] = 2;
    final sessions = _passedNativeSessions();
    sessions['data'].removeLast();
    sessions['metadata']['total'] = 1;
    expect(await _runIosVerdictFixture(job: job, sessions: sessions, shardCount: 1), ExitCode.success.code);
  });
}

void _registerProviderPaginationTests() {
  test('25 selected native tests use provider cursor, not invented offsets', () async {
    final job = _passedJob();
    job['data']['totalTests'] = 25;
    final all = [
      for (var index = 1; index <= 25; index++)
        {
          'sessionID': 'native-${index - 1}',
          'taskID': 'task-current',
          'status': 'passed',
          'scenario_name': 'LoginE2ETests/testShard${index.toString().padLeft(2, '0')}'
        }
    ];
    final urls = <String>[];
    // One job of 25 sessions, so its session list spans two provider pages; each
    // page's total counts that page.
    _stubConfiguredIosMaxParallel(25);
    final result = await _runIosVerdictFixture(
        job: job,
        shardCount: 25,
        sessionPage: (url) {
          urls.add(url);
          final second = url.contains('&cursor=');
          return {
            'data': second ? all.sublist(20) : all.sublist(0, 20),
            'metadata': {'total': second ? 5 : 20, 'hasmore': !second, 'cursor': second ? '' : 'native/20 +?'}
          };
        });
    expect(result, ExitCode.success.code);
    expect(
        urls, ['$_providerJobUrl/sessions?limit=20', '$_providerJobUrl/sessions?limit=20&cursor=native%2F20+%2B%3F']);
  });
  for (final mode in ['repeated cursor', 'missing cursor', 'repeated session', 'miscounted page', 'page limit']) {
    test('pagination fails closed: $mode', () async {
      var calls = 0;
      final result = await _runIosVerdictFixture(
          job: _passedJob(),
          sessionPage: (_) {
            calls++;
            final page = _passedNativeSessions();
            final session = Map<String, dynamic>.of(page['data'][calls == 1 || mode == 'repeated session' ? 0 : 1]);
            if (mode == 'page limit') {
              session['sessionID'] = 'native-page-$calls';
            }
            page['data'] = [session];
            page['metadata'] = {
              'total': mode == 'miscounted page' ? 2 : 1,
              'hasmore': true,
              'cursor': switch (mode) {
                'missing cursor' => '',
                'page limit' => 'cursor-$calls',
                _ => 'same-cursor-${calls == 1 || mode == 'repeated cursor' ? 1 : calls}',
              }
            };
            return page;
          });
      expect(result, ExitCode.unavailable.code);
      expect(calls, lessThanOrEqualTo(mode == 'page limit' ? 50 : 2));
    });
  }
}

void _stubConfiguredIosMaxParallel(int value) {
  final options = getDep<MplatrolConfig>().it;
  when(() => options.ltIosMaxParallel).thenReturn(value);
}

/// Shard indices (0-based) an iOS HyperExecute YAML maps.
List<int> _iosYamlWave(String yaml) => [
      for (final match in RegExp(r'"LoginE2ETests/testShard(\d+)"').allMatches(yaml)) int.parse(match[1]!) - 1,
    ];

class _StallFirstWatchdog extends Fake implements HyperexecuteStallWatchdog {
  var _calls = 0;

  @override
  Future<String?> watch({
    required String cliLogPath,
    required int cliLogOffset,
    required Map<String, String> headers,
    required Future<void> done,
  }) async {
    if (++_calls == 1) {
      return 'first wave stalled';
    }
    await done;
    return null;
  }
}

typedef _IosWaveRun = ({
  int result,
  List<String> yamls,
  List<List<String>> assigned,
  List<int> extraStatuses,
});

/// Runs one iOS device job over [files] (basename -> test descriptions,
/// default [shardCount] tests in one file) with [env] as the process
/// environment. Each HyperExecute job reads its YAML, lets that wave's
/// sessions ask the coordinator for a shard, and reports provider-green
/// evidence for exactly those sessions. A wave whose [waveExit] (1-based) is
/// non-zero, or the [stallWave], gets no assignment at all. With
/// [extraSession], one more session per wave asks for a shard after the wave's
/// own sessions; its HTTP statuses are returned. A session of [failedShards]
/// runs and fails, failing its wave's job, whose provider job API then answers
/// [failedJobProviderStatus]. Each HyperExecute call of [tunnelFailCalls]
/// (1-based) fails to start its tunnel before any session runs. A session of
/// [unreachableShards] (trailing shards of their wave) never reaches the
/// coordinator, the first time only unless [unreachableOnRetry].
Future<_IosWaveRun> _runIosWaveFixture({
  int shardCount = 12,
  Map<String, List<String>>? files,
  Map<String, String> env = const {ltIosMaxParallelEnv: '5'},
  int Function(int wave)? waveExit,
  int? stallWave,
  String Function(int index)? iosLog,
  bool extraSession = false,
  Set<int> failedShards = const {},
  int failedJobProviderStatus = 200,
  Set<int> tunnelFailCalls = const {},
  bool tunnelPortInUse = false,
  Set<int> unreachableShards = const {},
  bool unreachableOnRetry = false,
  LtSlotBudget? slotBudget,
  Map<String, String> runEnv = const {},
  int? stopWave,
  void Function()? stop,
}) async {
  final unreachableLeft = {...unreachableShards};
  var unreachable = <int>{};
  final repo = Directory.systemTemp.createTempSync();
  addTearDown(() => repo.deleteSync(recursive: true));
  final tests = files ??
      {
        'patrol_login_test': [for (var i = 0; i < shardCount; i++) 'case $i']
      };
  for (final MapEntry(key: name, value: descriptions) in tests.entries) {
    File(p.join(repo.path, 'patrol_test', '$name.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(descriptions.map((d) => "patrolTest('$d', (\$) async {});").join('\n'));
  }
  _stubRepo(repo);
  when(() => getDep<PlatformWrapper>().environment).thenReturn(env);
  final yamls = <String>[];
  final assigned = <List<String>>[];
  final extraStatuses = <int>[];
  var wave = <int>[];
  when(() => getDep<MplatrolShell>().runArgs(any(), any(),
      workingDirectory: any(named: 'workingDirectory'),
      throwOnError: any(named: 'throwOnError'),
      cancelOn: any(named: 'cancelOn'))).thenAnswer((invocation) async {
    _captureNativeVerdictFixturePlatform(invocation);
    final args = invocation.positionalArguments[1] as List<String>;
    yamls.add(File(args[args.indexOf('--config') + 1]).readAsStringSync());
    wave = _iosYamlWave(yamls.last);
    unreachable = wave.where(unreachableLeft.contains).toSet();
    if (!unreachableOnRetry) {
      unreachableLeft.removeAll(unreachable);
    }
    final tunnelFailed = tunnelFailCalls.contains(yamls.length);
    final exit = waveExit?.call(yamls.length) ?? (tunnelFailed ? 1 : 0);
    final stalled = yamls.length == stallWave || yamls.length == stopWave;
    if (yamls.length == stopWave) {
      stop!();
    }
    _iosCoordinatorFixtureAssigned = [];
    _iosCoordinatorFixtureRequestCount = exit == 0 && !stalled ? wave.length - unreachable.length : 0;
    _iosCoordinatorFixtureSessionPrefix = 'wave${yamls.length}';
    await _requestIosFixtureAssignments();
    assigned.add(List.of(_iosCoordinatorFixtureAssigned));
    if (extraSession) {
      extraStatuses.add(await _requestIosExtraAssignment('extra-wave${yamls.length}'));
    }
    if (stalled) {
      await (invocation.namedArguments[#cancelOn] as Future<void>);
      return ProcessResultX.from(ProcessResult(0, ExitCode.tempFail.code, '', 'Stopped'));
    }
    if (tunnelFailed) {
      return ProcessResultX.from(ProcessResult(
          0,
          exit,
          tunnelPortInUse
              ? 'ERR::TUN::INT Err occurred: ERR::TUN::STR Unable to start tunnels  listen tcp4 :59363: '
                  'bind: address already in use'
              : 'ERR::TUN::INT Err occurred: Tunnel abc #1 , errored: signal: killed\n'
                  'ERR::TUN::INT Err occurred: failed to start tunnel instances',
          ''));
    }
    final failing = exit != 0 || wave.any(failedShards.contains) || unreachable.isNotEmpty;
    final output = failing ? 'Failed Tasks: 1\n$_jobLink' : _jobLink;
    return ProcessResultX.from(ProcessResult(0, failing ? max(exit, 1) : 0, output, ''));
  });
  _stubLtGet((url) {
    if (url.startsWith(_providerJobUrl)) {
      final failing = wave.any(failedShards.contains) || unreachable.isNotEmpty;
      return http.Response(
          jsonEncode(url.contains('/sessions?')
              ? {
                  'data': [
                    for (final i in wave)
                      {
                        'sessionID': 'native-$i',
                        'taskID': 'task-current',
                        'status': failedShards.contains(i) || unreachable.contains(i) ? 'failed' : 'passed',
                        'scenario_name': iosCoordinatorShardOnlyTesting(i, _iosCoordinatorFixtureSelected.length)
                      },
                  ],
                  'metadata': {'total': wave.length, 'hasmore': false},
                }
              : _passedJob()),
          failing ? failedJobProviderStatus : 200);
    }
    if (url.contains('/log/instrumentation')) {
      final index = int.parse(RegExp(r'/native-(\d+)/').firstMatch(url)![1]!);
      return http.Response(
          unreachable.contains(index) ? _iosUnreachableCoordinatorLog : (iosLog ?? _iosInstrumentationFixture)(index),
          200);
    }
    return _iosMobileFixture(url, sessions: [
          for (final i in wave)
            {
              'session_id': 'native-$i',
              'status_ind': failedShards.contains(i) ? 'failed' : 'passed',
              'build_id': 28216933
            },
        ]) ??
        http.Response('{}', 200);
  }, includePassedJob: false);
  _stubLtPatch((url, body) => http.Response('{}', 200));
  final result = await LtHyperexecuteRunner(
    pollDelay: Duration.zero,
    tunnelRetryDelay: Duration.zero,
    stallWatchdog: stallWave == null ? null : _StallFirstWatchdog(),
    slotBudget: slotBudget,
  ).runIos(
      target: null,
      devices: const ['iPhone 17 Pro-26'],
      idleTimeoutSeconds: 240,
      env: {..._iosEnv, 'LT_BUILD_NAME': 'ios-waves', ...runEnv});
  return (result: result, yamls: yamls, assigned: assigned, extraStatuses: extraStatuses);
}

Future<int> _requestIosExtraAssignment(String session) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: Uri.parse(_iosCoordinatorFixtureUrl!).port,
        path: '/assign',
        queryParameters: {'xctestSession': session}));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

/// The instrumentation of a device session whose coordinator requests were
/// all refused (acme 2026-10-02, session ...492303604GXV).
const _iosUnreachableCoordinatorLog =
    'Runner[1:2] PATROL_SELECTION_COORDINATOR_FAILED attempts=15 elapsed=115s window=120s '
    'HTTP 500: dial tcp 127.0.0.1:50389: connect: connection refused\n'
    'RunnerUITests.swift:1089: error: -[RunnerUITests.LoginE2ETests testShard10] : failed - '
    'PATROL_SHARD_NOT_RUN iOS shard coordinator unreachable after 15 attempt(s) over 115s '
    '(window 120s): HTTP 500: dial tcp 127.0.0.1:50389: connect: connection refused .\n';

/// The HyperExecute CLI output of a job whose app LambdaTest could not patch.
const _frameworkSetupFailureOutput =
    '2026-10-02T14:33:47-04:00    error    app update failed - Error setting up framework.\n'
    'Error: app update failed\n';

List<String> _loggedErrors() => verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>();

void _registerIosWaveTests() {
  group('HE iOS device waves', () {
    test('12 shards with at most 5 devices run as waves of 5, 5 and 2', () async {
      final run = await _runIosWaveFixture();

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1, 2, 3, 4],
        [5, 6, 7, 8, 9],
        [10, 11],
      ]);
      for (final (index, concurrency) in [5, 5, 2].indexed) {
        final yaml = run.yamls[index];
        expect(yaml, contains('concurrency: $concurrency\n'));
        expect(yaml, contains('buildName: "ios-waves_wave${index + 1}"'));
      }
      expect(run.yamls[1], contains('- name: "shard 6"\n'));
      expect(run.yamls[1], contains('values: ["LoginE2ETests/testShard06"]'));
      expect(run.yamls[2], contains('- name: "shard 12"\n'));
      expect(run.yamls[2], isNot(contains('"shard 10"')));
      // Every test is assigned once, each wave only its own consecutive shards.
      final selected = _iosCoordinatorFixtureSelected;
      expect(run.assigned, [selected.sublist(0, 5), selected.sublist(5, 10), selected.sublist(10)]);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] iPhone 17 Pro-26: 12 shards in waves '
          'of at most 5 devices, each as big as the free LambdaTest sessions allow')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2: shards 6, 7, 8, 9, 10 of 12 '
          '(LT build "ios-waves_wave2")')).called(1);
      verify(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.')).called(3);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 12/12 shards '
          'assigned and 12/12 Dart results verified.')).called(1);
    });

    test('a seeded random order shuffles which shards each wave runs and the assignment order', () async {
      const order = TestOrder.random(7);
      getDep<ItTestOrder>().order = order;
      addTearDown(() => getDep<ItTestOrder>().order = const TestOrder.declared(0));
      final shuffled = order.apply([for (var index = 0; index < 12; index++) index]);

      final run = await _runIosWaveFixture();

      expect(run.result, ExitCode.success.code);
      expect(shuffled, isNot([for (var index = 0; index < 12; index++) index]));
      expect(run.yamls.map(_iosYamlWave), [shuffled.sublist(0, 5), shuffled.sublist(5, 10), shuffled.sublist(10)]);
      final selected = [for (final index in shuffled) _iosCoordinatorFixtureSelected[index]];
      expect(run.assigned, [selected.sublist(0, 5), selected.sublist(5, 10), selected.sublist(10)]);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 12/12 shards '
          'assigned and 12/12 Dart results verified.')).called(1);
    });

    // Regression: vandelay 2026-10-02 wave 4/5 passed 100% on LambdaTest but
    // was NOT VERIFIED because its iOS 16 session published JSON-lines
    // instrumentation the native XCTest parser could not read.
    test('passing waves verify when sessions publish JSON-lines instrumentation', () async {
      final run = await _runIosWaveFixture(iosLog: (index) => _iosJsonLinesLog(_iosInstrumentationFixture(index)));

      expect(run.result, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.')).called(3);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 12/12 shards '
          'assigned and 12/12 Dart results verified.')).called(1);
    });

    // Regression: a failed wave's passing sessions were never verified, so
    // vandelay reported "0/25 Dart results verified" after 40%-pass waves.
    test('a failed session fails its wave but its passing neighbours still count', () async {
      final run = await _runIosWaveFixture(
        failedShards: {6},
        iosLog: (index) {
          final log = _iosInstrumentationFixture(index);
          final plain = index == 6 ? log.replaceFirst('passed=true', 'passed=false') : log;
          return index.isOdd ? _iosJsonLinesLog(plain) : plain;
        },
      );

      expect(run.result, ExitCode.software.code);
      final selected = _iosCoordinatorFixtureSelected;
      expect(run.assigned, [selected.sublist(0, 5), selected.sublist(5, 10), selected.sublist(10)]);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 1 -> PASS (exit 0)')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> FAIL (exit 70)')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 3 -> PASS (exit 0)')).called(1);
      // Regression: acme 2026-10-02 said NOT VERIFIED although tests really failed.
      final errors = _loggedErrors();
      expect(
          errors,
          contains('[ios-waves] FAIL across waves: 1 test(s) failed: ${selected[6]}; '
              '12/12 shards assigned and 11/12 Dart results verified.'));
      expect(errors, isNot(contains(startsWith('[ios-waves] NOT VERIFIED across waves'))));
    });

    String skippedLog(int index) => _iosInstrumentationFixture(index)
        .replaceFirst('passed=true details=', 'passed=false details=Dart test skipped at runtime')
        .replaceFirst("' passed (62.769 seconds)", "' failed (62.769 seconds)")
        .replaceFirst(
            'Test Case',
            'Runner[1:2] MPLATROL_TEST_SKIPPED coordinator shard '
                'method=${_iosCoordinatorFixtureSelected[index]} NOT RUN: Dart test skipped at runtime\nTest Case');

    String failedLog(int index) => _iosInstrumentationFixture(index).replaceFirst('passed=true', 'passed=false');

    test('a wave whose only non-pass skipped itself at runtime is NOT VERIFIED, not FAIL', () async {
      final run = await _runIosWaveFixture(
          failedShards: {6}, iosLog: (index) => index == 6 ? skippedLog(6) : _iosInstrumentationFixture(index));

      expect(run.result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> NOT VERIFIED (exit 69)')).called(1);
      final selected = _iosCoordinatorFixtureSelected;
      final errors = _loggedErrors();
      expect(
          errors,
          contains('[ios-waves] every non-passing test of this wave skipped itself at '
              'runtime, at least one without a reason: NOT VERIFIED, not FAIL.'));
      expect(
          errors,
          contains('[ios-waves] NOT VERIFIED across waves: 12/12 shards assigned and 11/12 '
              'Dart results verified; every selected test must be assigned and verified exactly once. '
              'NOT RUN (skipped at runtime): ${selected[6]} (Dart test skipped at runtime).'));
    });

    String explainedSkipLog(int index) => skippedLog(index).replaceAll(
        'Dart test skipped at runtime', 'MOCK_TENANT_MISMATCH PROJ-TC-23589 needs an app prepared for soylent');

    // Regression: r11 lt-ios legs could never pass, because every runtime skip blocked them.
    test('a wave whose only non-pass skipped itself with a reason is NOT RUN, and the job passes', () async {
      final run = await _runIosWaveFixture(
          failedShards: {6}, iosLog: (index) => index == 6 ? explainedSkipLog(6) : _iosInstrumentationFixture(index));

      expect(run.result, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> PASS (exit 0)')).called(1);
      verify(() => getDep<MplatrolLogger>()
          .info(any(that: contains('skipped itself at runtime with a reason: NOT RUN, not FAIL')))).called(1);
      final selected = _iosCoordinatorFixtureSelected;
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 12/12 shards assigned and '
          '11/11 Dart results verified.')).called(1);
      expect(_loggedErrors(), isNot(contains(contains(selected[6]))));
    });

    for (final (name, explained, expected) in [
      ('with its reason passes', true, 0),
      ('without a reason is NOT VERIFIED', false, 69),
    ]) {
      test('a single-wave job whose only non-pass skipped itself $name', () async {
        final run = await _runIosWaveFixture(
            env: const {ltIosMaxParallelEnv: '12'},
            failedShards: {6},
            iosLog: (index) => index != 6
                ? _iosInstrumentationFixture(index)
                : (explained ? explainedSkipLog(index) : skippedLog(index)));

        expect(run.yamls, hasLength(1));
        expect(run.result, expected);
      });
    }

    // Regression: r11 wayne PROJ-TC-7760 ended in 2 s before any Dart test ran and counted as failed.
    test('a session that ended before any Dart test ran is NOT VERIFIED, not FAIL', () async {
      final run = await _runIosWaveFixture(
          failedShards: {6},
          iosLog: (index) => index == 6
              ? '2026-10-06 Runner[1:2] PATROL_SELECTION_SOURCE source=coordinator '
                  'method=${_iosCoordinatorFixtureSelected[6]} attempt=1\nRunner was killed\n'
              : _iosInstrumentationFixture(index));
      final selected = _iosCoordinatorFixtureSelected;

      expect(run.result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> NOT VERIFIED (exit 69)')).called(1);
      final errors = _loggedErrors();
      expect(
          errors,
          contains('[ios-waves] ${selected[6]}: the session ended before any Dart test ran '
              '(LambdaTest infrastructure), so NOT VERIFIED, not a test failure.'));
      expect(errors, isNot(contains(startsWith('[ios-waves] FAIL across waves'))));
    });

    test('a session without Dart output beside a real failure still FAILs its wave', () async {
      final run = await _runIosWaveFixture(
          failedShards: {6, 7},
          iosLog: (index) => switch (index) {
                6 => '2026-10-06 Runner[1:2] PATROL_SELECTION_SOURCE source=coordinator '
                    'method=${_iosCoordinatorFixtureSelected[6]} attempt=1\n',
                7 => failedLog(index),
                _ => _iosInstrumentationFixture(index),
              });

      expect(run.result, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> FAIL (exit 70)')).called(1);
    });

    // Regression: acme lt-ios 2026-10-02 had real failures in waves 3 and 4
    // and runtime skips in waves 1 and 3, yet reported NOT VERIFIED.
    test('real failures beside runtime skips FAIL the device job and name both', () async {
      final run = await _runIosWaveFixture(
        failedShards: {2, 6, 7},
        iosLog: (index) => switch (index) {
          2 || 7 => skippedLog(index),
          6 => failedLog(index),
          _ => _iosInstrumentationFixture(index),
        },
      );

      expect(run.result, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 1 -> NOT VERIFIED (exit 69)')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> FAIL (exit 70)')).called(1);
      final selected = _iosCoordinatorFixtureSelected;
      expect(
          _loggedErrors(),
          contains('[ios-waves] FAIL across waves: 1 test(s) failed: ${selected[6]}; '
              '12/12 shards assigned and 9/12 Dart results verified. NOT RUN (skipped at runtime): '
              '${selected[2]} (Dart test skipped at runtime), ${selected[7]} (Dart test skipped at runtime).'));
    });

    test('a non-passing session without a readable assigned test counts as neither fail nor skip', () async {
      final run = await _runIosWaveFixture(
          failedShards: {6}, iosLog: (index) => index == 6 ? 'no selection here' : _iosInstrumentationFixture(index));

      expect(run.result, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> FAIL (exit 70)')).called(1);
      expect(
          _loggedErrors(),
          contains('[ios-waves] NOT VERIFIED across waves: 12/12 shards assigned and 11/12 '
              'Dart results verified; every selected test must be assigned and verified exactly once.'));
    });

    test('a failed wave whose job evidence is unavailable verifies none of its sessions', () async {
      final run = await _runIosWaveFixture(failedShards: {6}, failedJobProviderStatus: 503);

      expect(run.result, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().warn('[ios-waves] could not verify the sessions '
          'of job $_currentJobId: HttpException.')).called(1);
      expect(
          _loggedErrors(),
          contains(startsWith('[ios-waves] NOT VERIFIED across waves: '
              '12/12 shards assigned and 7/12 Dart results verified;')));
    });

    test('a wave whose tunnel fails to start is retried once', () async {
      final run = await _runIosWaveFixture(tunnelFailCalls: {2});

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1, 2, 3, 4],
        [5, 6, 7, 8, 9],
        [5, 6, 7, 8, 9],
        [10, 11],
      ]);
      final selected = _iosCoordinatorFixtureSelected;
      expect(run.assigned, [selected.sublist(0, 5), <String>[], selected.sublist(5, 10), selected.sublist(10)]);
      verify(() => getDep<MplatrolLogger>().warn('[hyperexecute] the iOS job tunnel failed to start '
          'before any session ran; retrying the job once in 0s.')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 12/12 shards '
          'assigned and 12/12 Dart results verified.')).called(1);
    });

    test('a wave whose tunnel port is already in use is retried once', () async {
      final run = await _runIosWaveFixture(tunnelFailCalls: {2}, tunnelPortInUse: true);

      expect(run.result, ExitCode.success.code);
      expect(run.yamls, hasLength(4));
      verify(() => getDep<MplatrolLogger>().warn('[hyperexecute] the iOS job tunnel failed to start '
          'before any session ran; retrying the job once in 0s.')).called(1);
    });

    test('a wave whose tunnel fails to start twice is NOT RUN, not retried again', () async {
      final run = await _runIosWaveFixture(tunnelFailCalls: {2, 3});

      expect(run.result, ExitCode.software.code);
      expect(run.yamls, hasLength(4));
      verify(() =>
              getDep<MplatrolLogger>().warn(any(that: startsWith('[hyperexecute] the iOS job tunnel failed to start'))))
          .called(1);
      verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('lesson lambdaTestTunnel (observed '))))
          .called(1);
      final errors = _loggedErrors();
      expect(errors.where((e) => e.startsWith('[ios-shard-coordinator] NOT RUN')), hasLength(5));
      expect(
          errors,
          contains('[ios-waves] NOT VERIFIED across waves: 7/12 shards assigned '
              'and 7/12 Dart results verified; every selected test must be assigned and '
              'verified exactly once.'));
    });

    // Regression: acme lt-ios 2026-10-02 wave 2 lost
    // testBFastFailsInsideTheWebViewOnABadCredential to one device session whose
    // coordinator requests were all refused while its four neighbours passed.
    test('a shard whose session never reached the coordinator runs once more after the last wave', () async {
      final run = await _runIosWaveFixture(unreachableShards: {9});

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1, 2, 3, 4],
        [5, 6, 7, 8, 9],
        [10, 11],
        [9],
      ]);
      expect(run.yamls.last, contains('concurrency: 1\n'));
      expect(run.yamls.last, contains('buildName: "ios-waves_retry"'));
      expect(run.yamls.last, contains('- name: "shard 10"\n'));
      final selected = _iosCoordinatorFixtureSelected;
      expect(run.assigned, [
        selected.sublist(0, 5),
        selected.sublist(5, 9),
        selected.sublist(10),
        [selected[9]]
      ]);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> FAIL (exit 70)')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] retry: shard(s) 10 whose device session '
          'never reached the coordinator (LT build "ios-waves_retry")')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] retry -> PASS (exit 0)')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 12/12 shards '
          'assigned and 12/12 Dart results verified.')).called(1);
    });

    test('a retry whose session again cannot reach the coordinator is NOT VERIFIED', () async {
      final run = await _runIosWaveFixture(unreachableShards: {9}, unreachableOnRetry: true);

      expect(run.result, ExitCode.unavailable.code);
      expect(run.yamls, hasLength(4));
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] retry -> NOT VERIFIED (exit 69)')).called(1);
      expect(
          _loggedErrors(),
          contains('[ios-waves] NOT VERIFIED across waves: 11/12 shards assigned '
              'and 11/12 Dart results verified; every selected test must be assigned and '
              'verified exactly once.'));
    });

    test('a wave with a real failure beside an unreachable session is not retried', () async {
      final run = await _runIosWaveFixture(
        unreachableShards: {9},
        failedShards: {6},
        iosLog: (index) {
          final log = _iosInstrumentationFixture(index);
          return index == 6 ? log.replaceFirst('passed=true', 'passed=false') : log;
        },
      );

      expect(run.result, ExitCode.software.code);
      expect(run.yamls, hasLength(3));
      verifyNever(() => getDep<MplatrolLogger>().info(any(that: startsWith('[ios-waves] retry'))));
    });

    test('a wave session beyond its wave cannot take a shard of a later wave', () async {
      final run = await _runIosWaveFixture(extraSession: true);

      expect(run.result, ExitCode.success.code);
      expect(run.extraStatuses, [HttpStatus.conflict, HttpStatus.conflict, HttpStatus.conflict]);
      final selected = _iosCoordinatorFixtureSelected;
      expect(run.assigned, [selected.sublist(0, 5), selected.sublist(5, 10), selected.sublist(10)]);
    });

    test('a failed wave still runs the later waves and its failure wins', () async {
      final run = await _runIosWaveFixture(waveExit: (wave) => wave == 2 ? 1 : 0);

      expect(run.result, ExitCode.software.code);
      expect(run.yamls, hasLength(3));
      final selected = _iosCoordinatorFixtureSelected;
      // Wave 3 cannot take the shards wave 2 left unassigned.
      expect(run.assigned, [selected.sublist(0, 5), <String>[], selected.sublist(10)]);
      final errors = _loggedErrors();
      expect(errors.where((e) => e.startsWith('[ios-shard-coordinator] NOT RUN')), hasLength(5));
      for (final method in selected.sublist(5, 10)) {
        expect(errors, contains(contains('NOT RUN (infrastructure): $method ')));
      }
      expect(
          errors,
          contains('[ios-waves] NOT VERIFIED across waves: 7/12 shards assigned '
              'and 7/12 Dart results verified; every selected test must be assigned and '
              'verified exactly once.'));
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] wave 2 -> FAIL (exit 70)')).called(1);
    });

    test('a stalled wave is stopped and the next wave still runs', () async {
      final run = await _runIosWaveFixture(stallWave: 1);

      expect(run.result, ExitCode.unavailable.code);
      expect(run.yamls, hasLength(3));
      final selected = _iosCoordinatorFixtureSelected;
      expect(run.assigned, [<String>[], selected.sublist(5, 10), selected.sublist(10)]);
      expect(_loggedErrors(), contains(startsWith('[hyperexecute-watchdog] first wave stalled.')));
    });

    test('a Dart result repeated by a later wave is not verified', () async {
      final run = await _runIosWaveFixture(
        files: {
          'patrol_login_test': ['case 0'],
          'other_test': ['case 0']
        },
        env: const {ltIosMaxParallelEnv: '1'},
        iosLog: (index) => _iosInstrumentationFixtureNamed(index, 'patrol_login_test case 0'),
      );

      expect(run.result, ExitCode.unavailable.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0],
        [1]
      ]);
      expect(_loggedErrors(), contains(contains('iOS native Dart result repeated across waves')));
    });

    test('each wave is as big as the machine-wide session budget allows', () async {
      final slots = Directory.systemTemp.createTempSync('mplatrol_lt_slots');
      addTearDown(() => slots.deleteSync(recursive: true));
      final budget = LtSlotBudget(directory: slots.path, limit: 7, logger: getDep<MplatrolLogger>());

      final run = await _runIosWaveFixture(env: const {ltIosMaxParallelEnv: '10'}, slotBudget: budget);

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1, 2, 3, 4, 5, 6],
        [7, 8, 9, 10, 11],
      ]);
      expect(run.yamls.first, contains('concurrency: 7\n'));
      expect(File(p.join(slots.path, 'usage.log')).readAsLinesSync().map((line) => line.split(' ').skip(1).join(' ')), [
        'grant 7 ios-waves inUse=7/7',
        'release 7 ios-waves inUse=0/7',
        'grant 5 ios-waves_wave2 inUse=5/7',
        'release 5 ios-waves_wave2 inUse=0/7',
      ]);
    });

    test('a misconfigured session budget refuses the run before building', () async {
      final run = await _runIosWaveFixture(env: const {ltMaxConcurrentSessionsEnv: 'none', 'HOME': '/tmp'});

      expect(run.result, ExitCode.usage.code);
      expect(run.yamls, isEmpty);
      expect(
          _loggedErrors().single,
          '$ltMaxConcurrentSessionsEnv must be a positive whole number of LambdaTest '
          'sessions (got "none").');
    });

    group('per-user session cap', () {
      late Directory home;
      late LtSlotBudget budget;

      setUp(() {
        home = Directory.systemTemp.createTempSync('mplatrol_lt_user_cap');
        budget = LtSlotBudget(directory: p.join(home.path, 'lt-slots'), limit: 30, logger: getDep<MplatrolLogger>());
      });
      tearDown(() => home.deleteSync(recursive: true));

      List<String> userUsage() => File(p.join(home.path, '.mplatrol', 'lt-user-slots', 'user-a', 'usage.log'))
          .readAsLinesSync()
          .map((line) => line.split(' ').skip(1).join(' '))
          .toList();

      test('waves hold at most the sessions the test user pool may serve', () async {
        final run = await _runIosWaveFixture(
            env: {ltIosMaxParallelEnv: '10', 'HOME': home.path},
            runEnv: const {e2eUserKeysEnv: 'user-a'},
            slotBudget: budget);

        expect(run.result, ExitCode.success.code);
        expect(run.yamls.map(_iosYamlWave), [
          [0, 1, 2, 3],
          [4, 5, 6, 7],
          [8, 9, 10, 11],
        ]);
        verify(() => getDep<MplatrolLogger>().info('[lt-user-cap] ios-waves: 4 of 10 device session(s), share 4 of '
                'the test user cap of 4 (1 live LT leg(s) of this user; 4 per verified user x 1 verified user(s))'))
            .called(1);
        expect(
            Directory(p.join(home.path, '.mplatrol', 'lt-user-slots', 'user-a'))
                .listSync()
                .where((file) => file.path.endsWith('.leg')),
            isEmpty,
            reason: 'the leg left once it ended');
        expect(userUsage(), contains('grant 4 ios-waves_wave3 inUse=4/4'));
      });

      test('waves of a leg whose users another live leg shares stay within its share', () async {
        final android = LtUserSessionCap(
                directory: p.join(home.path, '.mplatrol', 'lt-user-slots', 'user-a'),
                users: 1,
                perUser: 4,
                logger: getDep<MplatrolLogger>())
            .join('demo:lt-android');
        addTearDown(android.leave);
        final run = await _runIosWaveFixture(
            shardCount: 5,
            env: {ltIosMaxParallelEnv: '10', 'HOME': home.path},
            runEnv: const {e2eUserKeysEnv: 'user-a'},
            slotBudget: budget);

        expect(run.result, ExitCode.success.code);
        expect(run.yamls.map(_iosYamlWave), [
          [0, 1],
          [2, 3],
          [4],
        ]);
        expect(userUsage(), contains('grant 2 ios-waves inUse=2/4'));
      });

      test('a retry bigger than the cap runs in parts instead of dropping shards', () async {
        final run = await _runIosWaveFixture(
            env: {ltIosMaxParallelEnv: '10', 'HOME': home.path},
            runEnv: const {e2eUserKeysEnv: 'user-a'},
            unreachableShards: {2, 3, 6, 7, 11},
            slotBudget: budget);

        expect(run.result, ExitCode.success.code);
        expect(run.yamls.map(_iosYamlWave).skip(3), [
          [2, 3, 6, 7],
          [11],
        ]);
        expect(userUsage(), containsAll(['grant 4 ios-waves_retry inUse=4/4', 'grant 1 ios-waves_retry2 inUse=1/4']));
      });

      test('a retry part that fails decides the retry verdict', () async {
        final run = await _runIosWaveFixture(
            env: {ltIosMaxParallelEnv: '10', 'HOME': home.path},
            runEnv: const {e2eUserKeysEnv: 'user-a'},
            unreachableShards: {2, 3, 6, 7, 11},
            failedShards: {11},
            slotBudget: budget);

        expect(run.result, isNot(ExitCode.success.code));
        expect(run.result, isNot(ExitCode.unavailable.code));
      });

      test('refuses an external coordinator whose shards would run on more sessions than the cap', () async {
        final run = await _runIosWaveFixture(
            shardCount: 5,
            env: {ltIosMaxParallelEnv: '10', 'HOME': home.path},
            runEnv: const {
              e2eUserKeysEnv: 'user-a',
              'MPLATROL_IOS_SHARD_COORDINATOR_URL': 'http://coordinator.test/assign',
            },
            slotBudget: budget);

        expect(run.result, ExitCode.usage.code);
        expect(run.yamls, isEmpty);
        expect(
            _loggedErrors().single,
            '5 iOS shards run at once with the external coordinator in '
            'MPLATROL_IOS_SHARD_COORDINATOR_URL, more than the 4 LambdaTest sessions this run may hold '
            '($ltSessionsPerUserEnv per test user, $ltMaxConcurrentSessionsEnv machine-wide). Unset it, '
            'or select at most 4 tests.');
      });

      test('a misconfigured per-user cap refuses the run before building', () async {
        final run = await _runIosWaveFixture(
            env: {ltSessionsPerUserEnv: 'all', 'HOME': home.path}, runEnv: const {e2eUserKeysEnv: 'user-a'});

        expect(run.result, ExitCode.usage.code);
        expect(run.yamls, isEmpty);
        expect(_loggedErrors().single, contains('$ltSessionsPerUserEnv must be a positive whole number'));
      });
    });

    test('a retry wave leases its sessions too', () async {
      final slots = Directory.systemTemp.createTempSync('mplatrol_lt_slots');
      addTearDown(() => slots.deleteSync(recursive: true));
      final budget = LtSlotBudget(directory: slots.path, limit: 30, logger: getDep<MplatrolLogger>());

      final run = await _runIosWaveFixture(unreachableShards: {4}, slotBudget: budget);

      expect(run.result, ExitCode.success.code);
      expect(File(p.join(slots.path, 'usage.log')).readAsStringSync(), contains('grant 1 ios-waves_retry inUse=1/30'));
    });

    group('coordinator port', () {
      Future<int> freePort() async {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        return port;
      }

      int coordinatorPort() => Uri.parse(_iosCoordinatorFixtureUrl!).port;

      test('listens on the configured port so the compiled URL stays the same', () async {
        final port = await freePort();
        final run = await _runIosWaveFixture(shardCount: 2, env: {iosShardCoordinatorPortEnv: '$port'});

        expect(run.result, ExitCode.success.code);
        expect(coordinatorPort(), port);
      });

      test('takes another port when the configured one is busy', () async {
        final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(busy.close);

        final run = await _runIosWaveFixture(shardCount: 2, env: {iosShardCoordinatorPortEnv: '${busy.port}'});

        expect(run.result, ExitCode.success.code);
        expect(coordinatorPort(), isNot(busy.port));
        verify(() => getDep<MplatrolLogger>().warn('[ios-shard-coordinator] port ${busy.port} '
            '($iosShardCoordinatorPortEnv) is in use; using another port, which changes the iOS build, so this '
            'run cannot reuse an earlier upload.')).called(1);
      });

      test('ignores a value that is not a port', () async {
        final run = await _runIosWaveFixture(shardCount: 2, env: const {iosShardCoordinatorPortEnv: 'any'});

        expect(run.result, ExitCode.success.code);
        verify(() => getDep<MplatrolLogger>()
            .warn('[ios-shard-coordinator] ignoring $iosShardCoordinatorPortEnv="any": not a port number.')).called(1);
      });
    });

    test('a released leg runs every wave outside the checkout', () async {
      final leg = Directory.systemTemp.createTempSync('mplatrol_leg');
      addTearDown(() => leg.deleteSync(recursive: true));
      when(() => getDep<MplatrolShell>().runArgs('git', ['rev-parse', '--short=12', 'HEAD'],
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: false,
          silent: true)).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 0, 'abc\n', '')));
      getDep<ItLegDir>().expectedUploads = 1;

      final run = await _runIosWaveFixture(env: {itLegDirEnv: leg.path, ltIosMaxParallelEnv: '5'});

      expect(run.result, ExitCode.success.code);
      expect(run.yamls, hasLength(3));
      expect(
          File(p.join(leg.path, 'hyperexecute', 'ios', '.mplatrol', 'hyperexecute-lt-ios.yaml')).existsSync(), isTrue);
      expect(getDep<ItLegDir>().released, isTrue);
    });

    test('shards within the limit run as one unchanged job', () async {
      final run = await _runIosWaveFixture(shardCount: 5);

      expect(run.result, ExitCode.success.code);
      expect(run.yamls, hasLength(1));
      expect(run.yamls.single, contains('concurrency: 5\n'));
      expect(run.yamls.single, contains('buildName: "ios-waves"\n'));
      expect(_iosYamlWave(run.yamls.single), [0, 1, 2, 3, 4]);
      verifyNever(() => getDep<MplatrolLogger>().info(any(that: startsWith('[ios-waves]'))));
    });

    test('the environment overrides the configured device limit', () async {
      _stubConfiguredIosMaxParallel(2);
      final run = await _runIosWaveFixture(shardCount: 4, env: const {ltIosMaxParallelEnv: ' 3 '});

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1, 2],
        [3]
      ]);
    });

    test('the configured device limit applies without the environment', () async {
      _stubConfiguredIosMaxParallel(2);
      final run = await _runIosWaveFixture(shardCount: 4, env: const {});

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1],
        [2, 3]
      ]);
    });

    for (final value in ['0', '-2', 'five']) {
      test('refuses device limit "$value" before building', () async {
        final run = await _runIosWaveFixture(env: {ltIosMaxParallelEnv: value});

        expect(run.result, ExitCode.usage.code);
        expect(run.yamls, isEmpty);
        expect(
            _loggedErrors().single,
            '$ltIosMaxParallelEnv / it.lt-ios-max-parallel must be '
            'a positive whole number of devices (got "$value").');
        verifyNever(() => getDep<LtIosRunner>().buildIosForHyperexecute(
            target: any(named: 'target'),
            env: any(named: 'env'),
            shards: any(named: 'shards'),
            selection: any(named: 'selection'),
            selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl')));
      });
    }

    test('refuses a configured device limit below one', () async {
      _stubConfiguredIosMaxParallel(0);
      final run = await _runIosWaveFixture(env: const {});

      expect(run.result, ExitCode.usage.code);
      expect(_loggedErrors().single, contains('(got "0")'));
    });

    test('refuses waves with an external coordinator', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(() => getDep<PlatformWrapper>().environment).thenReturn({ltIosMaxParallelEnv: '1'});

      final result = await LtHyperexecuteRunner().runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'MPLATROL_IOS_SHARD_COORDINATOR_URL': 'http://coordinator.test/assign'},
      );

      expect(result, ExitCode.usage.code);
      expect(_loggedErrors().single, contains('2 iOS shards need waves of at most 1 devices'));
    });
  });
}

void _registerIosAssignmentCoverageTests() {
  for (final (name, requests, repeat, expected) in [
    ('zero assignments / NoShard', 0, false, ExitCode.unavailable.code),
    ('partial exact Dart assignments', 1, false, ExitCode.unavailable.code),
    ('same assignment replayed twice', 2, true, ExitCode.unavailable.code),
    ('complete exact Dart assignments', 2, false, ExitCode.success.code),
  ]) {
    test('passed provider native metadata requires $name', () async {
      _iosCoordinatorFixtureRepeatSession = repeat;
      final result = await _runIosVerdictFixture(job: _passedJob(), assignmentRequests: requests);
      expect(result, expected);
      expect(_iosCoordinatorFixtureAssigned.length, requests);
      final assigned = _iosCoordinatorFixtureAssigned.toSet();
      expect(assigned.every(_iosCoordinatorFixtureSelected.contains), isTrue);
      if (expected == ExitCode.success.code) {
        expect(assigned, _iosCoordinatorFixtureSelected.toSet());
      } else {
        expect(assigned.length, lessThan(_iosCoordinatorFixtureSelected.length));
        verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute iOS E2E passed.'));
        verify(() => getDep<MplatrolLogger>().err(any(that: contains('do not exhaust selected Dart shards'))))
            .called(1);
      }
    });
  }
}

String _actualAssumptionLog() =>
    File(p.join('test', 'fixtures', 'integration_test', 'android_runtime_assumption_skip.log')).readAsStringSync();

Future<int> _runNativeAssumptionFixture({
  String? instrumentation,
  int logStatus = 200,
  bool throwLog = false,
  bool wrongProviderIdentity = false,
  List<int>? logStatuses,
  Exception? logError,
  int? expectedInstrumentationCalls,
  Map<String, String> logHeaders = const {},
  Duration pollDelay = Duration.zero,
}) async {
  final repo = Directory.systemTemp.createTempSync('native-skip-verdict-');
  addTearDown(() => repo.deleteSync(recursive: true));
  final testFile = File(p.join(repo.path, 'patrol_test/cardhub_user_journey_test.dart'));
  testFile.parent.createSync(recursive: true);
  testFile.writeAsStringSync("patrolTest('opens a card and its Alerts and Controls through CardHub', "
      '(\$) async {});\n');
  _stubRepo(repo);
  _stubJobResult(0, 'Pass test stage percentage: 100.00%\n');
  final sessions = jsonDecode(
      File(p.join('test', 'fixtures', 'integration_test', 'android_runtime_assumption_skip_sessions.json'))
          .readAsStringSync()) as Map<String, dynamic>;
  final session = (sessions['data'] as List).single as Map;
  final sessionId = session['sessionID'] as String;
  if (wrongProviderIdentity) {
    session['scenario_name'] = 'mplatrol.e2e.OtherTest/not_selected';
  }
  final job = _passedJob();
  job['data']['totalTests'] = 1;
  job['data']['tasks'] = [
    {'id': session['taskID'], 'status': 'passed'}
  ];
  var instrumentationCalls = 0;
  _stubLtGet((url) {
    if (url.startsWith(_providerJobUrl)) {
      return http.Response(jsonEncode(url.contains('/sessions?') ? sessions : job), 200);
    }
    if (url.contains('/builds?')) {
      return http.Response(
          jsonEncode({
            'data': [
              {'name': 'android-build', 'build_id': 'controlled-skip-build'}
            ]
          }),
          200);
    }
    if (url.contains('/sessions?build_id=')) {
      return http.Response(
          jsonEncode({
            'data': [
              {'session_id': sessionId, 'status_ind': 'passed'}
            ]
          }),
          200);
    }
    if (url.contains('$sessionId/log/instrumentation')) {
      instrumentationCalls++;
      if (throwLog || logError != null) {
        throw logError ?? const SocketException('fixture instrumentation unavailable');
      }
      final status = logStatuses == null ? logStatus : logStatuses[instrumentationCalls - 1];
      return http.Response(instrumentation ?? _actualAssumptionLog(), status, headers: logHeaders);
    }
    return http.Response('{}', 200);
  }, includePassedJob: false);
  final result = await LtHyperexecuteRunner(pollDelay: pollDelay).runAndroid(
    target: 'patrol_test/cardhub_user_journey_test.dart',
    devices: const ['Pixel 8-14'],
    idleTimeoutSeconds: 240,
    env: _androidEnv,
  );
  if (expectedInstrumentationCalls != null) {
    expect(instrumentationCalls, expectedInstrumentationCalls);
  } else if (!wrongProviderIdentity && logStatus == 200 && !throwLog && logError == null) {
    expect(instrumentationCalls, 1);
  }
  verifyNever(() => getDep<LtHttp>().patchJson(any(), headers: any(named: 'headers'), body: any(named: 'body')));
  if (result != ExitCode.success.code) {
    verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute Android E2E passed.'));
  }
  return result;
}

void _registerNativeAssumptionSkipRegression() {
  _registerNativeAnnotationRunnerCases();
  _registerInstrumentationFetchDiagnostics();
  test('actual Android assumption skip cannot pass provider-green verdict', () async {
    expect(await _runNativeAssumptionFixture(), ExitCode.unavailable.code);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('skipped (JUnit assumption/status -4)')))).called(1);
  });
  // LambdaTest marks an Android test that reported NOT RUN (status -4 plus
  // MPLATROL_TEST_SKIPPED) as passed; mplatrol must never count it as a pass.
  test('a provider-passed Android NOT RUN test (-4 and MPLATROL_TEST_SKIPPED) is not a pass', () async {
    final log = _actualAssumptionLog().replaceFirst(
        'INSTRUMENTATION_STATUS_CODE: -4',
        'INSTRUMENTATION_STATUS: stream=MPLATROL_TEST_SKIPPED CARDHUB_JOURNEY_NOT_RUN\n'
            'INSTRUMENTATION_STATUS_CODE: -4');
    expect(await _runNativeAssumptionFixture(instrumentation: log), ExitCode.unavailable.code);
    verify(() => getDep<MplatrolLogger>()
        .err(any(that: contains('skipped (JUnit assumption/status -4); a native skip is not a pass')))).called(1);
    verifyNever(() => getDep<MplatrolLogger>().success(any()));
  });
  test('a provider-passed Android skip with its reason is NOT RUN, not a failure of the job', () async {
    final log = _actualAssumptionLog().replaceFirst('AssumptionViolatedException: Dart test skipped at runtime',
        'AssumptionViolatedException: CARDHUB_JOURNEY_NOT_RUN not_in_more_menu');
    expect(await _runNativeAssumptionFixture(instrumentation: log), ExitCode.success.code);
    verify(() => getDep<MplatrolLogger>().info(any(
            that: allOf(
                startsWith('not-run: native test '), endsWith('skipped: CARDHUB_JOURNEY_NOT_RUN not_in_more_menu')))))
        .called(1);
  });
  for (final status in [404, 503]) {
    test('provider-green Android fails closed without log HTTP $status', () async {
      expect(await _runNativeAssumptionFixture(logStatus: status), ExitCode.unavailable.code);
    });
  }
  test('provider-green Android fails closed on log transport error', () async {
    expect(await _runNativeAssumptionFixture(throwLog: true), ExitCode.unavailable.code);
  });
  for (final log in ['', 'OK (1 test)', 'INSTRUMENTATION_STATUS_CODE: -4']) {
    test('provider-green Android rejects unidentified log: $log', () async {
      expect(await _runNativeAssumptionFixture(instrumentation: log), ExitCode.unavailable.code);
    });
  }
  test('provider-green Android cannot substitute an unselected native test', () async {
    expect(await _runNativeAssumptionFixture(wrongProviderIdentity: true), ExitCode.unavailable.code);
  });
  test('matching native pass ignores incidental assumption prose', () async {
    final log = _actualAssumptionLog()
        .replaceAll('INSTRUMENTATION_STATUS_CODE: -4', 'INSTRUMENTATION_STATUS_CODE: 0')
        .replaceAll('INSTRUMENTATION_STATUS: stack=', 'INSTRUMENTATION_STATUS: stream=');
    expect(await _runNativeAssumptionFixture(instrumentation: log), ExitCode.success.code);
  });
  test('log from an unrelated native identity cannot verify this session', () async {
    final log = _actualAssumptionLog().replaceAll('CardhubUserJourneyTest', 'UnrelatedTest');
    expect(await _runNativeAssumptionFixture(instrumentation: log), ExitCode.unavailable.code);
  });
  test('matching native failure overrides provider pass', () async {
    final log = _actualAssumptionLog()
        .replaceAll('INSTRUMENTATION_STATUS_CODE: -4', 'INSTRUMENTATION_STATUS_CODE: -2')
        .replaceAll('org.junit.AssumptionViolatedException', 'java.lang.AssertionError');
    expect(await _runNativeAssumptionFixture(instrumentation: log), ExitCode.unavailable.code);
  });
}

void _registerNativeAnnotationRunnerCases() {
  for (final missing in [false, true]) {
    test('current native ${missing ? 'UNVERIFIED' : 'SKIPPED'} annotation retains nonpass', () async {
      final fixture = _AnnotationRunnerFixture(missing: missing);
      fixture.stub();
      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
          target: 'patrol_test/cardhub_user_journey_test.dart',
          devices: const ['Pixel 8-14'],
          idleTimeoutSeconds: 240,
          env: _androidEnv);
      expect(result, ExitCode.unavailable.code);
      expect(fixture.body?['status_ind'], 'failed');
      expect(fixture.body?['name'], missing ? '[UNVERIFIED] native test' : '[SKIPPED] native test');
      expect(fixture.readbacks, 1);
      verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute Android E2E passed.'));
    });
  }
}

class _AnnotationRunnerFixture {
  _AnnotationRunnerFixture({required this.missing});
  final bool missing;
  Map<String, dynamic>? body;
  int readbacks = 0;
  late Map session;
  late Map sessions;
  late Map job;

  void stub() {
    final repo = Directory.systemTemp.createTempSync('annotation-verdict-');
    addTearDown(() => repo.deleteSync(recursive: true));
    final file = File(p.join(repo.path, 'patrol_test/cardhub_user_journey_test.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync("patrolTest('opens a card and its Alerts and Controls through CardHub', "
        '(\$) async {});\n');
    _stubRepo(repo);
    _stubJobResult(0, 'Pass test stage percentage: 100.00%\n');
    sessions = jsonDecode(
        File(p.join('test', 'fixtures', 'integration_test', 'android_runtime_assumption_skip_sessions.json'))
            .readAsStringSync()) as Map;
    session = (sessions['data'] as List).single as Map;
    job = _passedJob();
    job['data']['totalTests'] = 1;
    job['data']['tasks'] = [
      {'id': session['taskID'], 'status': 'passed'}
    ];
    _stubLtGet(_get, includePassedJob: false);
    _stubLtPatch((url, value) {
      expect(url, _nativeUrl);
      body = value;
      return http.Response('{}', 200);
    });
  }

  String get _nativeUrl => 'https://mobile-api.lambdatest.com/mobile-automation/api/v1/'
      'sessions/${session['sessionID']}';

  Map<String, dynamic> get _native => {
        'session_id': session['sessionID'],
        'test_id': 'native-test-current',
        'platform': 'Android',
        'build_id': 28244439,
        'status_ind': body?['status_ind'] ?? 'passed',
        'name': body?['name'] ?? 'original',
        'customdata': {'customData': body?['custom_data'] ?? {}}
      };

  http.Response _get(String url) {
    if (url.startsWith(_providerJobUrl)) {
      return http.Response(jsonEncode(url.contains('/sessions?') ? sessions : job), 200);
    }
    if (url == _nativeUrl) {
      if (body != null) {
        readbacks++;
      }
      return http.Response(jsonEncode({'data': _native}), 200);
    }
    if (url.contains('/sessions?build_id=28244439')) {
      return http.Response(
          jsonEncode({
            'data': [_native],
            'metadata': {'total': 1, 'hasmore': false}
          }),
          200);
    }
    if (url.endsWith('/log/instrumentation')) {
      return _instrumentationResponse();
    }
    return http.Response('{}', 200);
  }

  http.Response _instrumentationResponse() => http.Response(missing ? '' : _actualAssumptionLog(), missing ? 404 : 200);
}

void _registerInstrumentationFetchDiagnostics() {
  _registerProviderFailureContextTests();
  for (final status in [401, 403, 404, 503, 599]) {
    test('instrumentation exhaustion identifies session and HTTP $status safely', () async {
      expect(
          await _runNativeAssumptionFixture(
              logStatus: status,
              instrumentation: 'Authorization: Basic private-fixture-body',
              expectedInstrumentationCalls: 4),
          ExitCode.unavailable.code);
      final messages = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>();
      final diagnostic = messages.singleWhere((message) => message.contains('instrumentation fetch exhausted'));
      expect(diagnostic, contains('RMAA-AND-1913856-1790755176845516515SLC'));
      expect(diagnostic, contains('after 4 attempts'));
      expect(diagnostic, contains('attempt 4: HTTP $status'));
      if (status == 599) {
        expect(diagnostic, contains('transport failure'));
      }
      expect(messages.join('\n'), isNot(contains('private-fixture-body')));
    });
  }
  test('instrumentation exhaustion reports exception type without secret message', () async {
    expect(
        await _runNativeAssumptionFixture(
            logError: const SocketException('https://fixture?token=private-fixture-error'),
            expectedInstrumentationCalls: 4),
        ExitCode.unavailable.code);
    final messages = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>();
    expect(messages.join('\n'), contains('attempt 4: exception SocketException'));
    expect(messages.join('\n'), isNot(contains('private-fixture-error')));
  });
  test('instrumentation exhaustion preserves each retry HTTP status', () async {
    expect(await _runNativeAssumptionFixture(logStatuses: [404, 503, 599, 403], expectedInstrumentationCalls: 4),
        ExitCode.unavailable.code);
    verify(() => getDep<MplatrolLogger>().err(any(
        that: contains('attempt 1: HTTP 404; attempt 2: HTTP 503; '
            'attempt 3: HTTP 599 (transport failure); attempt 4: HTTP 403')))).called(1);
  });
  test('positive poll delay paces instrumentation retries until publication', () async {
    final started = DateTime.now();
    expect(
        await _runNativeAssumptionFixture(
            logStatuses: [503, 200], expectedInstrumentationCalls: 2, pollDelay: const Duration(milliseconds: 20)),
        ExitCode.unavailable.code);
    expect(DateTime.now().difference(started), greaterThanOrEqualTo(const Duration(milliseconds: 20)));
    verifyNever(() => getDep<MplatrolLogger>().err(any(that: contains('instrumentation fetch exhausted'))));
  });
  test('not-ready instrumentation can publish before bounded retries exhaust', () async {
    expect(await _runNativeAssumptionFixture(logStatuses: [404, 503, 200], expectedInstrumentationCalls: 3),
        ExitCode.unavailable.code);
    verifyNever(() => getDep<MplatrolLogger>().err(any(that: contains('instrumentation fetch exhausted'))));
  });
}

void _registerProviderFailureContextTests() {
  test('exhausted fetch includes only allowlisted provider correlation and code', () async {
    expect(
        await _runNativeAssumptionFixture(
            logStatus: 404,
            expectedInstrumentationCalls: 4,
            instrumentation: '{"code":"LOG_NOT_FOUND","message":"private-body",'
                '"token":"private-token","requestId":"private-body-id"}',
            logHeaders: const {
              'X-Request-ID': 'request-123',
              'x-correlation-id': 'correlation_456',
              'x-amzn-requestid': 'aws.789',
              'authorization': 'private-auth',
              'location': 'https://private-url/?token=private-query',
            }),
        ExitCode.unavailable.code);
    final messages = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>().join('\n');
    expect(messages, contains('providerCode=LOG_NOT_FOUND'));
    expect(messages, contains('x-request-id=request-123'));
    expect(messages, contains('x-correlation-id=correlation_456'));
    expect(messages, contains('x-amzn-requestid=aws.789'));
    expect(messages, isNot(contains('private-')));
  });
  for (final value in [
    '',
    'bad\nrequest',
    'bad\rrequest',
    'bad\u0000request',
    'https://private-url/?token=private-query',
    List.filled(129, 'x').join()
  ]) {
    test('unsafe provider correlation value is omitted: length ${value.length}', () async {
      expect(
          await _runNativeAssumptionFixture(
              logStatus: 403,
              expectedInstrumentationCalls: 4,
              instrumentation: '{"code":"private-token","message":"private-body"}',
              logHeaders: {'x-request-id': value}),
          ExitCode.unavailable.code);
      final messages = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>().join('\n');
      expect(messages, contains('attempt 4: HTTP 403'));
      expect(messages, isNot(contains('x-request-id=')));
      expect(messages, isNot(contains('providerCode=')));
      expect(messages, isNot(contains('private-')));
    });
  }
  test('provider request identifier accepts the bounded 128-character limit', () async {
    final identifier = List.filled(128, 'x').join();
    expect(
        await _runNativeAssumptionFixture(
            logStatus: 404, expectedInstrumentationCalls: 4, logHeaders: {'x-request-id': identifier}),
        ExitCode.unavailable.code);
    verify(() => getDep<MplatrolLogger>().err(any(that: contains('x-request-id=$identifier')))).called(1);
  });
  for (final body in [
    'not JSON',
    '{"error":{"code":"FORBIDDEN","message":"private"}}',
    '{"code":"FORBIDDEN","error_code":"UNAUTHORIZED"}',
    List.filled(4097, 'x').join()
  ]) {
    test('provider body handling stays bounded and failclosed: length ${body.length}', () async {
      expect(await _runNativeAssumptionFixture(logStatus: 403, instrumentation: body, expectedInstrumentationCalls: 4),
          ExitCode.unavailable.code);
      final messages = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.cast<String>().join('\n');
      expect(messages, contains('attempt 4: HTTP 403'));
      expect(messages.contains('providerCode=FORBIDDEN'), body.startsWith('{"error":'));
      expect(messages, isNot(contains('private')));
    });
  }
  test('HTTP below400 still reaches strict native parser without new retries', () async {
    expect(
        await _runNativeAssumptionFixture(
            logStatus: 302, expectedInstrumentationCalls: 1, logHeaders: const {'x-request-id': 'request-123'}),
        ExitCode.unavailable.code);
    verifyNever(() => getDep<MplatrolLogger>().err(any(that: contains('instrumentation fetch exhausted'))));
  });
}

void _registerProviderCompletionGuardTests() {
  test('provider-green Android rejects contradictory runner completion', () async {
    final pass = _actualAssumptionLog()
        .replaceAll('INSTRUMENTATION_STATUS_CODE: -4', 'INSTRUMENTATION_STATUS_CODE: 0')
        .replaceAll('INSTRUMENTATION_STATUS: stack=', 'INSTRUMENTATION_STATUS: stream=');
    expect(await _runNativeAssumptionFixture(instrumentation: '$pass\nINSTRUMENTATION_CODE: 0\n'),
        ExitCode.unavailable.code);
  });
  test('provider-green Android rejects a trailing selected status block', () async {
    final pass = _actualAssumptionLog()
        .replaceAll('INSTRUMENTATION_STATUS_CODE: -4', 'INSTRUMENTATION_STATUS_CODE: 0')
        .replaceAll('INSTRUMENTATION_STATUS: stack=', 'INSTRUMENTATION_STATUS: stream=');
    const trailing = 'INSTRUMENTATION_STATUS: '
        'class=mplatrol.e2e.CardhubUserJourneyTest\n'
        'INSTRUMENTATION_STATUS: '
        'test=opens_a_card_and_its_Alerts_and_Controls_through_CardHub\n';
    expect(await _runNativeAssumptionFixture(instrumentation: '$pass\n$trailing'), ExitCode.unavailable.code);
  });
}

class _ReadinessProxy extends HttpOverrides {
  _ReadinessProxy(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    return client;
  }
}

Future<void> _serveReadinessProxy(
    ServerSocket server, String failure, List<String> requests, List<Socket> sockets, Completer<void> closed) async {
  if (failure == 'refused') {
    await server.close();
    return;
  }
  server.listen((socket) {
    sockets.add(socket);
    var replied = false;
    socket.listen((bytes) {
      requests.add(utf8.decode(bytes));
      if (replied) {
        return;
      }
      replied = true;
      final status = failure == 'status' ? 200 : 404;
      final body = failure == 'body' ? '{"error":"wrong"}' : '{"error":"not found"}';
      socket.write('HTTP/1.1 $status Test\r\n'
          'Content-Length: ${body.length}\r\nConnection: close\r\n\r\n');
      if (failure != 'stalled body') {
        socket.write(body);
        unawaited(socket.close());
      }
    }, onDone: () {
      if (!closed.isCompleted) {
        closed.complete();
      }
    });
  });
}

Future<void> _expectReadinessFailure(String failure) async {
  final repo = _createRepoWithTests();
  addTearDown(() => repo.deleteSync(recursive: true));
  _stubRepo(repo);
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final proxyPort = server.port;
  final closed = Completer<void>();
  final requests = <String>[];
  final sockets = <Socket>[];
  addTearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });
  await _serveReadinessProxy(server, failure, requests, sockets, closed);
  final watch = Stopwatch()..start();
  final result = await HttpOverrides.runWithHttpOverrides(
    () => LtHyperexecuteRunner(pollDelay: Duration.zero)
        .runIos(target: null, devices: const ['iPhone 17 Pro-26'], idleTimeoutSeconds: 240, env: _iosEnv),
    _ReadinessProxy(proxyPort),
  );
  watch.stop();
  expect(result, ExitCode.unavailable.code);
  verifyNever(() => getDep<LtIosRunner>().buildIosForHyperexecute(
      target: any(named: 'target'),
      targetRegex: any(named: 'targetRegex'),
      sdk: any(named: 'sdk'),
      env: any(named: 'env'),
      reuseLast: any(named: 'reuseLast'),
      shards: any(named: 'shards'),
      selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl')));
  verifyNever(() => getDep<MplatrolShell>().runArgs(any(), any(),
      workingDirectory: any(named: 'workingDirectory'),
      throwOnError: any(named: 'throwOnError'),
      cancelOn: any(named: 'cancelOn')));
  final diagnostic = verify(() => getDep<MplatrolLogger>().err(captureAny())).captured.single as String;
  expect(diagnostic, contains('GET /nope failed on loopback port'));
  expect(diagnostic, contains('No cloud/device connectivity was tested'));
  final port = int.parse(RegExp(r'loopback port (\d+)').firstMatch(diagnostic)![1]!);
  await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1)),
      throwsA(isA<SocketException>()));
  if (failure != 'refused') {
    expect(requests.join(), contains('/nope'));
    expect(requests.join().toLowerCase(), contains('host: localhost.lambdatest.com'));
    expect(requests.join(), isNot(contains('/assign')));
  }
  if (failure == 'stalled body') {
    expect(diagnostic, contains('TimeoutException'));
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    await closed.future.timeout(const Duration(seconds: 1));
  }
}

const _ciLeg = ItRunLeg(tenant: 'acme', environment: 'Staging', variant: 'lt-ios');

List<(String, ItTestOutcome, String?)> _ciResults() => [
      for (final result in getDep<ItRunResults>().resultsOf(_ciLeg))
        (result.description, result.outcome, result.reason),
    ];

const _androidCiLeg = ItRunLeg(tenant: 'globex', environment: 'Staging', variant: 'lt-android');

/// The Android native identities of [repo]'s tests, by description.
Map<String, String> _androidIdentities(Directory repo) => {
      for (final file in discoverPatrolTestFiles(repo.path))
        for (final test in file.tests) test.description: androidLtNativeIdentity(file.basename, test.method),
    };

/// LambdaTest's own record of the Android job's sessions, for build `android-build`.
http.Response? _androidMobileSessions(String url, List<Map<String, Object?>> sessions) {
  if (url.contains('/builds?')) {
    return http.Response(
        jsonEncode({
          'data': [
            {'name': 'android-build', 'build_id': 'b-1'}
          ]
        }),
        200);
  }
  return url.contains('/sessions?build_id=b-1') ? http.Response(jsonEncode({'data': sessions}), 200) : null;
}

Future<int> _runAndroidCiLeg() => getDep<ItRunResults>().withLeg(
    _androidCiLeg,
    () => LtHyperexecuteRunner(pollDelay: Duration.zero)
        .runAndroid(target: null, devices: const ['Pixel 7-13'], idleTimeoutSeconds: 123, env: _androidEnv));

/// The instrumentation of an Android session of [identity] ending with [code] (0 passed, -2 failed) after
/// [body].
String _androidInstrumentation(String identity, int code, {String body = ''}) {
  final [className, method] = identity.split('/');
  return 'INSTRUMENTATION_STATUS: class=$className\nINSTRUMENTATION_STATUS: test=$method\n$body'
      'INSTRUMENTATION_STATUS_CODE: $code\nINSTRUMENTATION_CODE: -1\n';
}

/// A failure that counts as `lt-tunnel-err` (lesson runtimeCredentialsUnreachable).
const _credentialsUnreachable = 'INSTRUMENTATION_STATUS: stack=Could not read runtime E2E credentials from the '
    'runner: TimeoutException after 0:00:30.000000\n';

typedef _AndroidSession = ({String id, String test, bool passed, String log});

typedef _AndroidAttempt = ({int exit, String output, List<_AndroidSession> sessions});

/// Runs the Android CI leg over [_createRepoWithTests] with one HyperExecute job per [attempts] entry (the
/// last repeats), and returns the YAML of every job. Each job's sessions report their own instrumentation.
Future<({int code, List<String> yamls, Map<String, String> ids})> _runAndroidAttempts(
    List<_AndroidAttempt> Function(Map<String, String> identities) attempts,
    {Map<String, String> env = const {}}) async {
  final repo = _createRepoWithTests();
  addTearDown(() => repo.deleteSync(recursive: true));
  _stubRepo(repo);
  when(() => getDep<PlatformWrapper>().environment).thenReturn(env);
  final ids = _androidIdentities(repo);
  final plan = attempts(ids);
  final yamls = <String>[];
  _AndroidAttempt current() => plan[min(yamls.length, plan.length) - 1];
  when(() => getDep<MplatrolShell>().runArgs(any(), any(),
      workingDirectory: any(named: 'workingDirectory'),
      throwOnError: any(named: 'throwOnError'),
      cancelOn: any(named: 'cancelOn'))).thenAnswer((invocation) async {
    _captureNativeVerdictFixturePlatform(invocation);
    final args = invocation.positionalArguments[1] as List<String>;
    yamls.add(File(args[args.indexOf('--config') + 1]).readAsStringSync());
    return ProcessResultX.from(ProcessResult(0, current().exit, current().output, ''));
  });
  _stubLtGet((url) {
    if (url.startsWith('$_providerJobUrl/sessions?')) {
      final sessions = current().sessions;
      return http.Response(
          jsonEncode({
            'data': [
              for (final session in sessions)
                {
                  'sessionID': session.id,
                  'taskID': 'task-current',
                  'scenario_name': session.test,
                  'status': session.passed ? 'passed' : 'failed'
                },
            ],
            'metadata': {'total': sessions.length, 'hasmore': false},
          }),
          200);
    }
    if (url == _providerJobUrl) {
      return http.Response(jsonEncode(_passedJob()), 200);
    }
    for (final session in current().sessions) {
      if (url.contains('/sessions/${session.id}/log/instrumentation')) {
        return http.Response(session.log, 200);
      }
    }
    return http.Response('{}', 200);
  }, includePassedJob: false);
  final code = await getDep<ItRunResults>().withLeg(
      _androidCiLeg,
      () => LtHyperexecuteRunner(pollDelay: Duration.zero, tunnelRetryDelay: Duration.zero)
          .runAndroid(target: null, devices: const ['Pixel 7-13'], idleTimeoutSeconds: 123, env: _androidEnv));
  return (code: code, yamls: yamls, ids: ids);
}

/// The retry filter values of the Android native [identities].
String _retryFilter(List<String> identities) =>
    'values: [${identities.map((identity) => '"${identity.replaceFirst('/', '#')}"').join(', ')}]';

Map<String, ItTestResult> _androidCiResults() =>
    {for (final result in getDep<ItRunResults>().resultsOf(_androidCiLeg)) result.description: result};

_AndroidSession _androidSession(String id, String test, {bool passed = true, String body = ''}) =>
    (id: id, test: test, passed: passed, log: _androidInstrumentation(test, passed ? 0 : -2, body: body));

void _registerInfraRetryTests() {
  group('infrastructure retry', () {
    const failedJob = 'Failed Tasks: 1\n$_jobLink';

    test('Android: a test the tunnel failed reruns alone from the uploaded APKs and only the retry counts', () async {
      final run = await _runAndroidAttempts((ids) => [
            (
              exit: 1,
              output: failedJob,
              sessions: [
                _androidSession('s-first', ids['first test']!, passed: false, body: _credentialsUnreachable),
                _androidSession('s-second', ids['second test']!),
              ]
            ),
            (exit: 0, output: _jobLink, sessions: [_androidSession('s-retry', ids['first test']!)]),
          ]);

      expect(run.code, ExitCode.success.code);
      expect(run.yamls, hasLength(2));
      expect(run.yamls.first, isNot(contains('filters:')));
      final first = run.ids['first test']!;
      expect(run.yamls.last, contains('buildName: "android-build_retry"'));
      expect(
          run.yamls.last,
          contains('    filters:\n      attributes:\n        - type: class\n'
              '          ${_retryFilter([first])}\ntunnel: true\n'));
      expect(run.yamls.last, contains('appId: "lt://APP"'));
      expect(run.yamls.last, contains('concurrency: 1\n'));
      final results = _androidCiResults();
      expect(results['first test']!.outcome, ItTestOutcome.pass);
      expect(results['first test']!.ltSessionId, 's-retry');
      expect(
          results['first test']!.retriedAfter,
          startsWith('retried after lt-tunnel-err (lesson '
              'runtimeCredentialsUnreachable); first attempt FAIL: Could not read runtime E2E credentials'));
      expect(results['first test']!.retriedAfter, endsWith(' [LambdaTest session s-first]'));
      expect(results['first test']!.flaky, isFalse);
      expect(results['second test']!.retriedAfter, isNull);
      expect(File(p.join(_nativeVerdictFixtureRepo!, '.mplatrol', 'retry-hyperexecute-lt-android.yaml')).existsSync(),
          isTrue);
      verify(() => getDep<MplatrolLogger>().info(any(that: startsWith('[retry] $first: retried after lt-tunnel-err'))))
          .called(1);
      verify(() => getDep<MplatrolLogger>().info('[retry] Android Pixel 7-13: retried 1 infra failure(s): 1 passed, '
          '0 still failing.')).called(1);
    });

    test('Android: a real failure beside the retried test still fails the job', () async {
      final run = await _runAndroidAttempts((ids) => [
            (
              exit: 1,
              output: failedJob,
              sessions: [
                _androidSession('s-first', ids['first test']!,
                    passed: false, body: 'INSTRUMENTATION_STATUS: stack=Expected: true Actual: false\n'),
                _androidSession('s-second', ids['second test']!, passed: false, body: _credentialsUnreachable),
              ]
            ),
            (exit: 0, output: _jobLink, sessions: [_androidSession('s-retry', ids['second test']!)]),
          ]);

      expect(run.code, ExitCode.software.code);
      expect(run.yamls.last, contains(_retryFilter([run.ids['second test']!])));
      final results = _androidCiResults();
      expect([results['first test']!.categoryName, results['second test']!.categoryName], ['test-failure', 'pass']);
      expect(results['first test']!.retriedAfter, isNull);
    });

    test('Android: a retry that fails on the infrastructure again is reported and not retried again', () async {
      final run = await _runAndroidAttempts((ids) => [
            (
              exit: 1,
              output: failedJob,
              sessions: [
                _androidSession('s-first', ids['first test']!, passed: false, body: _credentialsUnreachable),
                _androidSession('s-second', ids['second test']!),
              ]
            ),
          ]);

      expect(run.code, ExitCode.software.code);
      expect(run.yamls, hasLength(2));
      final first = _androidCiResults()['first test']!;
      expect([first.outcome, first.categoryName], [ItTestOutcome.fail, 'lt-tunnel-err']);
      expect(first.retriedAfter, startsWith('retried after lt-tunnel-err'));
      verify(() => getDep<MplatrolLogger>().warn('[retry] Android Pixel 7-13: retried 1 infra failure(s): 0 passed, '
          '1 still failing.')).called(1);
    });

    test('Android: a job LambdaTest could not set up reruns every test without a filter', () async {
      final run = await _runAndroidAttempts((_) => [
            (exit: 1, output: _frameworkSetupFailureOutput, sessions: const []),
            (exit: 0, output: _jobLink, sessions: const []),
          ]);

      expect(run.code, ExitCode.unavailable.code);
      expect(run.yamls, hasLength(2));
      expect(run.yamls.last, isNot(contains('filters:')));
      expect(run.yamls.last, contains('buildName: "android-build_retry"'));
      expect(_androidCiResults().values.map((result) => result.retriedAfter),
          everyElement(startsWith('retried after lt-failure')));
    });

    test('Android: a test failure is not retried', () async {
      final run = await _runAndroidAttempts((ids) => [
            (
              exit: 1,
              output: failedJob,
              sessions: [
                _androidSession('s-first', ids['first test']!,
                    passed: false, body: 'INSTRUMENTATION_STATUS: stack=Expected: true Actual: false\n'),
                _androidSession('s-second', ids['second test']!),
              ]
            ),
          ]);

      expect(run.code, ExitCode.software.code);
      expect(run.yamls, hasLength(1));
      verifyNever(() => getDep<MplatrolLogger>().warn(any(that: startsWith('[retry]'))));
    });

    test('Android: $e2eInfraRetryEnv=0 turns the retry off', () async {
      final run = await _runAndroidAttempts(
          (ids) => [
                (
                  exit: 1,
                  output: failedJob,
                  sessions: [
                    _androidSession('s-first', ids['first test']!, passed: false, body: _credentialsUnreachable),
                    _androidSession('s-second', ids['second test']!),
                  ]
                ),
              ],
          env: const {e2eInfraRetryEnv: '0'});

      expect(run.code, ExitCode.software.code);
      expect(run.yamls, hasLength(1));
      expect(_androidCiResults()['first test']!.categoryName, 'lt-tunnel-err');
    });

    test('iOS: infra-failed shards beyond the device limit rerun in waves of the limit', () async {
      final run = await getDep<ItRunResults>().withLeg(
          _ciLeg,
          () => _runIosWaveFixture(
              shardCount: 6, env: const {ltIosMaxParallelEnv: '2'}, waveExit: (job) => job <= 2 ? 1 : 0));

      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1],
        [2, 3],
        [4, 5],
        [0, 1],
        [2, 3],
      ]);
      expect(run.yamls.skip(3), everyElement(contains('buildName: "ios-waves_infra_retry"')));
      expect(_ciResults().map((result) => result.$2), everyElement(ItTestOutcome.pass));
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] infrastructure retry: shard(s) 1, 2, 3, 4 '
          '(LT build "ios-waves_infra_retry")')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 6/6 shards assigned and 6/6 Dart '
          'results verified.')).called(1);
    });

    test('iOS: a retried shard that fails for real fails the device job', () async {
      final run = await getDep<ItRunResults>().withLeg(
          _ciLeg,
          () => _runIosWaveFixture(
              shardCount: 2,
              env: const {ltIosMaxParallelEnv: '1'},
              waveExit: (job) => job == 1 ? 1 : 0,
              failedShards: {0},
              iosLog: (index) => index == 0
                  ? _iosInstrumentationFixture(index).replaceFirst('passed=true', 'passed=false')
                  : _iosInstrumentationFixture(index)));

      expect(run.result, ExitCode.software.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0],
        [1],
        [0],
      ]);
      final results = getDep<ItRunResults>().resultsOf(_ciLeg);
      expect(results.map((result) => result.outcome), [ItTestOutcome.fail, ItTestOutcome.pass]);
      expect(results.first.retriedAfter, startsWith('retried after lt-failure; first attempt NOT RUN'));
    });
  });
}

void _registerCiResultTests() {
  group('CI results', () {
    test('iOS waves: verified passes PASS, a failed shard FAIL', () async {
      await getDep<ItRunResults>().withLeg(_ciLeg, () => _runIosWaveFixture(shardCount: 6, failedShards: {1}));
      expect(_ciResults(), [
        ('case 0', ItTestOutcome.pass, null),
        ('case 1', ItTestOutcome.fail, 'LambdaTest session failed'),
        for (var i = 2; i < 6; i++) ('case $i', ItTestOutcome.pass, null),
      ]);
      final first = getDep<ItRunResults>().resultsOf(_ciLeg).first;
      expect([first.file, first.ltSessionId, first.device], ['patrol_login_test', 'native-0', 'iPhone 17 Pro-26']);
    });

    test('iOS: a stalled wave runs its shards once more and reports only the retry', () async {
      final run = await getDep<ItRunResults>().withLeg(_ciLeg, () => _runIosWaveFixture(shardCount: 6, stallWave: 1));
      expect(run.result, ExitCode.success.code);
      expect(run.yamls.map(_iosYamlWave), [
        [0, 1, 2, 3, 4],
        [5],
        [0, 1, 2, 3, 4],
      ]);
      expect(run.yamls.last, contains('buildName: "ios-waves_infra_retry"'));
      expect(_ciResults(), [for (var i = 0; i < 6; i++) ('case $i', ItTestOutcome.pass, null)]);
      final results = getDep<ItRunResults>().resultsOf(_ciLeg);
      expect(
          results.take(5).map((result) => result.retriedAfter),
          everyElement('retried after lt-failure; first '
              'attempt NOT RUN: infrastructure: the HyperExecute job stalled before this test finished'));
      expect(results.last.retriedAfter, isNull);
      verify(() => getDep<MplatrolLogger>().warn('[retry] iOS iPhone 17 Pro-26: retrying 5 test(s) once after a '
          'LambdaTest infrastructure failure; only the retry is reported.')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[retry] iOS iPhone 17 Pro-26: retried 5 infra failure(s): 5 passed, '
          '0 still failing.')).called(1);
      verify(() => getDep<MplatrolLogger>().info('[ios-waves] verified across waves: 6/6 shards assigned and 6/6 Dart '
          'results verified.')).called(1);
    });

    test('iOS: a stalled wave is not retried when $e2eInfraRetryEnv=0', () async {
      final run = await getDep<ItRunResults>().withLeg(
          _ciLeg,
          () => _runIosWaveFixture(
              shardCount: 6, stallWave: 1, env: const {ltIosMaxParallelEnv: '5', e2eInfraRetryEnv: '0'}));
      expect(run.result, ExitCode.unavailable.code);
      expect(run.yamls, hasLength(2));
      const stalled = 'infrastructure: the HyperExecute job stalled before this test finished';
      expect(_ciResults(), [
        for (var i = 0; i < 5; i++) ('case $i', ItTestOutcome.notRun, stalled),
        ('case 5', ItTestOutcome.pass, null),
      ]);
      expect(getDep<ItRunResults>().resultsOf(_ciLeg).map((result) => result.categoryName),
          [for (var i = 0; i < 5; i++) 'lt-failure', 'pass']);
    });

    test('iOS: SIGTERM stops the running wave, its shards NOT RUN (stopped), and starts no other wave', () async {
      final signals = StreamController<ProcessSignal>();
      addTearDown(signals.close);
      final stopper = ItRunStop(signals: () => [signals.stream], stopChildren: () async {}, exitNow: (_) {})..watch();
      addTearDown(stopper.close);
      GetIt.I.unregister<ItRunStop>();
      GetIt.I.registerSingleton<ItRunStop>(stopper);

      final run = await getDep<ItRunResults>().withLeg(
          _ciLeg, () => _runIosWaveFixture(shardCount: 6, stopWave: 1, stop: () => signals.add(ProcessSignal.sigterm)));

      expect(run.result, 143);
      expect(run.yamls, hasLength(1));
      expect(_ciResults().take(5), [
        for (var i = 0; i < 5; i++) ('case $i', ItTestOutcome.notRun, itRunStoppedReason('SIGTERM')),
      ]);
      verify(() => getDep<MplatrolLogger>().warn('[it-run] lt-ios stopped before ios-waves_wave2 started; '
          'its tests are NOT RUN.')).called(1);
    });

    test('iOS: a shard that never reached the coordinator passes on its retry', () async {
      final run =
          await getDep<ItRunResults>().withLeg(_ciLeg, () => _runIosWaveFixture(shardCount: 6, unreachableShards: {4}));
      expect(run.result, ExitCode.success.code);
      expect(_ciResults().map((result) => result.$2), everyElement(ItTestOutcome.pass));
    });

    test('iOS: a framework setup failure is retried once and, failing again, leaves every shard NOT RUN', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _iosCoordinatorFixtureRequestCount = 0;
      _stubJobResult(1, _frameworkSetupFailureOutput, includeJobLink: false);
      final code = await getDep<ItRunResults>().withLeg(
          _ciLeg,
          () => LtHyperexecuteRunner(pollDelay: Duration.zero, tunnelRetryDelay: Duration.zero).runIos(
              target: null,
              devices: const ['iPhone 17 Pro-26'],
              idleTimeoutSeconds: 240,
              env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-verdict'}));
      expect(code, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolShell>().runArgs(any(), any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'))).called(2);
      expect(
          _ciResults().map((result) => (result.$2, result.$3)),
          everyElement((
            ItTestOutcome.notRun,
            'infrastructure: LambdaTest could not prepare the app for a device, so no test ran'
          )));
      final results = getDep<ItRunResults>().resultsOf(_ciLeg);
      expect(results.map((result) => result.categoryName), everyElement('lt-failure'));
      expect(results.map((result) => result.retriedAfter), everyElement(startsWith('retried after lt-failure')));
      verify(() => getDep<MplatrolLogger>().warn('[retry] iOS iPhone 17 Pro-26: retried 2 infra failure(s): 0 passed, '
          '2 still failing.')).called(1);
    });

    test('Android: a verified job reports each test PASS with its LambdaTest evidence', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, '');
      _stubLtGet((url) =>
          _androidMobileSessions(url, [
            {
              'session_id': 'native-0',
              'status_ind': 'passed',
              'duration': 52,
              'device': 'Pixel 7',
              'version': '13',
              'video_url': 'https://r2/0/video.mp4?verify=SIGNED',
              'device_logs': 'https://api/sessions/native-0/log/devicelog'
            },
          ]) ??
          http.Response('{}', 200));
      expect(await _runAndroidCiLeg(), ExitCode.success.code);
      final results = getDep<ItRunResults>().resultsOf(_androidCiLeg);
      expect(results.map((result) => result.outcome), everyElement(ItTestOutcome.pass));
      final withSession = results.singleWhere((result) => result.duration != null);
      expect([withSession.duration, withSession.device, withSession.os, withSession.videoUrl],
          [const Duration(seconds: 52), 'Pixel 7', 'Android 13', 'https://r2/0/video.mp4?verify=SIGNED']);
      expect(withSession.metadata.singleWhere((entry) => entry.name == 'Video').value, 'https://r2/0/video.mp4');
    });

    test('Android: a failed job reports each session by its own instrumentation', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final identities = _androidIdentities(repo);
      final first = identities['first test']!;
      final second = identities['second test']!;
      _stubJobResult(1, 'Failed Tasks: 1');
      String log(String identity, String status) {
        final [className, method] = identity.split('/');
        return 'INSTRUMENTATION_STATUS: class=$className\nINSTRUMENTATION_STATUS: test=$method\n$status';
      }

      _stubLtGet((url) {
        if (url.startsWith('$_providerJobUrl/sessions?')) {
          return http.Response(
              jsonEncode({
                'data': [
                  {'sessionID': 's-first', 'taskID': 't', 'scenario_name': first, 'status': 'failed'},
                  {'sessionID': 's-second', 'taskID': 't', 'scenario_name': second, 'status': 'passed'},
                  {'sessionID': 's-queued', 'taskID': 't', 'scenario_name': second, 'status': 'queued'},
                ],
                'metadata': {'total': 3, 'hasmore': false},
              }),
              200);
        }
        if (url.contains('/sessions/s-first/log/instrumentation')) {
          return http.Response(
              log(
                  first,
                  'INSTRUMENTATION_STATUS: stack=TimeoutException: STEP login_form: '
                  'ERRPAGE:chrome-error://chromewebdata/ token=${'s3cr3t-pass'}\n'
                  'INSTRUMENTATION_STATUS_CODE: -2\nINSTRUMENTATION_CODE: -1\n'),
              200);
        }
        if (url.contains('/sessions/s-second/log/instrumentation')) {
          return http.Response(
              log(
                  second,
                  'MPLATROL_MOCKED scope=api\nINSTRUMENTATION_STATUS_CODE: 0\n'
                  'INSTRUMENTATION_CODE: -1\n'),
              200);
        }
        return http.Response('{}', 200);
      }, includePassedJob: false);
      expect(
          await getDep<ItRunResults>().withLeg(
              _androidCiLeg,
              () => LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
                  target: null,
                  devices: const ['Pixel 7-13'],
                  idleTimeoutSeconds: 123,
                  env: {..._androidEnv, 'E2E_PASSWORD': 's3cr3t-pass'})),
          ExitCode.software.code);
      final results = {for (final r in getDep<ItRunResults>().resultsOf(_androidCiLeg)) r.description: r};
      expect(results['first test']!.outcome, ItTestOutcome.fail);
      expect(results['first test']!.reason,
          'TimeoutException: STEP login_form: ERRPAGE:chrome-error://chromewebdata/ token=<redacted>');
      expect(results['first test']!.lesson?.name, 'loginErrorPage');
      verify(() => getDep<MplatrolLogger>().err(any(that: startsWith('failure: $first: TimeoutException'))));
      expect(results['second test']!.outcome, ItTestOutcome.mocked);
    });

    test('Android: a failed test keeps the Flutter exception message of its UTF-8 instrumentation log', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final first = _androidIdentities(repo)['first test']!;
      final [className, method] = first.split('/');
      final fixture = File('test/fixtures/lt_scenario_logs/timeout_banner.txt').readAsStringSync();
      final log = 'INSTRUMENTATION_STATUS: class=$className\nINSTRUMENTATION_STATUS: test=$method\n$fixture'
          'INSTRUMENTATION_STATUS_CODE: -2\n';
      _stubJobResult(1, 'Failed Tasks: 1');
      _stubLtGet((url) {
        if (url.startsWith('$_providerJobUrl/sessions?')) {
          return http.Response(
              jsonEncode({
                'data': [
                  {'sessionID': 's-first', 'taskID': 't', 'scenario_name': first, 'status': 'failed'},
                ],
                'metadata': {'total': 1, 'hasmore': false},
              }),
              200);
        }
        if (url.contains('/sessions/s-first/log/instrumentation')) {
          return http.Response.bytes(utf8.encode(log), 200);
        }
        return http.Response('{}', 200);
      }, includePassedJob: false);

      expect(await _runAndroidCiLeg(), ExitCode.software.code);

      const message = 'TimeoutException: STEP account_detail_fields: not reached within 0:00:30.000000;';
      final result = getDep<ItRunResults>().resultsOf(_androidCiLeg).singleWhere((r) => r.description == 'first test');
      expect(result.reason, message);
      verify(() => getDep<MplatrolLogger>().err('failure: $first: $message'));
    });

    test('Android: announces the HyperExecute job live and links every test and the build', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final first = _androidIdentities(repo)['first test']!;
      final cliLog = File(p.join(repo.path, 'hyperexecute-cli.log'));
      when(() => getDep<MplatrolShell>().runArgs(any(), any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'))).thenAnswer((invocation) async {
        cliLog.writeAsStringSync('$_jobLink\n');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return ProcessResultX.from(ProcessResult(0, 1, 'Failed Tasks: 1\n$_jobLink', ''));
      });
      when(() => getDep<LtSessionArtifacts>().session(any(), any())).thenAnswer((_) async => {'build_id': 28547361});
      _stubLtGet((url) {
        if (url.startsWith('$_providerJobUrl/sessions?')) {
          return http.Response(
              jsonEncode({
                'data': [
                  {'sessionID': 's-first', 'taskID': 't', 'scenario_name': first, 'status': 'failed'},
                ],
                'metadata': {'total': 1, 'hasmore': false},
              }),
              200);
        }
        return http.Response('{}', 200);
      }, includePassedJob: false);

      await getDep<ItRunResults>().withLeg(
          _androidCiLeg,
          () => LtHyperexecuteRunner(pollDelay: const Duration(milliseconds: 1))
              .runAndroid(target: null, devices: const ['Pixel 7-13'], idleTimeoutSeconds: 123, env: _androidEnv));

      verify(() => getDep<MplatrolLogger>().info('[lt] Watch it live: '
          'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=$_currentJobId '
          '(HyperExecute job: devices, stages and logs as they run)')).called(1);
      final failed =
          getDep<ItRunResults>().resultsOf(_androidCiLeg).singleWhere((result) => result.ltSessionId != null);
      expect(failed.sessionUrl,
          'https://appautomation.lambdatest.com/test?build=28547361&testID=s-first&selectedTab=logs');
      expect(failed.ltBuildUrl, 'https://appautomation.lambdatest.com/build?jobid=$_currentJobId');
      expect(failed.hyperexecuteJobUrl, 'https://hyperexecute.lambdatest.com/hyperexecute/task?jobId=$_currentJobId');
    });

    test('Android: a build the job lookup cannot read leaves the build out of the test links', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final first = _androidIdentities(repo)['first test']!;
      _stubJobResult(1, 'Failed Tasks: 1');
      when(() => getDep<LtSessionArtifacts>().session(any(), any())).thenThrow(const SocketException('offline'));
      _stubLtGet(
          (url) => url.startsWith('$_providerJobUrl/sessions?')
              ? http.Response(
                  jsonEncode({
                    'data': [
                      {'sessionID': 's-first', 'taskID': 't', 'scenario_name': first, 'status': 'failed'}
                    ],
                    'metadata': {'total': 1, 'hasmore': false},
                  }),
                  200)
              : http.Response('{}', 200),
          includePassedJob: false);

      await _runAndroidCiLeg();

      final failed =
          getDep<ItRunResults>().resultsOf(_androidCiLeg).singleWhere((result) => result.ltSessionId != null);
      expect(failed.sessionUrl, 'https://appautomation.lambdatest.com/test?testID=s-first');
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('could not read the LambdaTest build of the job'))))
          .called(1);
    });

    test('Android: a job with no session has no build to look up', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(1, 'Failed Tasks: 1');
      _stubLtGet(
          (url) => url.startsWith('$_providerJobUrl/sessions?')
              ? http.Response(
                  jsonEncode({
                    'data': [],
                    'metadata': {'total': 0, 'hasmore': false}
                  }),
                  200)
              : http.Response('{}', 200),
          includePassedJob: false);

      await _runAndroidCiLeg();

      verifyNever(() => getDep<LtSessionArtifacts>().session(any(), any()));
    });

    test('Android: a failed job of more than 20 sessions reads every provider page', () async {
      // Round-5 globex lt-android (job 71c2072a): 21 sessions, 2 failed tasks. HyperExecute's
      // `total` counts each page (20 with hasmore, then 1), not the job.
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final identities = _androidIdentities(repo);
      final first = identities['first test']!;
      final second = identities['second test']!;
      _stubJobResult(
          1,
          'x [5]  $first (1m33s)\n    Pass test stage percentage:           90.48%\n'
          '    Failed Tasks:                         2\nError: Failed tasks found.');
      String log(String identity, String code) {
        final [className, method] = identity.split('/');
        return 'INSTRUMENTATION_STATUS: class=$className\nINSTRUMENTATION_STATUS: test=$method\n'
            'INSTRUMENTATION_STATUS_CODE: $code\nINSTRUMENTATION_CODE: -1\n';
      }

      const cursor = 'RMAA-AND-1913856-1791030296363442180NJG';
      final urls = <String>[];
      _stubLtGet((url) {
        if (url.startsWith('$_providerJobUrl/sessions?')) {
          urls.add(url);
          final last = url.contains('&cursor=');
          return http.Response(
              jsonEncode({
                'data': last
                    ? [
                        {'sessionID': cursor, 'taskID': 't', 'scenario_name': second, 'status': 'passed'}
                      ]
                    : [
                        {'sessionID': 'RMAA-AND-first', 'taskID': 't', 'scenario_name': first, 'status': 'failed'},
                        for (var i = 0; i < 19; i++)
                          {
                            'sessionID': 'RMAA-AND-queued-$i',
                            'taskID': 't',
                            'scenario_name': second,
                            'status': 'queued'
                          },
                      ],
                'metadata': last
                    ? {'total': 1, 'cursor': '', 'hasmore': false}
                    : {'total': 20, 'cursor': cursor, 'hasmore': true},
              }),
              200);
        }
        if (url.contains('/sessions/RMAA-AND-first/log/instrumentation')) {
          return http.Response(log(first, '-2'), 200);
        }
        if (url.contains('/sessions/$cursor/log/instrumentation')) {
          return http.Response(log(second, '0'), 200);
        }
        return http.Response('{}', 200);
      }, includePassedJob: false);
      expect(await _runAndroidCiLeg(), ExitCode.software.code);
      expect(urls, ['$_providerJobUrl/sessions?limit=20', '$_providerJobUrl/sessions?limit=20&cursor=$cursor']);
      final results = {for (final r in getDep<ItRunResults>().resultsOf(_androidCiLeg)) r.description: r.outcome};
      expect([results['first test'], results['second test']], [ItTestOutcome.fail, ItTestOutcome.pass]);
      verifyNever(
          () => getDep<MplatrolLogger>().warn(any(that: startsWith('[ci-report] could not read the sessions'))));
    });

    test('Android: an unreadable job leaves its tests without verdicts and warns', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(1, 'Failed Tasks: 1');
      _stubLtGet((url) => http.Response('{}', url.startsWith(_providerJobUrl) ? 500 : 200), includePassedJob: false);
      await _runAndroidCiLeg();
      expect(getDep<ItRunResults>().resultsOf(_androidCiLeg).map((result) => result.outcome),
          everyElement(ItTestOutcome.notRun));
      verify(() => getDep<MplatrolLogger>().warn(any(that: startsWith('[ci-report] could not read the sessions'))))
          .called(1);
    });

    test('Android: instrumentation the provider never published records no verdict', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final first = _androidIdentities(repo)['first test']!;
      _stubJobResult(1, 'Failed Tasks: 1');
      _stubLtGet((url) {
        if (url.startsWith('$_providerJobUrl/sessions?')) {
          return http.Response(
              jsonEncode({
                'data': [
                  {'sessionID': 's-first', 'taskID': 't', 'scenario_name': first, 'status': 'failed'},
                ],
                'metadata': {'total': 1, 'hasmore': false},
              }),
              200);
        }
        return http.Response('{}', url.contains('/log/instrumentation') ? 404 : 200);
      }, includePassedJob: false);
      await _runAndroidCiLeg();
      final result = getDep<ItRunResults>().resultsOf(_androidCiLeg).singleWhere((r) => r.description == 'first test');
      expect((result.outcome, result.reason), (ItTestOutcome.fail, 'LambdaTest session failed'));
    });
  });
}

void _registerLocalReadinessTests() {
  group('local coordinator readiness', () {
    for (final failure in ['refused', 'status', 'body', 'stalled body']) {
      test('fails before build and closes listener for $failure', () => _expectReadinessFailure(failure));
    }
  });
}

void main() {
  setUp(() async {
    await scaffoldMockDependencies();
    _nativeVerdictFixtureAndroid = false;
    _nativeVerdictFixtureRepo = null;
    _iosCoordinatorFixtureUrl = null;
    _iosCoordinatorFixtureSelected = [];
    _iosCoordinatorFixtureDescriptions = [];
    _iosFixtureBuildName = 'ios-verdict';
    _iosCoordinatorFixtureAssigned = [];
    _iosCoordinatorFixtureRequestCount = null;
    _iosCoordinatorFixtureRepeatSession = false;
    _iosCoordinatorFixtureSessionPrefix = 'fixture';
    when(() => getDep<MplatrolShell>().whichSync('hyperexecute')).thenReturn('hyperexecute');
    _stubLtGet((_) => http.Response('{}', 200));
    when(() => getDep<MplatrolShell>().runArgs(
          any(that: endsWith('hyperexecute')),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        )).thenAnswer((invocation) async {
      _captureNativeVerdictFixturePlatform(invocation);
      await _requestIosFixtureAssignments();
      return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
    });
  });
  _registerHyperexecuteVerdictTests();
  _registerLocalReadinessTests();
  _registerNativeAssumptionSkipRegression();
  _registerProviderCompletionGuardTests();
  _registerArtifactBoundSelectionTests();
  _registerInvalidArtifactPlanTests();
  _registerIosSelectionRefusalTests();
  _registerHyperexecuteEvidenceTests();
  _registerHyperexecuteNativeEvidenceTests();
  _registerObservedProviderTests();
  _registerProviderPaginationTests();
  _registerIosAssignmentCoverageTests();
  _registerIosInstrumentationTests();
  _registerIosWaveTests();
  _registerCiResultTests();
  _registerInfraRetryTests();

  group('LtHyperexecuteRunner.runAndroid', () {
    test('stops a stalled job and reports its task group as NOT RUN infrastructure', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final cliLog = File(p.join(repo.path, 'hyperexecute-cli.log'))
        ..writeAsStringSync('Build Link: https://appautomation.lambdatest.com/build?jobid=$_otherJobId\n');
      when(() => getDep<MplatrolShell>().runArgs(
            any(that: endsWith('hyperexecute')),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: any(named: 'throwOnError'),
            cancelOn: any(named: 'cancelOn'),
          )).thenAnswer((invocation) async {
        cliLog.writeAsStringSync('$_jobLink\n', mode: FileMode.append);
        await (invocation.namedArguments[#cancelOn] as Future<void>);
        return ProcessResultX.from(ProcessResult(0, ExitCode.tempFail.code, '', 'Stopped by caller'));
      });
      final finished = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
      _stubLtGet(
        (url) => url == _providerJobUrl
            ? http.Response(
                jsonEncode({
                  'data': {
                    'status': 'running',
                    'tasks': [
                      {'groupNumber': 1, 'status': 'passed', 'endTime': finished.toIso8601String()},
                      {'groupNumber': 2, 'status': 'running', 'startTime': finished.toIso8601String(), 'endTime': null},
                    ],
                  },
                }),
                200)
            : http.Response('{}', 404),
        includePassedJob: false,
      );

      final result = await LtHyperexecuteRunner(
        stallWatchdog: HyperexecuteStallWatchdog(pollEvery: const Duration(milliseconds: 1)),
      ).runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );

      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().err(any(
          that: allOf(contains('[hyperexecute-watchdog] HyperExecute job $_currentJobId task group(s) #2'),
              contains('NOT RUN (infrastructure)'))))).called(1);
      verifyNever(() => getDep<MplatrolLogger>().success(any()));
    });

    // Regression: hooli 2026-10-02 lt-android never ran — LambdaTest's app
    // patching never became network_ready — and was reported as exit 70 with
    // only "Could not find LambdaTest Android build".
    test('a framework setup failure is NOT VERIFIED with its HyperExecute error', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(1, _frameworkSetupFailureOutput, includeJobLink: false);

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      expect(
          _loggedErrors(),
          contains(allOf(startsWith('HyperExecute Android job NOT VERIFIED (infrastructure): '),
              contains('error    app update failed - Error setting up framework.'), contains('no test ran'))));
      verify(() =>
              getDep<MplatrolLogger>().info(any(that: startsWith('lesson lambdaTestFrameworkSetup (observed 1): '))))
          .called(1);
      verifyNever(() => getDep<MplatrolLogger>().err('HyperExecute Android E2E failed (exit 1).'));
      verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('for diagnostics'))));
    });

    test('runs one device session per selected test', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final slots = Directory.systemTemp.createTempSync('mplatrol_lt_slots');
      addTearDown(() => slots.deleteSync(recursive: true));

      final result = await LtHyperexecuteRunner(
        slotBudget: LtSlotBudget(directory: slots.path, limit: 30, logger: getDep<MplatrolLogger>()),
      ).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );

      expect(result, ExitCode.success.code);
      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('concurrency: 2\n'));
      verify(() => getDep<MplatrolLogger>().info('[lt-sessions] Android android-build: 2 device session(s) for '
          '2 selected test(s)')).called(1);
      expect(File(p.join(slots.path, 'usage.log')).readAsLinesSync().map((line) => line.split(' ').skip(1).join(' ')),
          ['grant 2 android-build inUse=2/30', 'release 2 android-build inUse=0/30']);
    });

    test('runs the Android tests on its share while the iOS leg of its users builds', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final home = Directory.systemTemp.createTempSync('mplatrol_lt_user_cap');
      addTearDown(() => home.deleteSync(recursive: true));
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': home.path, ltSessionsPerUserEnv: '2'});
      final userDir = p.join(home.path, '.mplatrol', 'lt-user-slots', 'user-a');
      final ios = LtUserSessionCap(directory: userDir, users: 1, perUser: 2, logger: getDep<MplatrolLogger>())
          .join('demo:lt-ios');
      addTearDown(ios.leave);

      final result = await LtHyperexecuteRunner(
        slotBudget: LtSlotBudget(directory: p.join(home.path, 'lt-slots'), limit: 30, logger: getDep<MplatrolLogger>()),
      ).runAndroid(
          target: null,
          devices: const ['Pixel 8-14'],
          idleTimeoutSeconds: 123,
          env: const {
            ..._androidEnv,
            'HYPEREXECUTE_BIN': '/tmp/hyperexecute',
            e2eUserKeysEnv: 'user-a',
          });

      expect(result, ExitCode.success.code);
      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('concurrency: 1\n'));
      verify(() => getDep<MplatrolLogger>().info('[lt-user-cap] android-build: 1 of 2 device session(s), share 1 of '
              'the test user cap of 2 (2 live LT leg(s) of this user; 2 per verified user x 1 verified user(s))'))
          .called(1);
      verify(() => getDep<MplatrolLogger>().info('[lt-sessions] Android android-build: 1 device session(s) for '
          '2 selected test(s)')).called(1);
      expect(File(p.join(userDir, 'usage.log')).readAsStringSync(), contains('release 1 android-build inUse=0/2'));
      expect(Directory(userDir).listSync().where((file) => file.path.endsWith('.leg')).map((file) => file.path),
          ['${p.join(userDir, ios.owner)}.leg'],
          reason: 'the Android leg left; the iOS leg is still present');
    });

    test('caps the Android sessions at the configured limit', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(() => getDep<PlatformWrapper>().environment).thenReturn({ltAndroidMaxParallelEnv: '1'});

      await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );

      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('concurrency: 1\n'));
    });

    for (final env in [
      {ltAndroidMaxParallelEnv: '0'},
      {ltMaxConcurrentSessionsEnv: 'x', 'HOME': '/tmp'},
    ]) {
      test('refuses a misconfigured Android session limit $env before building', () async {
        when(() => getDep<PlatformWrapper>().environment).thenReturn(env);

        final result = await LtHyperexecuteRunner().runAndroid(
          target: null,
          devices: const ['Pixel 8-14'],
          idleTimeoutSeconds: 123,
          env: _androidEnv,
        );

        expect(result, ExitCode.usage.code);
        expect(_loggedErrors().single, contains('must be a positive whole number'));
        verifyNever(() => getDep<LtAndroidRunner>().buildUploadAndroid(
            repo: any(named: 'repo'),
            tenant: any(named: 'tenant'),
            target: any(named: 'target'),
            buildName: any(named: 'buildName'),
            auth: any(named: 'auth'),
            env: any(named: 'env'),
            reuseLast: any(named: 'reuseLast')));
      });
    }

    test('a released leg runs its job outside the checkout', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final leg = Directory.systemTemp.createTempSync('mplatrol_leg');
      addTearDown(() => leg.deleteSync(recursive: true));
      when(() => getDep<PlatformWrapper>().environment).thenReturn({itLegDirEnv: leg.path});
      when(() => getDep<MplatrolShell>().runArgs('git', ['rev-parse', '--short=12', 'HEAD'],
          workingDirectory: repo.path,
          throwOnError: false,
          silent: true)).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 0, 'abc\n', '')));
      getDep<ItLegDir>().expectedUploads = 1;

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );

      expect(result, ExitCode.success.code);
      final jobRoot = p.join(leg.path, 'hyperexecute', 'android');
      expect(File(p.join(jobRoot, '.mplatrol', 'hyperexecute-lt-android.yaml')).existsSync(), isTrue);
      expect(File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).existsSync(), isFalse);
      expect(File(p.join(leg.path, itCheckoutReleasedMarker)).existsSync(), isTrue);
      verify(() => getDep<MplatrolShell>().runArgs('/tmp/hyperexecute', any(),
          workingDirectory: jobRoot, throwOnError: false, cancelOn: any(named: 'cancelOn'))).called(1);
    });

    test('lists every device of a pool so HyperExecute takes any free one', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      await LtHyperexecuteRunner().runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Pixel 9-16|Galaxy S24-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );

      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('deviceSelectionStrategy: any'));
      expect(yaml, contains('devices: ["Pixel 9-16", "Galaxy S24-14"]'));
    });

    test('writes Android YAML and runs HyperExecute with explicit binary', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      final result = await LtHyperexecuteRunner().runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
        tenantLabel: 'acme',
        environmentLabel: 'Dev',
      );

      expect(result, ExitCode.success.code);
      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('runson: android'));
      expect(yaml, contains('buildName: "android-build"'));
      expect(yaml, contains('appId: "lt://APP"'));
      expect(yaml, contains('testSuiteAppId: "lt://TEST"'));
      expect(yaml, contains('idleTimeout: 123'));
      expect(yaml, contains('devices: ["Pixel 8-14"]'));
      // HyperExecute owns the tunnel because externally-started tunnels handed
      // over via tunnelNames hit ERR::TUN::RESP. The mobile session still needs
      // its tunnel capability so Android traffic binds to that HE tunnel.
      expect(yaml, contains('tunnel: true'));
      expect(yaml, contains('localhost: true'));
      expect(yaml, contains('mitmProxy: true'));
      expect(yaml, contains('jobLabel: ["acme", "Dev", "Espresso", "mplatrol-it"]'));
      expect(yaml, isNot(contains('"HyperExecute"')));
      expect(yaml, isNot(contains('tunnelName:')));
      expect(yaml, isNot(contains('tunnelNames:')));
      verify(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: repo.path,
          target: 'patrol_test/patrol_login_test.dart',
          buildName: 'android-build',
          auth: 'user:key',
          env: any(named: 'env'),
          reuseLast: false,
          tenant: 'acme',
        ),
      ).called(1);
      verify(
        () => getDep<MplatrolShell>().runArgs(
          '/tmp/hyperexecute',
          [
            '--user',
            'user',
            '--key',
            'key',
            '--config',
            p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml'),
            '--download-logs',
            '--download-report',
          ],
          workingDirectory: repo.path,
          throwOnError: false,
          cancelOn: any(named: 'cancelOn'),
        ),
      ).called(1);
    });

    test('runs one Android HyperExecute job per device from one upload', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final yamls = <String>[];
      final workDirs = <String>[];
      final executables = <String>{};
      final release = Completer<void>();
      when(() => getDep<MplatrolShell>().runArgs(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: any(named: 'throwOnError'),
            cancelOn: any(named: 'cancelOn'),
          )).thenAnswer((invocation) async {
        final args = invocation.positionalArguments[1] as List<String>;
        yamls.add(File(args[args.indexOf('--config') + 1]).readAsStringSync());
        workDirs.add(invocation.namedArguments[#workingDirectory] as String);
        executables.add(invocation.positionalArguments.first as String);
        _captureNativeVerdictFixturePlatform(invocation);
        // Both device jobs must be running before either may finish.
        if (yamls.length == 2) {
          release.complete();
        }
        await release.future;
        return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
      });

      final result = await LtHyperexecuteRunner(deviceJobSpacing: Duration.zero).runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Galaxy S23-13', 'Pixel 6-12'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );

      expect(result, ExitCode.success.code);
      expect(yamls, hasLength(2));
      expect(yamls[0], contains('devices: ["Galaxy S23-13"]'));
      expect(yamls[0], contains('buildName: "android-build-Galaxy_S23_13"'));
      expect(yamls[1], contains('devices: ["Pixel 6-12"]'));
      expect(yamls[1], contains('buildName: "android-build-Pixel_6_12"'));
      expect(workDirs, [
        p.join(repo.path, '.mplatrol', 'he-jobs', 'Android-Galaxy_S23_13'),
        p.join(repo.path, '.mplatrol', 'he-jobs', 'Android-Pixel_6_12'),
      ]);
      expect(executables, {'/tmp/hyperexecute'});
      expect(File(p.join(workDirs.first, 'hyperexecute-lt-android.yaml')).existsSync(), isTrue);
      verify(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: repo.path,
          target: 'patrol_test/patrol_login_test.dart',
          buildName: 'android-build',
          auth: 'user:key',
          env: any(named: 'env'),
          reuseLast: false,
        ),
      ).called(1);
      verify(() => getDep<MplatrolLogger>().info('[device-matrix] Android verdicts per device:')).called(1);
    });

    test('returns usage before any build when Android devices are empty', () async {
      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const [],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.usage.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('No LambdaTest Android devices supplied.'))))
          .called(1);
      verifyNever(() => getDep<LtAndroidRunner>().buildUploadAndroid(
            repo: any(named: 'repo'),
            tenant: any(named: 'tenant'),
            target: any(named: 'target'),
            buildName: any(named: 'buildName'),
            auth: any(named: 'auth'),
            env: any(named: 'env'),
            reuseLast: any(named: 'reuseLast'),
          ));
    });

    test('defaults to no retries; enables them when MPLATROL_E2E_MAX_RETRIES is set', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      // Default (env has no MPLATROL_E2E_MAX_RETRIES) -> no task retries.
      await LtHyperexecuteRunner().runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );
      var yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('maxRetries: 0'));
      expect(yaml, contains('retryOnFailure: false'));

      // Set to 2 -> retries on.
      when(() => getDep<PlatformWrapper>().environment).thenReturn({e2eMaxRetriesEnv: '2'});
      await LtHyperexecuteRunner().runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );
      yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('maxRetries: 2'));
      expect(yaml, contains('retryOnFailure: true'));

      // Negative is clamped to 0.
      when(() => getDep<PlatformWrapper>().environment).thenReturn({e2eMaxRetriesEnv: '-3'});
      await LtHyperexecuteRunner().runAndroid(
        target: 'patrol_test/patrol_login_test.dart',
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );
      yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
      expect(yaml, contains('maxRetries: 0'));
    });

    for (final retries in [null, '2']) {
      test('Android failure remains a failure with retry opt-in $retries', () async {
        final repo = _createRepoWithTests();
        addTearDown(() => repo.deleteSync(recursive: true));
        _stubRepo(repo);
        when(() => getDep<PlatformWrapper>().environment).thenReturn({
          if (retries != null) e2eMaxRetriesEnv: retries,
        });
        _stubJobResult(1, 'Failed Tasks: 1');

        final result = await LtHyperexecuteRunner().runAndroid(
          target: 'patrol_test/patrol_login_test.dart',
          devices: const ['Pixel 8-14'],
          idleTimeoutSeconds: 123,
          env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
        );

        expect(result, ExitCode.software.code);
        final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
        expect(yaml, contains('maxRetries: ${retries ?? '0'}'));
        expect(yaml, contains('retryOnFailure: ${retries != null}'));
        verify(() => getDep<MplatrolShell>().runArgs(
              '/tmp/hyperexecute',
              any(),
              workingDirectory: repo.path,
              throwOnError: false,
              cancelOn: any(named: 'cancelOn'),
            )).called(1);
      });
    }

    test('uses cached home HyperExecute binary when PATH has none', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final home = Directory.systemTemp.createTempSync('hyperexecute_home');
      addTearDown(() {
        if (home.existsSync()) {
          home.deleteSync(recursive: true);
        }
      });
      final cached = File(p.join(home.path, '.hyperexecute', 'hyperexecute'))
        ..createSync(recursive: true)
        ..writeAsStringSync('cached binary');
      when(() => getDep<MplatrolShell>().whichSync('hyperexecute')).thenReturn(null);
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': home.path});

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.success.code);
      verify(
        () => getDep<MplatrolShell>().runArgs(
          cached.path,
          [
            '--user',
            'user',
            '--key',
            'key',
            '--config',
            p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml'),
            '--download-logs',
            '--download-report',
          ],
          workingDirectory: repo.path,
          throwOnError: false,
          cancelOn: any(named: 'cancelOn'),
        ),
      ).called(1);
    });

    test('adds a run suffix to the git sha fallback Android build name', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final env = Map<String, String>.of(_androidEnv)..remove('LT_BUILD_NAME');

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: env,
      );

      expect(result, ExitCode.success.code);
      final buildNames = verify(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: repo.path,
          target: null,
          buildName: captureAny(named: 'buildName'),
          auth: 'user:key',
          env: any(named: 'env'),
          reuseLast: false,
        ),
      ).captured;
      expect(buildNames.single, matches(RegExp(r'^LoginE2EAndroid-outText-\d{8}T\d{6}Z$')));
    });

    test('returns config when Android environment values are missing', () async {
      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {'LT_USERNAME': 'user'},
      );

      expect(result, ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('Missing required environment values')))).called(1);
    });

    test('does not require package-manager secrets for Android HyperExecute', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {
          'LT_USERNAME': 'user',
          'LT_ACCESS_KEY': 'key',
          'LT_BIN': '/Users/test/Downloads/LT',
          'LT_BUILD_NAME': 'android-build',
        },
      );

      expect(result, ExitCode.success.code);
      verify(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: repo.path,
          target: null,
          buildName: 'android-build',
          auth: 'user:key',
          env: any(named: 'env'),
          reuseLast: false,
        ),
      ).called(1);
    });

    test('maps missing Android build/upload artifacts to software failure', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: any(named: 'repo'),
          tenant: any(named: 'tenant'),
          target: any(named: 'target'),
          buildName: any(named: 'buildName'),
          auth: any(named: 'auth'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
        ),
      ).thenAnswer((_) async => null);

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.software.code);
    });

    test('seeds the CLI tunnel binary from LT_BIN before the job', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final cached = File(p.join(repo.path, 'cached-LT'))..writeAsStringSync('full tunnel binary');
      // A timed-out CLI download leaves a truncated <repo>/LT behind; it must
      // be replaced, not trusted.
      File(p.join(repo.path, 'LT')).writeAsStringSync('trunc');

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: {..._androidEnv, 'LT_BIN': cached.path},
      );

      expect(result, ExitCode.success.code);
      expect(File(p.join(repo.path, 'LT')).readAsStringSync(), 'full tunnel binary');
    });

    // Regression: the CLI rewrites <repo>/LT in place before every job, and
    // macOS SIGKILLs a signed binary rewritten in place after it ran, so a
    // later wave failed with "Tunnel ... errored: signal: killed".
    test('gives every job a fresh LT file instead of trusting a same-size one', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final cached = File(p.join(repo.path, 'cached-LT'))..writeAsStringSync('full tunnel binary');
      final previous = File(p.join(repo.path, 'previous-LT'))..writeAsStringSync('ran in an old job');
      final hardLink = await Process.run('ln', [previous.path, p.join(repo.path, 'LT')]);
      expect(hardLink.exitCode, 0);

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: {..._androidEnv, 'LT_BIN': cached.path},
      );

      expect(result, ExitCode.success.code);
      expect(File(p.join(repo.path, 'LT')).readAsStringSync(), 'full tunnel binary');
      // Not written through the old inode: its other name keeps the old bytes.
      expect(previous.readAsStringSync(), 'ran in an old job');
    });

    test('removes a stale LT file when the cached tunnel binary is missing', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final stale = File(p.join(repo.path, 'LT'))..writeAsStringSync('ran in an old job');

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.success.code);
      expect(stale.existsSync(), isFalse);
    });

    // Regression: r12 legs started from Terminal could not read ~/Downloads/LT, and the copy error aborted
    // every job before its results were read.
    test('an unreadable tunnel binary only warns; the job runs and its results are read', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final unreadable = File(p.join(repo.path, 'unreadable-LT'))..writeAsStringSync('tunnel');
      Process.runSync('chmod', ['000', unreadable.path]);
      addTearDown(() => Process.runSync('chmod', ['644', unreadable.path]));

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: {..._androidEnv, 'LT_BIN': unreadable.path},
      );

      expect(result, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().warn(any(
          that: allOf(startsWith('[hyperexecute] could not seed the tunnel binary from ${unreadable.path}'),
              endsWith('the HyperExecute CLI downloads its own.'))))).called(1);
      verify(() => getDep<MplatrolLogger>().success('HyperExecute Android E2E passed.')).called(1);
    });

    test('an unreadable scenario log only warns; the job results are still read', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final log = File(p.join(repo.path, 'logs', _currentJobId, 'scenarios', 'scenario.log'))
        ..createSync(recursive: true)
        ..writeAsStringSync('log');
      Process.runSync('chmod', ['000', log.path]);
      addTearDown(() => Process.runSync('chmod', ['644', log.path]));

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().warn(any(
          that: allOf(startsWith('[leg-artifacts] warn: could not keep the scenario logs of job $_currentJobId'),
              contains('scenario.log'))))).called(1);
    });

    test('keeps the tunnel binary the CLI downloaded as mplatrol copy for later jobs', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final home = Directory.systemTemp.createTempSync('lt-home');
      addTearDown(() => home.deleteSync(recursive: true));
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': home.path});
      final kept = ltTunnelBinaryPath(home.path);
      when(() => getDep<MplatrolShell>().runArgs(any(), any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'))).thenAnswer((invocation) async {
        File(p.join(repo.path, 'LT')).writeAsStringSync('downloaded tunnel');
        return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
      });

      await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: {..._androidEnv, 'LT_BIN': kept},
      );

      expect(File(kept).readAsStringSync(), 'downloaded tunnel');
      verify(() => getDep<MplatrolLogger>().info('[hyperexecute] kept the tunnel binary the CLI downloaded -> $kept'))
          .called(1);
    });

    test('a tunnel binary that cannot be kept only warns', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final home = Directory.systemTemp.createTempSync('lt-home');
      addTearDown(() => home.deleteSync(recursive: true));
      when(() => getDep<PlatformWrapper>().environment).thenReturn({'HOME': home.path});
      final kept = ltTunnelBinaryPath(home.path);
      File(p.dirname(kept))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('a file where the directory belongs');
      when(() => getDep<MplatrolShell>().runArgs(any(), any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'))).thenAnswer((invocation) async {
        File(p.join(repo.path, 'LT')).writeAsStringSync('downloaded tunnel');
        return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
      });

      await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: {..._androidEnv, 'LT_BIN': kept},
      );

      verifyNever(() => getDep<MplatrolLogger>().err(any(that: startsWith('HyperExecute Android E2E failed: '))));
      verify(() => getDep<MplatrolLogger>()
          .warn(any(that: startsWith('[hyperexecute] could not keep the tunnel binary at $kept')))).called(1);
    });

    test('returns software when HyperExecute exits non-zero', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 1, 'Build Link: https://example.test', '')));

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.software.code);
    });

    test('keeps HyperExecute status on a spinner and dedupes summary lines', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenAnswer(
        (_) async => ProcessResultX.from(
          ProcessResult(
              0,
              1,
              '''
Build Link: https://example.test
Build Link: https://example.test
⠸ 5/4 stages completed  [1s] taskId:HYPL-1 has failed with remark: failed
taskId:HYPL-1 has failed with remark: failed
ERR::TUN::RESP no running tunnels found
Failed Tasks: 1
Failed Tasks: 1
''',
              ''),
        ),
      );

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().progress('Running HyperExecute Android job')).called(1);
      verify(() => getDep<MplatrolLogger>().info('Build Link: https://example.test')).called(1);
      verify(() => getDep<MplatrolLogger>().info('Failed Tasks: 1')).called(1);
      verify(() => getDep<MplatrolLogger>().info('ERR::TUN::RESP no running tunnels found')).called(1);
      verifyNever(() => getDep<MplatrolLogger>().info(any(that: contains('taskId:HYPL-1'))));
      verifyNever(() => getDep<MplatrolLogger>().info(any(that: contains('stages completed'))));
    });

    test('reports LambdaTest diagnostics for HyperExecute Android failures', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 1, 'Build Link: https://example.test', '')));
      when(
        () => getDep<LtHttp>().get(
          any(that: contains('/builds?')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'data': [
              {'name': 'other-build', 'build_id': 'ignored'},
              {'name': 'android-build', 'build_id': 'build-android-1'},
            ],
          }),
          200,
        ),
      );

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.software.code);
      verify(
        () => getDep<LtDiagnostics>().report(buildId: 'build-android-1', platform: 'Android', env: _androidEnv),
      ).called(1);
    });

    test('finds HyperExecute Android diagnostics from sessions by build name', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenAnswer((_) async => ProcessResultX.from(ProcessResult(0, 1, 'Build Link: https://example.test', '')));
      when(
        () => getDep<LtHttp>().get(
          any(),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).thenAnswer((invocation) async {
        final url = invocation.positionalArguments.single as String;
        if (url.contains('/builds?')) {
          return http.Response(jsonEncode({'data': []}), 200);
        }
        if (url.contains('/sessions?') && url.contains('build=android-build')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'build_name': 'android-build', 'build_id': 22472485},
              ],
            }),
            200,
          );
        }
        return http.Response('{"data":[]}', 200);
      });

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.software.code);
      verify(
        () => getDep<LtDiagnostics>().report(buildId: '22472485', platform: 'Android', env: _androidEnv),
      ).called(1);
    });

    test('returns software when HyperExecute throws', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenThrow(Exception('process failed'));

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.software.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('HyperExecute Android E2E failed')))).called(1);
    });
  });

  group('LtHyperexecuteRunner.runIos', () {
    test('a framework setup failure is NOT VERIFIED and its shards NOT RUN', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _iosCoordinatorFixtureRequestCount = 0;
      _stubJobResult(1, _frameworkSetupFailureOutput, includeJobLink: false);

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-verdict'},
      );

      expect(result, ExitCode.unavailable.code);
      final errors = _loggedErrors();
      expect(errors, contains(startsWith('HyperExecute iOS job NOT VERIFIED (infrastructure): ')));
      expect(errors.where((e) => e.startsWith('[ios-shard-coordinator] NOT RUN')), hasLength(2));
      verifyNever(() => getDep<MplatrolLogger>().err('HyperExecute iOS E2E failed (exit 1).'));
    });

    test('returns config when iOS environment values are missing', () async {
      final result = await LtHyperexecuteRunner().runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {'LT_USERNAME': 'user'},
      );

      expect(result, ExitCode.config.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('Missing required environment values')))).called(1);
    });

    test('returns usage when iOS devices are empty', () async {
      final result = await LtHyperexecuteRunner().runIos(
        target: null,
        devices: const [],
        idleTimeoutSeconds: 240,
        env: const {'LT_USERNAME': 'user', 'LT_ACCESS_KEY': 'key', 'LT_BIN': '/Users/test/Downloads/LT'},
      );

      expect(result, ExitCode.usage.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('No LambdaTest iOS devices supplied.')))).called(1);
    });

    test('refuses a multi-device run with an external iOS coordinator', () async {
      final result = await LtHyperexecuteRunner().runIos(
        target: null,
        devices: const ['iPhone 8-16', 'iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {
          ..._iosEnv,
          'MPLATROL_IOS_SHARD_COORDINATOR_URL': 'http://coordinator.test/assign',
        },
      );

      expect(result, ExitCode.usage.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('cannot serve 2 LambdaTest iOS devices'))))
          .called(1);
    });

    test('reassigns every shard for each iOS device job from one build', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final yamls = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;
      when(() => getDep<MplatrolShell>().runArgs(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
            throwOnError: any(named: 'throwOnError'),
            cancelOn: any(named: 'cancelOn'),
          )).thenAnswer((invocation) async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await pumpEventQueue();
        final args = invocation.positionalArguments[1] as List<String>;
        yamls.add(File(args[args.indexOf('--config') + 1]).readAsStringSync());
        _captureNativeVerdictFixturePlatform(invocation);
        final port = Uri.parse(_iosCoordinatorFixtureUrl!).port;
        final client = HttpClient();
        try {
          for (var index = 0; index < _iosCoordinatorFixtureSelected.length; index++) {
            final request = await client.getUrl(Uri(
                scheme: 'http',
                host: '127.0.0.1',
                port: port,
                path: '/assign',
                queryParameters: {'xctestSession': 'job${yamls.length}-$index'}));
            final response = await request.close();
            await response.drain<void>();
            expect(response.statusCode, HttpStatus.ok);
          }
        } finally {
          client.close();
        }
        inFlight--;
        return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
      });

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 8-16', 'iPad 10.9 (2022)-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-matrix'},
      );

      expect(result, ExitCode.success.code);
      expect(yamls, hasLength(2));
      expect(yamls[0], contains('devices: ["iPhone 8-16"]'));
      expect(yamls[0], contains('buildName: "ios-matrix-iPhone_8_16"'));
      expect(yamls[1], contains('devices: ["iPad 10.9 (2022)-26"]'));
      expect(yamls[1], contains('buildName: "ios-matrix-iPad_10.9_2022_26"'));
      // The shared coordinator cannot attribute sessions to devices.
      expect(maxInFlight, 1);
      verify(() => getDep<LtIosRunner>().buildIosForHyperexecute(
            target: null,
            env: any(named: 'env'),
            reuseLast: any(named: 'reuseLast'),
            shards: any(named: 'shards'),
            selection: any(named: 'selection'),
            selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
          )).called(1);
      verify(() => getDep<MplatrolLogger>().info('[device-matrix] iOS verdicts per device:')).called(1);
    });

    test('returns usage when no iOS Patrol shards are discovered', () async {
      final repo = Directory.systemTemp.createTempSync();
      addTearDown(() => repo.deleteSync(recursive: true));
      Directory(p.join(repo.path, 'patrol_test')).createSync();
      _stubRepo(repo);

      final result = await LtHyperexecuteRunner().runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {'LT_USERNAME': 'user', 'LT_ACCESS_KEY': 'key', 'LT_BIN': '/Users/test/Downloads/LT'},
      );

      expect(result, ExitCode.usage.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('No iOS Patrol test shards discovered.'))))
          .called(1);
    });

    test('returns software when iOS HyperExecute artifacts are missing', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: any(named: 'target'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ),
      ).thenAnswer((_) async => null);

      final result = await LtHyperexecuteRunner().runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {'LT_USERNAME': 'user', 'LT_ACCESS_KEY': 'key', 'LT_BIN': '/Users/test/Downloads/LT'},
      );

      expect(result, ExitCode.software.code);
    });

    test('uses a generated iOS build name with an implicit coordinator', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {
          'LT_USERNAME': 'user',
          'LT_ACCESS_KEY': 'key',
          'LT_BIN': '/Users/test/Downloads/LT',
        },
      );

      expect(result, ExitCode.success.code);
      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-ios.yaml')).readAsStringSync();
      expect(yaml, matches(RegExp(r'buildName: "LoginE2EiOS-outText-\d{8}T\d{6}Z"')));
    });

    test('writes one-build iOS YAML with one coordinator-backed shard per test', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {
          'LT_USERNAME': 'user',
          'LT_ACCESS_KEY': 'key',
          'LT_BIN': '/Users/test/Downloads/LT',
          'LT_BUILD_NAME': 'ios-one-build',
        },
        tenantLabel: 'acme',
        environmentLabel: 'Dev',
      );

      expect(result, ExitCode.success.code);
      final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-ios.yaml')).readAsStringSync();
      expect(yaml, contains('runson: ios'));
      // Two shard mappings run on two devices at once.
      expect(yaml, contains('concurrency: 2'));
      expect(yaml, contains('autosplit: true'));
      // iOS defaults retries off because the coordinator assigns methods once;
      // a retry would be an extra session after every method already ran.
      expect(yaml, contains('maxRetries: 0'));
      expect(yaml, contains('retryOnFailure: false'));
      expect(yaml, contains('shards:'));
      // Shards are named generically ("shard N") and point to synthetic XCTest
      // methods. Each synthetic method asks the coordinator which real Patrol
      // test to run, avoiding LT's class-level expansion into duplicate
      // sessions.
      expect(yaml, contains('name: "shard 1"'));
      expect(yaml, contains('values: ["LoginE2ETests/testShard01"]'));
      expect(yaml, contains('name: "shard 2"'));
      expect(yaml, contains('values: ["LoginE2ETests/testShard02"]'));
      expect(yaml, contains('strategy: "only-testing"'));
      expect(yaml, contains('tunnel: true'));
      expect(yaml, contains('jobLabel: ["acme", "Dev", "XCUI", "mplatrol-it"]'));
      expect(yaml, isNot(contains('"HyperExecute"')));
      expect(yaml, contains('localhost: true'));
      expect(yaml, contains('mitmProxy: true'));
      expect(yaml, isNot(contains('tunnelName:')));
      expect(yaml, isNot(contains('tunnelNames:')));
      // Pre-uploaded lt:// ids — the runner uploads the IPAs itself so the
      // bytes are at LT before the CLI's local test discovery needs them.
      expect(yaml, contains('appId: "lt://APPIOS"'));
      expect(yaml, contains('testSuiteAppId: "lt://TESTIOS"'));
      expect(yaml, isNot(contains('appPath')));
      final coordinatorUrl = verify(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: null,
          env: any(named: 'env'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: captureAny(named: 'selectionCoordinatorUrl'),
        ),
      ).captured.single as String;
      expect(coordinatorUrl, startsWith('http://localhost.lambdatest.com:'));
      expect(coordinatorUrl, endsWith('/assign'));
    });

    test('passes explicit iOS coordinator URL through when configured', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {
          'LT_USERNAME': 'user',
          'LT_ACCESS_KEY': 'key',
          'LT_BIN': '/Users/test/Downloads/LT',
          'LT_BUILD_NAME': 'ios-explicit-coordinator',
          'MPLATROL_IOS_SHARD_COORDINATOR_URL': 'http://coordinator.test/assign',
        },
      );

      expect(result, ExitCode.success.code);
      final coordinatorUrl = verify(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: null,
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: captureAny(named: 'selectionCoordinatorUrl'),
        ),
      ).captured.single as String;
      expect(coordinatorUrl, 'http://coordinator.test/assign');
    });

    test('routes iOS builds through the targetRegex/sdk build path', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: any(named: 'target'),
          targetRegex: any(named: 'targetRegex'),
          sdk: any(named: 'sdk'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ),
      ).thenAnswer((invocation) async {
        _captureIosCoordinatorFixture(invocation);
        return _iosCoordinatorFixtureArtifacts();
      });

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-regex'},
        targetRegex: 'patrol_test',
      );

      expect(result, ExitCode.success.code);
      verify(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: null,
          targetRegex: 'patrol_test',
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ),
      ).called(1);
    });

    test('excludes journeys whose SDK is not built from iOS shards and build', () async {
      _createExcludedSdkArtifactFixture();
      PatrolSelectionPlan? selection;
      List<String>? descriptions;
      when(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: any(named: 'target'),
          targetRegex: any(named: 'targetRegex'),
          sdk: any(named: 'sdk'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ),
      ).thenAnswer((invocation) async {
        selection = invocation.namedArguments[#selection] as PatrolSelectionPlan?;
        descriptions =
            (invocation.namedArguments[#shards] as List<IosTestShard>).map((shard) => shard.description).toList();
        return null;
      });

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-sdk-excluded'},
      );

      expect(result, ExitCode.software.code);
      expect(selection?.platform, 'ios');
      expect(selection?.excluded.map((excluded) => excluded.file), ['neutral_vendor_test']);
      expect(descriptions, isNot(contains('contact SDK journey')));
      expect(descriptions, containsAll(['first test', 'second test']));
      verify(() => getDep<MplatrolLogger>().info(any(that: contains('[sdk-excluded] iOS neutral_vendor_test:'))))
          .called(1);
    });

    test('excludes a localOnly journey from iOS shards and Dart names', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      final manifestFile = File(p.join(repo.path, patrolSdkRequirementsPath));
      final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
      (manifest['tests'] as List)
          .cast<Map>()
          .singleWhere((test) => test['file'] == 'patrol_test/login_faults_test.dart')[localOnlyKey] = true;
      manifestFile.writeAsStringSync(jsonEncode(manifest));

      final result = await _runIosVerdictFixtureOnRepo(repo);

      expect(result, ExitCode.success.code);
      expect(_iosCoordinatorFixtureDescriptions, ['first test']);
      verify(() => getDep<MplatrolLogger>().info('[sdk-excluded] iOS login_faults_test: '
          'local-only (not scheduled on LambdaTest)')).called(1);
    });
  });

  group('LambdaTest network capture', () {
    Future<String> androidYaml({required bool pinnedsdk, String? target}) async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      if (pinnedsdk) {
        _markPinnedSdkJourney(repo);
      }
      await LtHyperexecuteRunner().runAndroid(
        target: target,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
      );
      return File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-android.yaml')).readAsStringSync();
    }

    test('is off for a job that runs a PinnedSdk journey, whose SDK pins its certificates', () async {
      final yaml = await androidYaml(pinnedsdk: true);

      expect(yaml, contains('    network: false\n'));
      expect(yaml, contains('    mitmProxy: false\n'));
      expect(yaml, contains('    tunnel: true\n'));
      expect(yaml, isNot(contains('tunnelOpts')));
      verify(() => getDep<MplatrolLogger>().info('[lt-network] Android: no LambdaTest network log for this job: '
          'login_faults_test need a certificate-pinning SDK (certificatePinningSdks), which its capture proxy '
          'breaks.')).called(1);
    });

    test('stays on when the job selects no PinnedSdk journey', () async {
      final yaml = await androidYaml(pinnedsdk: true, target: 'patrol_test/patrol_login_test.dart');

      expect(yaml, contains('    network: true\n'));
      expect(yaml, contains('    mitmProxy: true\n'));
    });

    test('stays on for a suite without PinnedSdk journeys', () async {
      final yaml = await androidYaml(pinnedsdk: false);

      expect(yaml, contains('    network: true\n'));
      verifyNever(() => getDep<MplatrolLogger>().info(any(that: startsWith('[lt-network]'))));
    });
  });

  group('LtHyperexecuteRunner target/sdk routing', () {
    test('routes Android builds through the targetRegex/sdk build path', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      when(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: any(named: 'repo'),
          tenant: any(named: 'tenant'),
          target: any(named: 'target'),
          targetRegex: any(named: 'targetRegex'),
          sdk: any(named: 'sdk'),
          buildName: any(named: 'buildName'),
          auth: any(named: 'auth'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
        ),
      ).thenAnswer((_) async => AndroidLtArtifacts(appId: 'lt://APP', testSuiteAppId: 'lt://TEST'));

      final result = await LtHyperexecuteRunner().runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: const {..._androidEnv, 'HYPEREXECUTE_BIN': '/tmp/hyperexecute'},
        targetRegex: 'patrol_test',
        sdk: 'videosdk',
      );

      expect(result, ExitCode.unavailable.code);
      verify(
        () => getDep<LtAndroidRunner>().buildUploadAndroid(
          repo: repo.path,
          target: null,
          targetRegex: 'patrol_test',
          sdk: 'videosdk',
          buildName: 'android-build',
          auth: 'user:key',
          env: any(named: 'env'),
          reuseLast: false,
        ),
      ).called(1);
    });
  });

  group('LtHyperexecuteRunner skipped-session handling', () {
    test('output skip is non-pass without unsupported provider status mutation', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(
        0,
        'Build Link: https://example.test?access_key=SECRET\n'
        'MPLATROL_TEST_SKIPPED\n',
      );
      var skipLogCalls = 0;
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'android-build', 'build_id': 'bid-1'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'session_id': 'sess-skip'},
                {'session_id': 'sess-clean'},
                {'no_id': 'x'},
              ],
            }),
            200,
          );
        }
        if (url.contains('sess-skip/log/instrumentation')) {
          skipLogCalls++;
          // First attempt lags (>=400) to exercise the retry + poll delay.
          return skipLogCalls == 1 ? http.Response('lagging', 503) : http.Response('...MPLATROL_TEST_SKIPPED...', 200);
        }
        return http.Response('nothing skipped here', 200);
      });
      _stubLtPatch((url, body) => http.Response('{}', 200));

      final result = await LtHyperexecuteRunner(pollDelay: const Duration(milliseconds: 1)).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('skipped LambdaTest session could not be mapped'))))
          .called(1);
    });

    test('names tests that passed only on retry', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, 'all passed\n');
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'android-build', 'build_id': 'bid-1'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'session_id': 's1', 'name': 'backend', 'status_ind': 'failed'},
                {'session_id': 's2', 'name': 'backend', 'status_ind': 'passed'},
                {'session_id': 's3', 'name': 'login', 'status_ind': 'passed'},
                {'session_id': 's4', 'status_ind': 'passed'},
              ],
            }),
            200,
          );
        }
        return http.Response('nothing skipped here', 200);
      });

      final result = await LtHyperexecuteRunner(pollDelay: const Duration(milliseconds: 1)).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.success.code);
      verify(() => getDep<MplatrolLogger>().warn('LambdaTest Android: 1 test(s) passed only on retry (flaky): '
          'backend')).called(1);
    });

    for (final logStatus in [200, 404]) {
      test('API skipped status is non-pass without log evidence ($logStatus)', () async {
        final repo = _createRepoWithTests();
        addTearDown(() => repo.deleteSync(recursive: true));
        _stubRepo(repo);
        _stubJobResult(0, 'completed successfully');
        _stubLtGet((url) {
          if (url.contains('/builds?')) {
            return http.Response(
                jsonEncode({
                  'data': [
                    {'name': 'android-build', 'build_id': 'bid-1'}
                  ],
                }),
                200);
          }
          if (url.contains('/sessions?build_id=')) {
            return http.Response(
                jsonEncode({
                  'data': [
                    {'session_id': 'skipped-session', 'status_ind': 'skipped'}
                  ],
                }),
                200);
          }
          return http.Response('', logStatus);
        });
        _stubLtPatch((_, __) => http.Response('{}', 200));

        final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
          target: null,
          devices: const ['Pixel 8-14'],
          idleTimeoutSeconds: 123,
          env: _androidEnv,
        );

        expect(result, ExitCode.unavailable.code);
        verifyNever(() => getDep<LtHttp>().get(
              any(that: contains('/log/instrumentation')),
              headers: any(named: 'headers'),
              timeout: any(named: 'timeout'),
            ));
        verifyNever(() => getDep<MplatrolLogger>().success('HyperExecute Android E2E passed.'));
      });
    }

    test('does not PATCH unsupported real-device skipped status', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, 'MPLATROL_TEST_SKIPPED\n');
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'android-build', 'build_id': 'bid-1'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'session_id': 'sess-a'},
                {'session_id': 'sess-b'},
              ],
            }),
            200,
          );
        }
        return http.Response('MPLATROL_TEST_SKIPPED', 200);
      });
      when(
        () => getDep<LtHttp>().patchJson(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((invocation) async {
        final url = invocation.positionalArguments.single as String;
        if (url.contains('sess-a')) {
          return http.Response('nope', 409);
        }
        throw Exception('patch boom');
      });

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      verifyNever(() => getDep<LtHttp>().patchJson(any(), headers: any(named: 'headers'), body: any(named: 'body')));
    });

    test('warns when the skipped build cannot be found', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, 'MPLATROL_TEST_SKIPPED\n');
      _stubLtGet((url) => http.Response(jsonEncode({'data': []}), 200));

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>()
          .warn(any(that: contains('Could not find LambdaTest Android build "android-build"')))).called(1);
    });

    test('warns when a skipped build has no sessions', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, 'MPLATROL_TEST_SKIPPED\n');
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'android-build', 'build_id': 'bid-1'},
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'data': []}), 200);
      });

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('had no sessions to mark skipped')))).called(1);
    });

    test('marks the lone session when output skips but logs do not map', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, 'MPLATROL_TEST_SKIPPED\n');
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'android-build', 'build_id': 'bid-1'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'session_id': 'only-session'},
              ],
            }),
            200,
          );
        }
        return http.Response('clean instrumentation', 200);
      });
      _stubLtPatch((url, body) => http.Response('{}', 200));

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().err(any(that: contains('detected 1 skipped session(s)')))).called(1);
    });

    test('warns when a skip cannot be mapped to any session', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      _stubJobResult(0, 'MPLATROL_TEST_SKIPPED\n');
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'android-build', 'build_id': 'bid-1'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'session_id': 'sess-a'},
                {'session_id': 'sess-b'},
              ],
            }),
            200,
          );
        }
        return http.Response('clean instrumentation', 200);
      });

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runAndroid(
        target: null,
        devices: const ['Pixel 8-14'],
        idleTimeoutSeconds: 123,
        env: _androidEnv,
      );

      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().warn(any(
          that: contains('skipped LambdaTest session could not be '
              'mapped')))).called(1);
    });
  });

  group('LtHyperexecuteRunner iOS shard coordinator', () {
    Future<void> hitCoordinator(String coordinatorUrl, String pathAndQuery) async {
      final port = Uri.parse(coordinatorUrl).port;
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$pathAndQuery'));
        final response = await request.close();
        await response.drain<void>();
      } finally {
        client.close();
      }
    }

    test('assigns shards over HTTP and renames the matched LT sessions', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      String? coordinatorUrl;
      when(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: any(named: 'target'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ),
      ).thenAnswer((invocation) async {
        coordinatorUrl = invocation.namedArguments[#selectionCoordinatorUrl] as String;
        return IosHyperexecuteArtifacts(
          appPath: '/tmp/Runner.ipa',
          testSuitePath: '/tmp/RunnerUITests-Runner.ipa',
          appId: 'lt://APPIOS',
          testSuiteAppId: 'lt://TESTIOS',
          productsDir: '/tmp',
        );
      });
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenAnswer((_) async {
        final url = coordinatorUrl!;
        await hitCoordinator(url, '/nope');
        await hitCoordinator(url, '/assign');
        await hitCoordinator(url, '/assign?xctestSession=s1');
        await hitCoordinator(url, '/assign?xctestSession=s1');
        await hitCoordinator(url, '/assign?runnerSession=r2');
        await hitCoordinator(url, '/assign?runnerSession=r3');
        return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
      });
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'ios-handle', 'build_id': 'bid-ios'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'session_id': 's1', 'start_timestamp': '1'},
                {'session_id': 's2', 'start_timestamp': '2'},
              ],
            }),
            200,
          );
        }
        if (url.contains('s1/log/instrumentation')) {
          return http.Response('PATROL_SELECTION_SOURCE source=x method=testAFirstTest', 200);
        }
        if (url.contains('s2/log/instrumentation')) {
          return http.Response('PATROL_SELECTION_SOURCE source=x method=testBSecondTest', 200);
        }
        return http.Response('{}', 200);
      });
      _stubLtPatch((url, body) => http.Response('{}', url.contains('s2') ? 400 : 200));

      final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-handle'},
      );

      // Rename fixtures have unrelated provider session IDs, not verified HE evidence.
      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('rename failed for s2 (HTTP 400)')))).called(1);
    });

    test('falls back to coordinator order and warns on partial matches', () async {
      final repo = _createRepoWithTests();
      addTearDown(() => repo.deleteSync(recursive: true));
      _stubRepo(repo);
      String? coordinatorUrl;
      when(
        () => getDep<LtIosRunner>().buildIosForHyperexecute(
          target: any(named: 'target'),
          env: any(named: 'env'),
          reuseLast: any(named: 'reuseLast'),
          shards: any(named: 'shards'),
          selection: any(named: 'selection'),
          selectionCoordinatorUrl: any(named: 'selectionCoordinatorUrl'),
        ),
      ).thenAnswer((invocation) async {
        coordinatorUrl = invocation.namedArguments[#selectionCoordinatorUrl] as String;
        return IosHyperexecuteArtifacts(
          appPath: '/tmp/Runner.ipa',
          testSuitePath: '/tmp/RunnerUITests-Runner.ipa',
          appId: 'lt://APPIOS',
          testSuiteAppId: 'lt://TESTIOS',
          productsDir: '/tmp',
        );
      });
      when(
        () => getDep<MplatrolShell>().runArgs(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          throwOnError: any(named: 'throwOnError'),
          cancelOn: any(named: 'cancelOn'),
        ),
      ).thenAnswer((_) async {
        final url = coordinatorUrl!;
        await hitCoordinator(url, '/assign?xctestSession=s1');
        await hitCoordinator(url, '/assign?xctestSession=s2');
        return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
      });
      _stubLtGet((url) {
        if (url.contains('/builds?')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'name': 'ios-fallback', 'build_id': 'bid-ios'},
              ],
            }),
            200,
          );
        }
        if (url.contains('/sessions?build_id=')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'no_id': 'x'},
                {'session_id': 'sa', 'start_timestamp': '2'},
                {'session_id': 'sb', 'start_timestamp': '2'},
                {'session_id': 'sc', 'create_timestamp': '5'},
                {'session_id': 'sd'},
              ],
            }),
            200,
          );
        }
        if (url.contains('sa/log/instrumentation')) {
          return http.Response('PATROL_SELECTION_SOURCE source=x method=unknownMethod', 200);
        }
        return http.Response('no selection marker here', 200);
      });
      _stubLtPatch((url, body) => http.Response('{}', 200));

      final result = await LtHyperexecuteRunner(pollDelay: const Duration(milliseconds: 1)).runIos(
        target: null,
        devices: const ['iPhone 17 Pro-26'],
        idleTimeoutSeconds: 240,
        env: const {..._iosEnv, 'LT_BUILD_NAME': 'ios-fallback'},
      );

      // Coordinator-order display names cannot certify mismatched native sessions.
      expect(result, ExitCode.unavailable.code);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('assignment/session count mismatch')))).called(1);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('no assignment available for sd')))).called(1);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('session title(s) from instrumentation'))))
          .called(1);
    });

    for (final retries in [null, '0', '2']) {
      for (final failure in [
        (name: 'no assignment', exit: 1, output: 'Failed Tasks: 1'),
        (
          name: 'connection refused',
          exit: 1,
          output: 'iOS shard coordinator: HTTP 500: '
              'dial tcp 127.0.0.1:55502: connect: connection refused'
        ),
        (name: 'native NoShard', exit: 0, output: 'PATROL_NO_SHARD'),
      ]) {
        test('preserves first ${failure.name} with retries ${retries ?? 'default'}', () async {
          final repo = _createRepoWithTests();
          addTearDown(() => repo.deleteSync(recursive: true));
          _stubRepo(repo);
          final platform = getDep<PlatformWrapper>();
          when(() => platform.environment).thenReturn({
            if (retries != null) e2eMaxRetriesEnv: retries,
          });
          final env = {..._iosEnv, 'LT_BUILD_NAME': 'ios-first-job'};
          var jobCalls = 0;
          when(() => getDep<MplatrolShell>().runArgs(any(), any(),
              workingDirectory: any(named: 'workingDirectory'),
              throwOnError: any(named: 'throwOnError'),
              cancelOn: any(named: 'cancelOn'))).thenAnswer((_) async {
            jobCalls++;
            if (jobCalls > 1) {
              await _requestIosFixtureAssignments();
              return ProcessResultX.from(ProcessResult(0, 0, _jobLink, ''));
            }
            await hitCoordinator(_iosCoordinatorFixtureUrl!, '/nope');
            return ProcessResultX.from(ProcessResult(0, failure.exit, '${failure.output}\n$_jobLink', ''));
          });
          _stubLtGet(
              (url) => http.Response(
                  jsonEncode({
                    'data': url.contains('/builds?')
                        ? [
                            {'name': 'ios-first-job', 'build_id': 'first-build'}
                          ]
                        : [],
                  }),
                  200),
              includePassedJob: failure.exit == 0);

          final result = await LtHyperexecuteRunner(pollDelay: Duration.zero).runIos(
            target: null,
            devices: const ['iPhone 17 Pro-26'],
            idleTimeoutSeconds: 240,
            env: env,
          );

          expect(result, failure.exit == 0 ? ExitCode.unavailable.code : ExitCode.software.code);
          expect(jobCalls, 1);
          verify(() => getDep<MplatrolShell>().runArgs(any(), any(),
              workingDirectory: repo.path, throwOnError: false, cancelOn: any(named: 'cancelOn'))).called(1);
          verifyNever(() => getDep<MplatrolLogger>().warn(any(that: contains('failed before assigning any shard'))));
          if (failure.exit != 0) {
            verify(() => getDep<LtDiagnostics>().report(buildId: 'first-build', platform: 'iOS', env: env)).called(1);
            // No session received a shard: each one is NOT RUN, never a pass.
            verify(() => getDep<MplatrolLogger>()
                .err(any(that: startsWith('[ios-shard-coordinator] NOT RUN (infrastructure): ')))).called(2);
          }
          final yaml = File(p.join(repo.path, '.mplatrol', 'hyperexecute-lt-ios.yaml')).readAsStringSync();
          expect(yaml, contains('buildName: "ios-first-job"'));
          expect(yaml, contains('maxRetries: ${retries ?? '0'}'));
          expect(yaml, contains('retryOnFailure: ${retries == '2'}'));
          final socket = await Socket.connect(InternetAddress.loopbackIPv4, Uri.parse(_iosCoordinatorFixtureUrl!).port,
                  timeout: const Duration(seconds: 2))
              .then<Socket?>((socket) => socket, onError: (Object error) {
            expect(error, isA<SocketException>());
            return null;
          });
          socket?.destroy();
          expect(socket, isNull, reason: 'The owned coordinator must be closed.');
        });
      }
    }
  });
}
