import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:mplatrol/src/ios_device_egress.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

const _iphone = '00008140-000435880C8B001C';

/// Stubs `xcrun devicectl`: `device info details` reports [hostnames];
/// `device process launch` (opening Safari) runs [onSafari] and exits with [launchExitCode].
void _stubDevicectl({
  required List<String>? hostnames,
  int exitCode = 0,
  String? rawJson,
  int launchExitCode = 0,
  Future<void> Function()? onSafari,
}) {
  when(() => getDep<MplatrolShell>().runArgs('xcrun', any(), throwOnError: false, silent: true))
      .thenAnswer((invocation) async {
    final args = invocation.positionalArguments[1] as List<String>;
    if (args.contains('launch')) {
      expect(args, [
        'devicectl', 'device', 'process', 'launch', '--device', _iphone, //
        '--payload-url', IosDeviceEgress.probeUrl, 'com.apple.mobilesafari',
      ]);
      await onSafari?.call();
      return ProcessResultX(pid: 1, exitCode: launchExitCode, stdout: '', stderr: '');
    }
    expect(args.take(6), ['devicectl', 'device', 'info', 'details', '--device', _iphone]);
    final json = args.last;
    if (exitCode == 0) {
      File(json).writeAsStringSync(rawJson ??
          jsonEncode({
            'result': {
              'connectionProperties': {'localHostnames': hostnames},
            },
          }));
    }
    return ProcessResultX(pid: 1, exitCode: exitCode, stdout: '', stderr: '');
  });
}

void stubMacName(String? name) =>
    when(() => getDep<MplatrolShell>().runArgs('scutil', ['--get', 'LocalHostName'], throwOnError: false, silent: true))
        .thenAnswer(
            (_) async => ProcessResultX(pid: 1, exitCode: name == null ? 1 : 0, stdout: name ?? '', stderr: ''));

void main() {
  late List<String> lookups;
  late Map<String, List<String>> addresses;
  late int port;

  setUp(() async {
    await scaffoldMockDependencies();
    lookups = [];
    addresses = {
      'Blakes-iPhone.local': ['169.254.155.107', '127.0.0.1']
    };
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = free.port;
    await free.close();
    when(() => getDep<PlatformWrapper>().environment).thenReturn({iosDeviceProxyPortEnv: '$port'});
    when(getDep<PlatformWrapper>().localNetworkHost).thenAnswer((_) async => '127.0.0.1');
    stubMacName('MAC-TEST');
    _stubDevicectl(hostnames: [
      '1B9DE065-E4A3-5184-BA9A-C280EE28FC56.coredevice.local',
      'Blakes-iPhone.coredevice.local',
    ]);
  });

  IosDeviceEgress egress() => IosDeviceEgress(lookup: (host) async {
        lookups.add(host);
        return addresses[host] ?? const [];
      });

  Future<String> get(String path) async {
    final client = HttpClient();
    try {
      final response = await (await client.get('127.0.0.1', port, path)).close();
      return '${response.statusCode} ${await utf8.decodeStream(response)}';
    } finally {
      client.close(force: true);
    }
  }

  test('serves the PAC file to the phone during the run and logs the one-time setup', () async {
    Map<String, String>? runEnv;
    String? pac;

    final result = await egress().around(_iphone, (env) async {
      runEnv = env;
      pac = await get('/proxy.pac');
      return 3;
    });

    expect(result, 3);
    expect(runEnv, {e2eDeviceProxyEnv: 'true'});
    expect(lookups, ['Blakes-iPhone.local']);
    expect(pac, startsWith('200 function FindProxyForURL'));
    expect(pac, contains('"PROXY MAC-TEST.local:$port; DIRECT"'));
    verify(() => getDep<MplatrolLogger>().info(any(
            that: allOf(
          contains('iPhone $_iphone (127.0.0.1, 169.254.155.107) test traffic -> this Mac'),
          contains('Configure Proxy > Automatic, URL http://MAC-TEST.local:$port/proxy.pac'),
        )))).called(1);
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
  });

  test('warns when the phone sent nothing, naming the URL and refused addresses', () async {
    addresses = {
      'Blakes-iPhone.local': ['10.9.9.9']
    };

    await egress().around(_iphone, (_) async {
      final refused = await Socket.connect(InternetAddress.loopbackIPv4, port);
      // The proxy hangs up on a refused address: the read stream just ends.
      await refused.drain<void>().timeout(const Duration(seconds: 5));
      refused.destroy();
      return 0;
    });

    verify(() => getDep<MplatrolLogger>().warn(any(
            that: allOf(
          contains('sent no traffic through this Mac. If the app started on the phone'),
          contains('URL http://MAC-TEST.local:$port/proxy.pac'),
          contains('Refused connections from 127.0.0.1'),
        )))).called(1);
  });

  test('reports reached hosts after a routed run', () async {
    final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(upstream.close);
    upstream.listen((socket) => socket.destroy());

    await egress().around(_iphone, (_) async {
      final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
      try {
        await (await client.get('127.0.0.1', upstream.port, '/')).close();
      } on HttpException {
        // The upstream hangs up; only the proxied host matters here.
      } finally {
        client.close(force: true);
      }
      return 0;
    });

    verify(() => getDep<MplatrolLogger>().info('[device-egress] iPhone $_iphone reached 1 host(s) through this Mac.'))
        .called(1);
  });

  test("falls back to the Mac's Wi-Fi address when it has no Bonjour name", () async {
    stubMacName(null);

    await egress().around(_iphone, (_) async => 0);

    verify(() => getDep<MplatrolLogger>().info(any(that: contains('URL http://127.0.0.1:$port/proxy.pac')))).called(1);
  });

  test('accepts the phone over IPv6 when its .local name resolves there', () async {
    addresses = {
      'Blakes-iPhone.local': ['192.168.1.238', '::1', 'fe80::1417:1275:937d:2382%en0'],
    };
    String? pac;

    await egress().around(_iphone, (_) async {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse('http://[::1]:$port/proxy.pac'))).close();
        pac = await utf8.decodeStream(response);
      } finally {
        client.close(force: true);
      }
      return 0;
    });

    expect(pac, startsWith('function FindProxyForURL'));
  });

  group('phone setup check', () {
    const hostnames = ['Blakes-iPhone.coredevice.local'];

    Future<void> proxiedRequest() async {
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((socket) => socket.destroy());
      final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
      try {
        await (await client.get('127.0.0.1', upstream.port, '/')).close();
      } on HttpException {
        // The upstream hangs up; only the proxied host matters here.
      } finally {
        client.close(force: true);
        await upstream.close();
      }
    }

    test('phoneSetup gives the Bonjour PAC URL and the phone addresses', () async {
      final setup = await egress().phoneSetup(_iphone);

      expect(setup.missing, isNull);
      expect(setup.pacUrl, 'http://MAC-TEST.local:$port/proxy.pac');
      expect(setup.phoneAddresses, {'127.0.0.1', '169.254.155.107'});
    });

    test('phoneSetup names what is missing', () async {
      _stubDevicectl(hostnames: null, exitCode: 1);

      final setup = await egress().phoneSetup(_iphone);

      expect(setup.missing, "the iPhone's Wi-Fi address");
    });

    test('verifyRoute is routed when Safari traffic reaches the proxy', () async {
      _stubDevicectl(hostnames: hostnames, onSafari: proxiedRequest);
      final e = egress();

      final check = await e.verifyRoute(await e.phoneSetup(_iphone), _iphone);

      expect(check.routed, isTrue);
      expect(check.hosts, hasLength(1));
      expect(check.problem, isNull);
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
    });

    test('verifyRoute reports refused addresses when the phone is not the peer', () async {
      addresses = {
        'Blakes-iPhone.local': ['10.9.9.9']
      };
      _stubDevicectl(
          hostnames: hostnames,
          onSafari: () async {
            final refused = await Socket.connect(InternetAddress.loopbackIPv4, port);
            await refused.drain<void>().timeout(const Duration(seconds: 5));
            refused.destroy();
          });
      final e = egress();

      final check = await e.verifyRoute(await e.phoneSetup(_iphone), _iphone);

      expect(check.routed, isFalse);
      expect(check.problem, isNull);
      expect(check.refused, {'127.0.0.1'});
    });

    test('verifyRoute times out with no traffic', () async {
      _stubDevicectl(hostnames: hostnames);
      final e = egress();

      final check = await e.verifyRoute(await e.phoneSetup(_iphone), _iphone, timeout: const Duration(seconds: 3));

      expect(check.routed, isFalse);
      expect(check.hosts, isEmpty);
      expect(check.refused, isEmpty);
    });

    test('verifyRoute reports a locked phone when Safari cannot open', () async {
      _stubDevicectl(hostnames: hostnames, launchExitCode: 1);
      final e = egress();

      final check = await e.verifyRoute(await e.phoneSetup(_iphone), _iphone);

      expect(check.routed, isFalse);
      expect(check.problem, 'could not open Safari on the phone (is it unlocked?)');
    });

    test('verifyRoute reports a busy port', () async {
      final taken = await ServerSocket.bind(InternetAddress.anyIPv6, port);
      addTearDown(taken.close);
      final e = egress();

      final check = await e.verifyRoute(await e.phoneSetup(_iphone), _iphone);

      expect(check.routed, isFalse);
      expect(check.problem, startsWith('port $port is in use on this Mac ('));
    });
  });

  test('PAC sends only the configured domains through the Mac', () {
    final pac = IosDeviceEgress.pacScript('192.168.1.236:47480');

    for (final domain in IosDeviceEgress.proxiedDomains) {
      expect(pac, contains('dnsDomainIs(host, "$domain")'));
    }
    expect(pac, contains('return "PROXY 192.168.1.236:47480; DIRECT";'));
    expect(pac, endsWith('return "DIRECT";\n}\n'));
  });

  group('runs unrouted with a warning when', () {
    Future<void> expectUnrouted(String missing) async {
      Map<String, String>? runEnv;
      await egress().around(_iphone, (env) async {
        runEnv = env;
        return 0;
      });
      expect(runEnv, isEmpty);
      verify(() => getDep<MplatrolLogger>().warn(any(
              that: allOf(
            startsWith('[device-egress] could not route iPhone $_iphone through this Mac (no $missing)'),
            contains('Unauthorized network location'),
          )))).called(1);
    }

    test('the Mac has neither a Bonjour name nor a Wi-Fi address', () async {
      stubMacName(null);
      when(getDep<PlatformWrapper>().localNetworkHost).thenAnswer((_) async => null);
      await expectUnrouted("this Mac's Wi-Fi address");
    });

    test('devicectl fails', () async {
      _stubDevicectl(hostnames: null, exitCode: 1);
      await expectUnrouted("the iPhone's Wi-Fi address");
    });

    test('devicectl output is not JSON', () async {
      _stubDevicectl(hostnames: null, rawJson: 'not json');
      await expectUnrouted("the iPhone's Wi-Fi address");
    });

    test('the phone only has a CoreDevice UUID host name', () async {
      _stubDevicectl(hostnames: ['00008140-000435880C8B001C.coredevice.local']);
      await expectUnrouted("the iPhone's Wi-Fi address");
      expect(lookups, isEmpty);
    });

    test('the system lookup finds no phone on Bonjour', () async {
      _stubDevicectl(hostnames: ['mplatrol-no-such-phone-7f3a.coredevice.local']);
      Map<String, String>? runEnv;

      await IosDeviceEgress().around(_iphone, (env) async {
        runEnv = env;
        return 0;
      });

      expect(runEnv, isEmpty);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains("(no the iPhone's Wi-Fi address)")))).called(1);
    });

    test('the phone has no Wi-Fi IPv4 address', () async {
      addresses = {
        'Blakes-iPhone.local': ['fe80::1', '169.254.155.107'],
      };
      await expectUnrouted("the iPhone's Wi-Fi address");
    });

    test('Bonjour only returns a link-local address', () async {
      addresses = {
        'Blakes-iPhone.local': ['169.254.155.107']
      };
      await expectUnrouted("the iPhone's Wi-Fi address");
    });

    test('the proxy port is already taken', () async {
      final taken = await ServerSocket.bind(InternetAddress.anyIPv6, port);
      addTearDown(taken.close);
      Map<String, String>? runEnv;

      await egress().around(_iphone, (env) async {
        runEnv = env;
        return 0;
      });

      expect(runEnv, isEmpty);
      verify(() => getDep<MplatrolLogger>().warn(any(that: contains('(no port $port on this Mac')))).called(1);
    });
  });
}
