# mplatrol

> **Not for publication yet.** See [NOTICE.md](NOTICE.md): this code may only be published once the written
> approval recorded there is granted.

`mplatrol` runs a Flutter app's [Patrol](https://patrol.leancode.co) end-to-end suite on local Android
emulators, iOS simulators and connected phones, and on LambdaTest real devices through HyperExecute, then tells
you what failed and why.

It is built for suites that run many times a day on many devices:

- **Variants**: `android`, `ios` (local), `lt-android`, `lt-ios` (LambdaTest), `all`, `lt-all`, and `auto`
  (the fastest available target per platform).
- **Device specs and leases**: local runs use one spec emulator (`mplatrol_e2e_pixel9`) and one spec
  simulator; machine-wide leases under `~/.mplatrol/` keep parallel runs off each other's devices.
- **LambdaTest**: one tunnel per job, app uploads with retries and a stall-based abort (an upload that stops
  making progress is cancelled instead of waiting for a timeout), a machine-wide session budget, per-user
  session caps, device pools (`Pixel 8-14|Galaxy S24-14`), iOS sharding through a local shard coordinator, and
  a per-user artifact cache so unchanged builds are not uploaded again.
- **Matrix rounds**: `mplatrol matrix` runs tenants x variants on a pool of lane checkouts, iOS and Android in
  parallel, with a disk guard, a stall watchdog, per-leg logs and JUnit, timings and publish hooks.
- **Failure classification**: every test ends in one category (`pass`, `app-defect`, `test-failure`,
  `cred-failure`, `<env>-env-failure`, `lt-tunnel-err`, `lt-failure`, `build-failure`, `test-data-failure`,
  `device-failure`, `framework-failure`, `not-run`, `not-verified`, `no-detail`, `not-selected`). Only
  `app-defect` and `test-failure` count as failed; known infrastructure failures are recognised from the run
  output (`TestLesson`) and printed with their fix.
- **Retries**: infrastructure retries (tunnel, framework setup, shard coordinator) are separate from test
  results, and a retried test is reported once, marked retried.
- **Reports**: console summary, JUnit XML and `summary.json` for every run, TeamCity service messages, and
  pluggable result sinks.
- **Runtime credentials**: test logins are served to the device at run time by a local credential server (never
  compiled into the app), with a user pool and a sign-in slot so parallel devices do not sign in as the same
  user at once.
- **Ordering**: tests run in a seeded random order by default; `--seed` reproduces a run.

The repository holds two packages:

| Path | What |
| --- | --- |
| `/` (`mplatrol`) | The Dart CLI and library. |
| [`packages/mplatrol_harness`](packages/mplatrol_harness) | A small Flutter library the app's Patrol tests use: runtime credentials client, sign-in slot, typed runtime skips, native dialog helpers. |

## Requirements

- macOS for iOS variants (Xcode with command line tools); macOS or Linux for Android.
- Flutter and the Android SDK (`adb`, `emulator`) on `PATH`.
- [fvm](https://fvm.app) activated globally (`dart pub global activate fvm`): local iOS runs and LambdaTest iOS
  builds run Flutter and the patched Patrol CLI through it.
- The Patrol CLI: `dart pub global activate patrol_cli`.
- For LambdaTest variants: a LambdaTest account (`LT_USERNAME`, `LT_ACCESS_KEY`), the HyperExecute CLI and the
  LambdaTest tunnel binary (see `mplatrol doctor`).

## Install

```sh
dart pub global activate --source path /path/to/mplatrol
mplatrol --help
```

or run it from a checkout with `dart run bin/mplatrol.dart`.

## The app under test

`mplatrol` works on a Flutter app with Patrol tests under `patrol_test/`:

```
my_app/
  pubspec.yaml          # dev_dependencies: patrol, mplatrol_harness
  mplatrol.yaml         # optional, see below
  patrol_test/
    app_test.dart
    sdk_requirements.json   # optional: which tests need which SDK/plugin
```

Generated files (`patrol_test/test_bundle.dart`, the Android runner classes under
`android/app/src/androidTest/java/mplatrol/e2e/`, `.mplatrol/`) belong in the app's `.gitignore`.

## Configuration: `mplatrol.yaml`

Every key is optional; `mplatrol` looks for `mplatrol.yaml` in the current folder and its parents
(`MPLATROL_CONFIG` names another file). A complete example is in
[`example/mplatrol.yaml`](example/mplatrol.yaml):

```yaml
prepare:
  command: ./tool/configure_tenant.sh "$MPLATROL_TENANT"   # optional white-label step
tenant: default
environment: staging
lambdatest:
  android-devices: ['Pixel 8-14|Galaxy S24-14']
  ios-devices: ['iPhone 15-17|iPhone 16-18']
  required-env: [PRIVATE_REGISTRY_TOKEN]
credentials:
  provider: env            # or: file
reporting:
  sinks:
    - type: junit
      path: build/mplatrol/junit.xml
```

**Tenants and environments.** A *tenant* is a white-label flavor of the app (use `default` for a single-flavor
app); an *environment* is the backend the tests run against. Both reach the app as the `E2E_TENANT` and
`E2E_ENVIRONMENT` dart-defines and the prepare command as `MPLATROL_TENANT` / `MPLATROL_ENVIRONMENT`.

**Prepare.** Before a tenant's builds, `mplatrol` runs `prepare.command` (if any) and then points `patrol` at a
patched private copy under `.mplatrol/patched_packages/patrol` (set `prepare.patch-patrol: false` to opt out).
The patches fix JSON-body native routes on Android, the LambdaTest loopback handshake, full iOS failure
details, native view queries, iOS text input, typed runtime skips and safe failure reports. The shared pub cache
is never edited.

## Quick start: local

```sh
cd my_app
mplatrol doctor                    # what is missing on this machine, and how to fix it
mplatrol devices --setup           # create the spec emulator and simulator
mplatrol run android               # the whole suite on the spec emulator
mplatrol run ios --target=patrol_test/app_test.dart
mplatrol run android --develop --target=patrol_test/app_test.dart   # hot-restart one test
mplatrol run android --coverage    # E2E line coverage (lcov + summary)
```

## Quick start: LambdaTest

```sh
export LT_USERNAME=... LT_ACCESS_KEY=...
mplatrol run lt-android
mplatrol run lt-ios --device='iPhone 16-18'
mplatrol run lt-all --tenant=acme,globex --environment=qa
```

Each LambdaTest leg builds the app, uploads it (reusing an earlier upload of the same build), opens a tunnel so
the devices reach this machine (and the credential server), runs one HyperExecute job per device spec and
collects per-test results, videos and logs. `mplatrol clean` stops leftover tunnels.

A round of many legs:

```sh
mplatrol matrix --run-dir=rounds/r1 --lane=../lane1/app --lane=../lane2/app \
  --tenant=acme --tenant=globex --variant=lt-ios --variant=lt-android \
  --publish='./tool/publish_results.sh {run}'
```

## Credentials

Tests sign in with logins the run serves at runtime: the harness's `E2eCredentialsClient` reads
`E2E_CREDENTIALS_URL` (a dart-define `mplatrol` sets) and fetches the login for its session.

Built-in providers (`credentials.provider`):

- `env` (default): `MPLATROL_CRED_USERNAME`, `MPLATROL_CRED_PASSWORD`, optional `MPLATROL_CRED_OTP`, then
  `MPLATROL_CRED_2_USERNAME`, ... for more users (parallel sessions get different users).
- `file`: a JSON file (default `.mplatrol/credentials.json`, keep it out of version control):

  ```json
  {"logins": [
    {"tenant": "acme", "environment": "staging", "username": "e2e-1", "password": "...", "otp": "123456",
     "userType": "business", "extra": {"ACCOUNT": "1234"}}
  ]}
  ```

To read logins from your own secret store, implement `CredentialProvider` and register it before the CLI runs:

```dart
import 'package:get_it/get_it.dart';
import 'package:mplatrol/mplatrol.dart';

class VaultCredentialProvider implements CredentialProvider {
  @override
  Future<List<TestLogin>> logins(CredentialRequest request) async {
    final secret = await myVault.read('e2e/${request.tenant}/${request.environment}');
    return [TestLogin(environment: request.environment, username: secret.user, password: secret.password)];
  }
}

Future<void> main(List<String> args) async {
  GetIt.I.registerSingleton<CredentialProvider>(VaultCredentialProvider());
  exitCode = await MplatrolCommandRunner().run(args);
}
```

With no login, the run continues and tells the suite to skip its sign-in journeys
(`MPLATROL_E2E_SKIP_HAPPY_LOGIN_TEST`).

## Result sinks

Every run writes JUnit XML and `summary.json` under `<app>/.mplatrol/reports/` (or `--junit=<path>`), plus each
`reporting.sinks` entry (`junit` or `json`). To publish results elsewhere (a dashboard, a test-management tool),
implement `ResultSink` and register it:

```dart
class DashboardSink implements ResultSink {
  @override
  String get name => 'dashboard';

  @override
  Future<String?> publish(RunReport report) async {
    await postToDashboard(report.renderSummary());
    return 'https://dashboard.example.com/runs/latest';
  }
}

GetIt.I.registerSingleton(ResultSinks([DashboardSink()]));
```

A sink that throws only logs a warning; reporting never changes a run's verdict or exit code.

## Failure lessons

When a run fails, `mplatrol` matches the output against its lessons: each one names a known failure, the
result category it counts as and the fix, which is printed as `lesson <name> (observed N): <remedy>`. The
built-in lessons cover LambdaTest, tunnels, emulators, simulators, signing, CocoaPods, Gradle and Patrol itself
(`TestLesson.builtIn`). Add your project's own lessons in `mplatrol.yaml`:

```yaml
lessons:
  - name: paymentsSandboxDown          # letters, digits and _; must not clash with a built-in lesson
    category: env-failure              # any result category except pass, not-run, not-verified, not-selected
    pattern: 'payments sandbox returned 50\d'   # regular expression, case-insensitive, `.` matches newlines
    symptom: The payments sandbox answers HTTP 5xx
    remedy: The sandbox is down; rerun when its status page is green.
```

or in code:

```dart
final sandboxDown = TestLesson.custom(
  name: 'paymentsSandboxDown',
  category: ItResultCategory.envFailure,
  symptom: 'The payments sandbox answers HTTP 5xx',
  remedy: 'The sandbox is down; rerun when its status page is green.',
  pattern: r'payments sandbox returned 50\d',
);
exitCode = await MplatrolCommandRunner(lessons: [sandboxDown]).run(args);
```

Project lessons are matched after the built-in ones, explain a leg's unfinished tests the same way, and are
counted in `.mplatrol/test_lessons.json`. An invalid lesson stops the run with exit code 78 and the reason.

## Runtime skips

A test that cannot run in this environment says why instead of passing:

```dart
import 'package:mplatrol_harness/mplatrol_harness.dart';

skipTest(SkipCode.featureNotConfigured, 'APP-TC-12 payments are off for this tenant');
```

It prints `MPLATROL_TEST_SKIPPED <CODE> <reason>`; `mplatrol` reports the test as NOT RUN with that reason,
never as a pass.

## App-upgrade tests

Mark a Patrol file with a `// mplatrol: upgrade-test` line. Normal runs leave it out. Run the setup leg on a
checkout of the previous release, then the verify leg on the current one, on the same device:

```sh
MPLATROL_E2E_UPGRADE_LEG=setup  mplatrol run android --device=emulator-5554   # tests named UPGRADE-SETUP ...
MPLATROL_E2E_UPGRADE_LEG=verify mplatrol run android --device=emulator-5554   # the other tests of those files
```

## Environment variables

| Variable | Purpose |
| --- | --- |
| `LT_USERNAME`, `LT_ACCESS_KEY` | LambdaTest credentials. |
| `LT_BIN`, `HYPEREXECUTE_BIN` | Paths to the LambdaTest tunnel and HyperExecute CLI. |
| `MPLATROL_CONFIG` | Config file to use instead of the nearest `mplatrol.yaml`. |
| `MPLATROL_E2E_ENVIRONMENT` | Default environment when `--environment` is not given. |
| `MPLATROL_LT_MAX_CONCURRENT_SESSIONS` | Machine-wide LambdaTest session budget (default 30). |
| `MPLATROL_LT_SESSIONS_PER_USER` | Most device sessions signing in as one user at once (default 4). |
| `MPLATROL_IOS_SIGNING_COMMAND` | Command that installs a provisioning profile for `$MPLATROL_BUNDLE_ID` (physical iPhones). |
| `CODESIGN_TEAM` | Apple Developer team id for signing. |
| `MPLATROL_E2E_FALLBACK_OTP` | One-time code served for logins without their own. |
| `MPLATROL_NON_INTERACTIVE` | Never prompt (also implied by `CI=true`). |

## Development

```sh
dart pub get
dart analyze
dart test                      # suites run one at a time (dart_test.yaml); two suites need a JDK 17
cd packages/mplatrol_harness && flutter test
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0, see [LICENSE](LICENSE), subject to [NOTICE.md](NOTICE.md).
