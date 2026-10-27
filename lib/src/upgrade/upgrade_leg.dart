/// Env var naming the leg of an app-upgrade test a `mplatrol run` is: `setup` (run on a checkout of the previous
/// release; the app is reinstalled fresh) or `verify` (run on the current checkout, installed over the previous
/// release's app data). Unset for a normal run.
const e2eUpgradeLegEnv = 'MPLATROL_E2E_UPGRADE_LEG';

/// The `--dart-define` the leg reaches the app as.
const e2eUpgradeLegDefine = 'E2E_UPGRADE_LEG';

/// The line a Patrol test file starts with when its tests are app-upgrade tests: normal runs leave the file out,
/// and the two upgrade legs run only such files.
const upgradeFromMarker = '// mplatrol: upgrade-test';

/// The description prefix of the tests the setup leg runs on the previous release.
const upgradeSetupTestPrefix = 'UPGRADE-SETUP';

/// The two legs of an upgrade run.
enum UpgradeLeg {
  /// The previous release: sets up the state the upgrade must keep.
  setup,

  /// The current build installed over the previous release's app data.
  verify;

  /// The leg [env] names in [e2eUpgradeLegEnv], or null outside an upgrade leg.
  ///
  /// Throws:
  ///   StateError: [e2eUpgradeLegEnv] holds a value that is not a leg.
  static UpgradeLeg? fromEnv(Map<String, String> env) {
    final value = (env[e2eUpgradeLegEnv] ?? '').trim();
    if (value.isEmpty) {
      return null;
    }
    for (final leg in values) {
      if (leg.name == value) {
        return leg;
      }
    }
    throw StateError('$e2eUpgradeLegEnv is "$value"; expected ${values.map((leg) => leg.name).join(' or ')}.');
  }

  /// Whether this leg runs the test [description]: setup runs the [upgradeSetupTestPrefix] tests, verify the rest.
  bool runs(String description) => description.startsWith(upgradeSetupTestPrefix) == (this == setup);
}

/// Whether the Patrol test [source] declares that its tests are app-upgrade tests ([upgradeFromMarker]).
bool declaresUpgradeFrom(String source) {
  for (final line in source.split('\n')) {
    if (line.trim() == upgradeFromMarker) {
      return true;
    }
  }
  return false;
}
