# Contributing to mplatrol

Thanks for helping. These notes apply to everyone contributing to mplatrol.

## Setup

- Dart 3.11 or newer (the CI uses 3.11.4), Flutter 3.41 for `packages/mplatrol_harness`.
- JDK 17 for the two suites that compile the generated Android runner classes.

```sh
dart pub get
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed lib test bin
dart test
(cd packages/mplatrol_harness && flutter pub get && flutter analyze && flutter test)
```

`dart_test.yaml` runs suites one at a time: several suites bind local ports and check they are freed.

## Changes

- Keep commands thin: argument parsing and orchestration in `lib/src/commands/`, the work in services resolved
  through `getDep<T>()` so tests can replace them.
- Inject every process, file and network access (`MplatrolShell`, `FileSystem`, `PlatformWrapper`,
  `ProcessRunFunction`, `LtHttp`); tests never start real devices, builds or network calls.
- Wait on real events (process exit, file-system events, HTTP responses) rather than adding new sleeps or
  polling loops; where a remote API offers no event, bound the wait and say why in a comment.
- Every error says what failed, with which input, and how to fix it.
- Test behaviour, edges and every error path the code handles. A new `TestLesson` needs a real-looking evidence
  line in `test/src/test_lessons_test.dart`.
- No product, customer, host or person names, no credentials, and no internal ticket keys in code, tests,
  fixtures or docs. Use `acme`, `globex`, `example.com` / `example.test` and `PROJ-123` style keys.
- 120-character lines, absolute `package:` imports in `lib/`, Dartdoc on public APIs.

## Pull requests

Describe what the change does now, in plain words, and how you tested it (commands and results). Keep one
logical change per pull request.

## License

By contributing you agree that your contribution is licensed under the Apache License 2.0 ([LICENSE](LICENSE)).
