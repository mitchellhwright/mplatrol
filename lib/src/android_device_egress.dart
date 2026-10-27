import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:mplatrol/src/device_egress_proxy.dart';
import 'package:mplatrol/src/e2e_dart_defines.dart';

/// Routes a USB-connected Android phone's traffic through this Mac for one run.
///
/// Starts a [DeviceEgressProxy], maps its port onto the phone with
/// `adb reverse`, and points the phone's global HTTP proxy at it. The run's env
/// gains [e2eDeviceProxyEnv] so the build turns on the app's Developer Tools
/// proxy, which sends the app's own API calls through that system proxy too.
/// Afterwards the phone's previous proxy setting and the port mapping are
/// restored, whether the run passed, failed, or threw.
class AndroidDeviceEgress {
  MplatrolShell get _shell => getDep<MplatrolShell>();
  MplatrolLogger get _logger => getDep<MplatrolLogger>();

  /// Runs [run] with [deviceId]'s traffic routed through this Mac, passing the
  /// env additions the run needs. When routing cannot be set up, [run] still
  /// runs (with no additions) after a warning.
  Future<T> around<T>(String deviceId, Future<T> Function(Map<String, String> env) run) async {
    final proxy = DeviceEgressProxy();
    final port = await proxy.start();
    final previous = _withoutLeftoverRoute(deviceId, await _proxySetting(deviceId));
    if (previous == null || !await _route(deviceId, port)) {
      _logger.warn(
        '[device-egress] could not route $deviceId through this Mac; the phone uses its own network, '
        'which test environments may refuse ("Unauthorized network location").',
      );
      await proxy.close();
      return run(const {});
    }
    _logger.info('[device-egress] $deviceId traffic -> this Mac (adb reverse tcp:$port, phone proxy 127.0.0.1:$port)');
    try {
      return await run(const {e2eDeviceProxyEnv: 'true'});
    } finally {
      await _restore(deviceId, port, previous);
      await proxy.close();
      _logger.info(
        '[device-egress] restored $deviceId proxy; ${proxy.hosts.length} host(s) reached through this Mac'
        '${proxy.errors == 0 ? '' : ', ${proxy.errors} dropped connection(s)'}. If a run is killed before this '
        'point, the next run clears it, or run `adb -s $deviceId shell settings put global http_proxy :0`.',
      );
    }
  }

  /// [setting], or `null` when it is a loopback proxy left by an interrupted
  /// run: this class only ever sets `127.0.0.1:<port>`, and that address does
  /// nothing once its run's port mapping is gone, so it is cleared afterwards
  /// instead of restored.
  String? _withoutLeftoverRoute(String deviceId, String? setting) {
    if (setting == null || !setting.startsWith('127.0.0.1:')) {
      return setting;
    }
    _logger.warn(
        '[device-egress] $deviceId still had proxy $setting from an interrupted run; clearing it after this run.');
    return 'null';
  }

  /// The phone's current global proxy (`null` text when unset), or null when adb fails.
  Future<String?> _proxySetting(String deviceId) async {
    final result = await _adb(deviceId, ['shell', 'settings', 'get', 'global', 'http_proxy']);
    return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
  }

  Future<bool> _route(String deviceId, int port) async {
    final reverse = await _adb(deviceId, ['reverse', 'tcp:$port', 'tcp:$port']);
    if (reverse.exitCode != 0) {
      return false;
    }
    final proxy = await _adb(deviceId, ['shell', 'settings', 'put', 'global', 'http_proxy', '127.0.0.1:$port']);
    if (proxy.exitCode != 0) {
      await _adb(deviceId, ['reverse', '--remove', 'tcp:$port']);
      return false;
    }
    return true;
  }

  Future<void> _restore(String deviceId, int port, String previous) async {
    final unset = previous.isEmpty || previous == 'null' || previous == ':0';
    // `:0` is Android's documented way to clear the proxy immediately; deleting
    // the key afterwards leaves the setting as it was before the run.
    await _adb(deviceId, ['shell', 'settings', 'put', 'global', 'http_proxy', if (unset) ':0' else previous]);
    if (unset) {
      await _adb(deviceId, ['shell', 'settings', 'delete', 'global', 'http_proxy']);
    }
    await _adb(deviceId, ['reverse', '--remove', 'tcp:$port']);
  }

  Future<ProcessResultX> _adb(String deviceId, List<String> arguments) =>
      _shell.runArgs('adb', ['-s', deviceId, ...arguments], throwOnError: false, silent: true);
}
