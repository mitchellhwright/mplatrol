# mplatrol_harness

The in-app side of [`mplatrol`](../../README.md), the Patrol E2E orchestrator. Add it to a
Flutter app's dev dependencies and use it from `patrol_test/`:

- **Runtime credentials** — `E2eCredentialsClient` fetches the test login from
  the credential server `mplatrol` runs, so built apps never contain secrets.
  It also takes turns at sign-in with other device sessions that share a login
  (`acquireSignInSlot`) and frees the login when the test ends (`endSession`).
- **Runtime skips** — `skipTest(SkipCode, reason)` marks a test NOT RUN and
  prints the `MPLATROL_TEST_SKIPPED <CODE> <reason>` line `mplatrol` reads from
  the device log.
- **Native helpers** — deadline-bounded Patrol native queries
  (`nativeElementVisible`, `nativeWithinDeadline`), an OS permission dialog page
  object (`SystemPermissionDialogPage`), and a timer-driven dialog watchdog.
- **Small utilities** — `KeyedPageObject`, `visibleScreenText`, `pageLeafRoute`,
  `DelegatingHttpClientRequest`/`Response` for `HttpOverrides`,
  `WebViewErrorRetryPolicy`, `jsEscape`.

## Depend on it

```yaml
dev_dependencies:
  patrol: 4.10.0
  mplatrol_harness:
    path: ../mplatrol/packages/mplatrol_harness
    # or:
    # git:
    #   url: https://example.com/mplatrol.git
    #   path: packages/mplatrol_harness
```

`mplatrol` passes `E2E_CREDENTIALS_URL`, `E2E_ENVIRONMENT` and `E2E_TENANT` as
`--dart-define`s. To let a run reuse an already-built app, also bundle the
runtime config asset it writes:

```yaml
flutter:
  assets:
    - assets/mplatrol/e2e_runtime_config.json
```

## Use it

```dart
import 'package:mplatrol_harness/mplatrol_harness.dart';
import 'package:patrol/patrol.dart';

void main() {
  patrolTest('signs in', ($) async {
    final client = await E2eCredentialsClient.fromEnvironment();
    if (client == null) {
      skipTest(SkipCode.credentialsUnavailable, 'signs in: this build has no credential server');
      return;
    }
    client.endSessionAtTearDown();
    final login = await client.credentials();

    // ... open the sign-in screen and enter login.username ...
    final slot = await client.acquireSignInSlot();
    try {
      // ... enter login.password and login.oneTimeCode, submit ...
    } finally {
      await slot.release();
    }
  });
}
```

Apps add their own skip reasons with `const SkipCode('MY_CODE', 'What it means.')`;
a code is upper-case letters, digits and underscores, at least three characters.

## Develop

```sh
flutter pub get
flutter analyze
flutter test
```
