import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_config.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/core/retry_helper.dart';
import 'package:mplatrol/src/device_egress_proxy.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';
import 'package:path/path.dart' as p;

/// Looks up the IPv4 and IPv6 addresses of a host name (Bonjour `.local` names included).
typedef AddressLookup = Future<List<String>> Function(String host);

/// Env var overriding the fixed port the iPhone's proxy setting points at.
const iosDeviceProxyPortEnv = 'MPLATROL_E2E_DEVICE_PROXY_PORT';

/// Routes a physical iPhone's test-environment traffic through this Mac for one run.
///
/// An iPhone has no `adb reverse`, so it reaches the Mac over Wi-Fi. The phone
/// is set up once: Settings > Wi-Fi > (i) > Configure Proxy > Automatic, with
/// the URL this class logs (`http://<mac>.local:<port>/proxy.pac`). The URL and
/// the PAC file's proxy use the Mac's Bonjour name, so the setting survives the
/// Mac's Wi-Fi address changing. During a run mplatrol serves that PAC file and the
/// proxy on IPv4 and IPv6 (a `.local` name may resolve to either), accepting
/// connections only from the phone's current addresses (found through
/// CoreDevice and Bonjour). The PAC file sends the `network.proxied-domains` of `mplatrol.yaml` (every host when
/// none are configured) through the Mac and everything else direct; outside a run nothing answers, so the phone
/// falls back to its own network. The build turns on the app's Developer Tools
/// proxy ([e2eDeviceProxyEnv]) so the app's own API calls follow the PAC file.
class IosDeviceEgress {
  /// Creates the service; [lookup] resolves host names to IP addresses.
  IosDeviceEgress({AddressLookup? lookup}) : _lookup = lookup ?? _systemLookup;

  /// Default port for the phone's one-time proxy setting.
  static const defaultPort = 47480;

  /// Domains the PAC file sends through the Mac (`network.proxied-domains`); the rest go direct. Empty: every
  /// host goes through the Mac.
  static List<String> get proxiedDomains => getDep<MplatrolConfig>().network.proxiedDomains;

  final AddressLookup _lookup;

  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();
  PlatformWrapper get _platform => getDep<PlatformWrapper>();

  /// Runs [run] with the iPhone [deviceId]'s test traffic routed through this
  /// Mac, passing the env additions the run needs. When routing cannot be set
  /// up, [run] still runs (with no additions) after a warning.
  Future<T> around<T>(String deviceId, Future<T> Function(Map<String, String> env) run) async {
    final setup = await phoneSetup(deviceId);
    if (setup.missing != null) {
      return _unrouted(deviceId, run, setup.missing!);
    }
    final proxy = setup.proxy();
    try {
      await proxy.start();
    } on SocketException catch (error) {
      return _unrouted(deviceId, run, 'port ${setup.port} on this Mac (${error.osError?.message ?? error.message})');
    }
    _logger.info(
      '[device-egress] iPhone $deviceId (${setup.phoneAddresses.join(', ')}) test traffic -> this Mac. One-time '
      'phone setup: Settings > Wi-Fi > (i) > Configure Proxy > Automatic, URL '
      '${setup.pacUrl}',
    );
    try {
      return await run(const {e2eDeviceProxyEnv: 'true'});
    } finally {
      await proxy.close();
      _report(deviceId, proxy, setup.pacUrl);
    }
  }

  /// What the iPhone [deviceId] needs for routing: the one-time proxy URL and
  /// the addresses the proxy accepts, or why routing is not possible
  /// ([IosPhoneSetup.missing]).
  Future<IosPhoneSetup> phoneSetup(String deviceId) async {
    final port = int.tryParse(_platform.environment[iosDeviceProxyPortEnv] ?? '') ?? defaultPort;
    final macHost = await _macBonjourName() ?? await _platform.localNetworkHost();
    final phoneAddresses = await _phoneAddresses(deviceId);
    if (macHost == null || phoneAddresses == null) {
      return IosPhoneSetup.missing(macHost == null ? "this Mac's Wi-Fi address" : "the iPhone's Wi-Fi address");
    }
    return IosPhoneSetup(macHost: macHost, port: port, phoneAddresses: phoneAddresses);
  }

  /// Checks that the iPhone [deviceId] already sends Example traffic through
  /// this Mac: serves the proxy, opens [probeUrl] in Safari on the phone with
  /// `devicectl`, and waits up to [timeout] for that traffic. The phone must be
  /// unlocked. Returns the hosts that arrived (empty when the phone is not set
  /// up) and the addresses refused.
  Future<IosRouteCheck> verifyRoute(IosPhoneSetup setup, String deviceId,
      {Duration timeout = const Duration(seconds: 45)}) async {
    final proxy = setup.proxy();
    try {
      await proxy.start();
    } on SocketException catch (error) {
      return IosRouteCheck(
          problem: 'port ${setup.port} is in use on this Mac (${error.osError?.message ?? error.message})');
    }
    try {
      final launch = await _shell.runArgs(
        'xcrun',
        [
          'devicectl',
          'device',
          'process',
          'launch',
          '--device',
          deviceId,
          '--payload-url',
          probeUrl,
          'com.apple.mobilesafari'
        ],
        throwOnError: false,
        silent: true,
      );
      if (launch.exitCode != 0) {
        return IosRouteCheck(problem: 'could not open Safari on the phone (is it unlocked?)');
      }
      final sleep = getDep<SleepFunction>();
      for (var waited = Duration.zero; waited < timeout && proxy.hosts.isEmpty; waited += _routePollDelay) {
        await sleep(_routePollDelay);
      }
      return IosRouteCheck(hosts: {...proxy.hosts}, refused: {...proxy.refusedPeers});
    } finally {
      await proxy.close();
    }
  }

  /// Page the route check opens on the phone (`network.probe-url`); it must be on a [proxiedDomains] host.
  static String get probeUrl => getDep<MplatrolConfig>().network.probeUrl;

  static const _routePollDelay = Duration(seconds: 1);

  /// The PAC script: [proxiedDomains] through [proxy] (`host:port`), falling back
  /// to a direct connection; everything else direct. Without domains every host goes through [proxy].
  static String pacScript(String proxy) {
    final domains = proxiedDomains;
    if (domains.isEmpty) {
      return 'function FindProxyForURL(url, host) {\n'
          '  return "PROXY $proxy; DIRECT";\n'
          '}\n';
    }
    final matches = domains.map((domain) => 'dnsDomainIs(host, "$domain")').join(' || ');
    return 'function FindProxyForURL(url, host) {\n'
        '  if ($matches) return "PROXY $proxy; DIRECT";\n'
        '  return "DIRECT";\n'
        '}\n';
  }

  Future<T> _unrouted<T>(String deviceId, Future<T> Function(Map<String, String> env) run, String missing) {
    _logger.warn(
      '[device-egress] could not route iPhone $deviceId through this Mac (no $missing); the phone uses its own '
      'network, which test environments may refuse ("Unauthorized network location").',
    );
    return run(const {});
  }

  void _report(String deviceId, DeviceEgressProxy proxy, String pacUrl) {
    if (proxy.hosts.isNotEmpty) {
      _logger.info('[device-egress] iPhone $deviceId reached ${proxy.hosts.length} host(s) through this Mac.');
      return;
    }
    final refused = proxy.refusedPeers.isEmpty ? '' : ' Refused connections from ${proxy.refusedPeers.join(', ')}.';
    _logger.warn(
      '[device-egress] iPhone $deviceId sent no traffic through this Mac. If the app started on the phone, set its '
      'Wi-Fi proxy to Automatic with URL $pacUrl; if the run failed before that (build or signing), this is '
      'expected.$refused',
    );
  }

  /// The phone's current addresses, its Wi-Fi IPv4 first: its CoreDevice host
  /// name (`<name>.coredevice.local`) is also advertised over Bonjour as
  /// `<name>.local`. All of them are allowed: the phone may reach the Mac's
  /// `.local` name over IPv6 or over its link-local USB/peer link (169.254/16),
  /// and it did try the link-local one first on 2026-10-02. Null when the phone
  /// has no Wi-Fi IPv4 address (not on Wi-Fi).
  Future<Set<String>?> _phoneAddresses(String deviceId) async {
    final hostname = await _coreDeviceHostname(deviceId);
    if (hostname == null) {
      return null;
    }
    final bonjour = hostname.replaceFirst(RegExp(r'\.coredevice\.local$'), '.local');
    final addresses = await _lookup(bonjour);
    final ipv4 = [
      for (final address in addresses)
        if (!address.contains(':') && !address.startsWith('169.254.')) address
    ];
    if (ipv4.isEmpty) {
      return null;
    }
    return {...ipv4, for (final address in addresses) normalizePeerAddress(address)};
  }

  /// This Mac's Bonjour name (`<LocalHostName>.local`), stable across Wi-Fi
  /// address changes; null when it has none.
  Future<String?> _macBonjourName() async {
    final result = await _shell.runArgs('scutil', ['--get', 'LocalHostName'], throwOnError: false, silent: true);
    final name = '${result.stdout}'.trim();
    return result.exitCode == 0 && name.isNotEmpty ? '$name.local' : null;
  }

  Future<String?> _coreDeviceHostname(String deviceId) async {
    final scratch = Directory.systemTemp.createTempSync('mplatrol_devicectl_');
    try {
      final json = p.join(scratch.path, 'device.json');
      final result = await _shell.runArgs(
        'xcrun',
        ['devicectl', 'device', 'info', 'details', '--device', deviceId, '--json-output', json],
        throwOnError: false,
        silent: true,
      );
      if (result.exitCode != 0 || !File(json).existsSync()) {
        return null;
      }
      final names = _localHostnames(jsonDecode(File(json).readAsStringSync()));
      final uuidName = RegExp(r'^[0-9A-Fa-f-]{25,}\.coredevice\.local$');
      return names?.whereType<String>().where((name) => !uuidName.hasMatch(name)).firstOrNull;
    } on FormatException {
      return null;
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  /// `result.connectionProperties.localHostnames` from `devicectl` JSON.
  static List<Object?>? _localHostnames(Object? decoded) {
    final result = decoded is Map ? decoded['result'] : null;
    final connection = result is Map ? result['connectionProperties'] : null;
    final names = connection is Map ? connection['localHostnames'] : null;
    return names is List ? names : null;
  }

  static Future<List<String>> _systemLookup(String host) async {
    try {
      final addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      // A successful answer needs a live Bonjour responder (the phone); the live iPhone run covers it.
      return [for (final address in addresses) address.address]; // coverage:ignore-line
      // Not resolvable (SocketException) or no Bonjour answer (TimeoutException):
      // either way the phone's Wi-Fi address is unknown.
    } on Exception {
      return const [];
    }
  }
}

/// The one-time proxy setting for a physical iPhone and what the proxy accepts.
class IosPhoneSetup {
  /// Routing for a phone at [phoneAddresses] through this Mac ([macHost]:[port]).
  IosPhoneSetup({required String macHost, required this.port, required this.phoneAddresses})
      : _macHost = macHost,
        missing = null;

  /// Routing is not possible because there is no [missing].
  IosPhoneSetup.missing(this.missing)
      : _macHost = '',
        port = 0,
        phoneAddresses = const {};

  final String _macHost;

  /// Why routing is not possible (for example no Wi-Fi address), or null.
  final String? missing;

  /// Port the proxy listens on.
  final int port;

  /// The phone's current addresses, all accepted by the proxy.
  final Set<String> phoneAddresses;

  /// The URL to enter on the phone: Settings > Wi-Fi > (i) > Configure Proxy > Automatic.
  String get pacUrl => 'http://$_macHost:$port/proxy.pac';

  /// A proxy that serves this setup's PAC file and accepts only the phone.
  DeviceEgressProxy proxy() => DeviceEgressProxy(
        bindAddress: InternetAddress.anyIPv6,
        port: port,
        allowedPeers: phoneAddresses,
        pac: IosDeviceEgress.pacScript('$_macHost:$port'),
      );
}

/// The result of [IosDeviceEgress.verifyRoute].
class IosRouteCheck {
  /// Creates a result; [problem] is set when the check itself could not run.
  IosRouteCheck({this.hosts = const {}, this.refused = const {}, this.problem});

  /// Proxied hosts the phone reached through this Mac.
  final Set<String> hosts;

  /// Addresses the proxy refused (not the phone).
  final Set<String> refused;

  /// Why the check could not run, or null.
  final String? problem;

  /// Whether the phone's proxied traffic went through this Mac.
  bool get routed => problem == null && hosts.isNotEmpty;
}
