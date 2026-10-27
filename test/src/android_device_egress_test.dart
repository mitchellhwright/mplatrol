import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/android_device_egress.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _pixel = '54120DLAQ002QN';

void main() {
  late List<String> adbCalls;
  late String currentProxy;
  late Set<String> failing;

  setUp(() async {
    await scaffoldMockDependencies();
    adbCalls = [];
    currentProxy = 'null';
    failing = {};
    when(() => getDep<MplatrolShell>().runArgs('adb', any(), throwOnError: false, silent: true))
        .thenAnswer((invocation) async {
      final args = invocation.positionalArguments[1] as List<String>;
      expect(args.take(2), ['-s', _pixel]);
      final command = args.skip(2).join(' ');
      adbCalls.add(command);
      final fails = failing.any(command.startsWith);
      return ProcessResultX(
        pid: 1,
        exitCode: fails ? 1 : 0,
        stdout: command == 'shell settings get global http_proxy' ? '$currentProxy\n' : '',
        stderr: '',
      );
    });
  });

  int routedPort() {
    final reverse = adbCalls.firstWhere((call) => call.startsWith('reverse tcp:'));
    return int.parse(reverse.split(' ')[1].substring(4));
  }

  test('routes the phone through the Mac for the run, then clears the proxy it set', () async {
    Map<String, String>? runEnv;
    List<String>? callsDuringRun;

    final result = await AndroidDeviceEgress().around(_pixel, (env) async {
      runEnv = env;
      callsDuringRun = [...adbCalls];
      return 7;
    });

    final port = routedPort();
    expect(result, 7);
    expect(runEnv, {e2eDeviceProxyEnv: 'true'});
    expect(callsDuringRun, [
      'shell settings get global http_proxy',
      'reverse tcp:$port tcp:$port',
      'shell settings put global http_proxy 127.0.0.1:$port',
    ]);
    expect(adbCalls.skip(3), [
      'shell settings put global http_proxy :0',
      'shell settings delete global http_proxy',
      'reverse --remove tcp:$port',
    ]);
    verify(() => getDep<MplatrolLogger>().info(any(that: contains('traffic -> this Mac')))).called(1);
    verify(() => getDep<MplatrolLogger>()
            .info(any(that: allOf(startsWith('[device-egress] restored $_pixel proxy'), contains('http_proxy :0')))))
        .called(1);
  });

  test('puts back a proxy the phone already had', () async {
    currentProxy = '10.0.0.5:8888';

    await AndroidDeviceEgress().around(_pixel, (_) async => 0);

    expect(adbCalls, contains('shell settings put global http_proxy 10.0.0.5:8888'));
    expect(adbCalls, isNot(contains('shell settings delete global http_proxy')));
  });

  test('clears a loopback proxy left behind by an interrupted run instead of restoring it', () async {
    currentProxy = '127.0.0.1:59927';

    await AndroidDeviceEgress().around(_pixel, (_) async => 0);

    expect(adbCalls, contains('shell settings put global http_proxy :0'));
    expect(adbCalls, contains('shell settings delete global http_proxy'));
    expect(adbCalls, isNot(contains('shell settings put global http_proxy 127.0.0.1:59927')));
    verify(() => getDep<MplatrolLogger>().warn(any(that: contains('still had proxy 127.0.0.1:59927')))).called(1);
  });

  test('restores the phone when the run throws', () async {
    await expectLater(
      AndroidDeviceEgress().around<int>(_pixel, (_) async => throw StateError('build failed')),
      throwsA(isA<StateError>()),
    );

    final port = routedPort();
    expect(adbCalls.last, 'reverse --remove tcp:$port');
    expect(adbCalls, contains('shell settings put global http_proxy :0'));
  });

  for (final (step, failingCall, expectRouteUndo) in [
    ('reading the current proxy fails', 'shell settings get', false),
    ('adb reverse fails', 'reverse tcp:', false),
    ('setting the proxy fails', 'shell settings put', true),
  ]) {
    test('runs unrouted with a warning when $step', () async {
      failing = {failingCall};
      Map<String, String>? runEnv;

      await AndroidDeviceEgress().around(_pixel, (env) async {
        runEnv = env;
        return 0;
      });

      expect(runEnv, isEmpty);
      expect(adbCalls.any((call) => call.startsWith('reverse --remove')), expectRouteUndo);
      verify(() => getDep<MplatrolLogger>().warn(any(
              that: allOf(
            startsWith('[device-egress] could not route $_pixel through this Mac'),
            contains('Unauthorized network location'),
          )))).called(1);
    });
  }
}
