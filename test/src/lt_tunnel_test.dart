import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/lt_http.dart';
import 'package:mplatrol/src/lt_tunnel.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

class _MockMplatrolProcess extends Mock implements MplatrolProcess {}

const _readyLine = 'You can start testing now';
const _autoNameLine = 'Tunnel Name was not specified, using: auto-abc123';

void main() {
  late MplatrolShell shell;
  late MplatrolLogger logger;
  late _MockMplatrolProcess process;
  late List<MapEntry<String, List<String>>> startCalls;
  late LtHttp ltHttp;

  /// Stub `shell.start` to hand back [process], recording each (exe, args)
  /// vector so the launch flags can be asserted.
  void stubStart() {
    when(() => shell.start(any(), any(), workingDirectory: any(named: 'workingDirectory'))).thenAnswer((
      invocation,
    ) async {
      startCalls.add(
        MapEntry(
          invocation.positionalArguments[0] as String,
          (invocation.positionalArguments[1] as List).cast<String>(),
        ),
      );
      return process;
    });
  }

  /// Stub the LT tunnels API to return [bodies] in sequence, repeating the
  /// last one once the sequence is exhausted.
  void stubTunnelsApi(List<String> bodies) {
    var call = 0;
    when(
      () => ltHttp.get(
        any(that: contains('/tunnels')),
        headers: any(named: 'headers'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer((_) async {
      final body = bodies[call < bodies.length ? call : bodies.length - 1];
      call++;
      return http.Response(body, 200);
    });
  }

  setUp(() async {
    await scaffoldMockDependencies();
    shell = getDep<MplatrolShell>();
    logger = getDep<MplatrolLogger>();
    ltHttp = getDep<LtHttp>();
    process = _MockMplatrolProcess();
    startCalls = [];
    when(process.kill).thenReturn(null);
    stubStart();
    when(() => ltHttp.basicAuth(any(), any())).thenReturn(const {});
    // Default: both fixture tunnel names are already registered, so tests
    // that aren't about the registration wait pass straight through it.
    const registeredBoth = '{"data": [{"tunnel_name": "alkstg", "status_ind": "running"}, '
        '{"tunnel_name": "auto-abc123", "status_ind": "running"}]}';
    stubTunnelsApi([registeredBoth]);
  });

  /// Zero poll delay keeps the readiness loop instant in tests.
  LtTunnel tunnel() => LtTunnel(pollDelay: Duration.zero);

  group('LtTunnel.start', () {
    test('passes an explicit tunnel name through and reports ready', () async {
      when(() => process.output).thenReturn(_readyLine);

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k', tunnelName: 'alkstg');

      expect(result.ready, isTrue);
      expect(result.name, 'alkstg');
      expect(result.process, same(process));
      expect(startCalls.single.key, '/Downloads/LT');
      expect(startCalls.single.value, ['--user', 'u', '--key', 'k', '--tunnelName', 'alkstg', '--mitm']);
    });

    test('never kills other processes (no pkill) — only starts its own tunnel', () async {
      when(() => process.output).thenReturn(_readyLine);

      await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k');

      verifyNever(() => shell.runArgs('pkill', any(), throwOnError: any(named: 'throwOnError')));
    });

    test('auto-generates and reads back the name when none is given', () async {
      when(() => process.output).thenReturn('$_autoNameLine\n$_readyLine');

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k');

      expect(result.ready, isTrue);
      expect(result.name, 'auto-abc123');
      // No --tunnelName flag when the name is auto-assigned.
      expect(startCalls.single.value, isNot(contains('--tunnelName')));
    });

    test('treats an empty tunnel name like none (auto-assigned)', () async {
      when(() => process.output).thenReturn('$_autoNameLine\n$_readyLine');

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k', tunnelName: '');

      expect(result.name, 'auto-abc123');
      expect(startCalls.single.value, isNot(contains('--tunnelName')));
    });

    test('fails when ready but the auto name cannot be read', () async {
      // Ready line present, but no "using: <name>" line to parse.
      when(() => process.output).thenReturn(_readyLine);

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k');

      expect(result.ready, isFalse);
      expect(result.name, '');
      verify(() => logger.err(any(that: contains('name could not be read')))).called(1);
    });

    test('returns not-ready when the tunnel never reports ready', () async {
      when(() => process.output).thenReturn('starting tunnel...');

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k', tunnelName: 'alkstg');

      expect(result.ready, isFalse);
      expect(result.process, same(process));
      verify(() => logger.err(any(that: contains('did not become ready')))).called(1);
    });

    test('becomes ready when the line appears on a later poll', () async {
      var reads = 0;
      when(() => process.output).thenAnswer((_) {
        reads++;
        return reads < 3 ? 'starting tunnel...' : _readyLine;
      });

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k', tunnelName: 'alkstg');

      expect(result.ready, isTrue);
      expect(reads, greaterThanOrEqualTo(3));
    });

    test('waits for the tunnel to appear in the LT tunnels API', () async {
      // HyperExecute validates `tunnelNames` against the LT tunnels API once,
      // immediately, with no retry — and a just-started tunnel takes a few
      // seconds to appear there. LT returns `"data": {}` (a single map, not an
      // array) while the account shows no tunnels; both shapes must be treated
      // as not-registered-yet.
      when(() => process.output).thenReturn(_readyLine);
      stubTunnelsApi([
        '{"data": {}}',
        '{"data": []}',
        '{"data": [{"tunnel_name": "alkstg", "status_ind": "running"}]}',
      ]);

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k', tunnelName: 'alkstg');

      expect(result.ready, isTrue);
      verify(
        () => ltHttp.get(
          any(that: contains('/tunnels')),
          headers: any(named: 'headers'),
          timeout: any(named: 'timeout'),
        ),
      ).called(3);
    });

    test('fails when the tunnel never registers with the LT API', () async {
      when(() => process.output).thenReturn(_readyLine);
      stubTunnelsApi(['{"data": {}}']);

      final result = await tunnel().start(ltBin: '/Downloads/LT', ltUser: 'u', ltKey: 'k', tunnelName: 'alkstg');

      expect(result.ready, isFalse);
      expect(result.process, same(process));
      verify(() => logger.err(any(that: contains('never appeared in the LambdaTest')))).called(1);
    });
  });
}
