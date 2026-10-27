# Scan report

Scan of this repository before its first commit (2026-10-27), to check that nothing proprietary, personal or
secret came over from the internal sources it was extracted from.

## Scope

Every file in the working tree (`lib/`, `bin/`, `test/` including `test/fixtures/`, `packages/mplatrol_harness/`,
`example/`, `.github/`, the Markdown files, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`,
`dart_test.yaml`), file names included. Generated folders (`.dart_tool/`, `build/`) are git-ignored and were not
committed. The history is new: no `.git` data was copied from the source repositories.

## Tools

- `gitleaks` and `trufflehog` are not installed on the machine, so neither ran.
- Instead, a Python secret scanner went over every text file. It checked for AWS access key ids, PEM private
  keys, GitHub, GitLab and Slack tokens, JWTs, Google API keys, LambdaTest-style keys, credentials embedded in
  URLs, `password/secret/token/api_key = "..."` assignments, and high-entropy strings (32 or more
  characters, Shannon entropy of 4.3 or more, mixed case plus digits).
- `rg -i` (ripgrep) checked contents and file names against a list of 57 terms. The list is kept outside this
  repository on purpose, because it names the source's customers and vendors. It covers:
  - the originating company's name, its product and internal platform names, and their API names;
  - every customer and tenant identifier that appeared in the source;
  - the demo user and environment names;
  - the vendor SDKs the source integrated;
  - its secret store, test-management, issue-tracker, wiki, chat and package-registry integrations, and its
    git host;
  - internal ticket-key formats and internal run names;
  - the tool's old name.
- The same checks searched for:
  - secret-store item ids and chat channel ids from the source;
  - the Apple Developer team id from the source;
  - LambdaTest user names and access keys from the source tests;
  - every hostname in an URL or string, which were then reviewed one by one.
- People's names: the author names and e-mail addresses of both source repositories (73 identities; 154
  name/e-mail tokens of four or more characters) were searched as whole words, case-insensitive. So were the
  names that appear in the source's internal notes.

## Changes made because of the scan

- **Removed entirely:**
  - the secret-store credential integration and its preflight;
  - test-management, issue-tracker and dashboard publishing, and bug drafting and filing;
  - the AI-pacing modules;
  - the white-label prepare pipeline;
  - the tenant/credential finder;
  - the adoption log;
  - the version-freshness check;
  - private plugin copies;
  - the build label;
  - the wiki publish warning;
  - tenant-specific SDK patches;
  - every lesson that described a defect in the source app or its vendors.
- **Replaced** with generic interfaces and configuration:
  - `CredentialProvider` (env and file providers);
  - `ResultSink` (JUnit and JSON sinks);
  - `prepare.command`;
  - `network.proxied-domains`;
  - `lambdatest.required-env`;
  - `coverage.packages`;
  - `CODESIGN_TEAM` (it replaced a hardcoded team id);
  - `MPLATROL_IOS_SIGNING_COMMAND` (it replaced the internal signing setup);
  - the `mplatrol.e2e` Java package for generated Android tests;
  - the `// BEGIN MPLATROL TAG:` registration markers.
- **Renamed** in tests and fixtures:
  - customer names became placeholder companies (`acme`, `globex`, `initech`, ...);
  - environments became `staging`, `qa`, `dev`, `uat`, `perf`;
  - vendor SDKs became generic names (`pinnedsdk`, `paysdk`, `depositsdk`, `chatsdk`, ...);
  - ticket keys became `PROJ-...`, hosts became `example.com`/`example.test`, and the team id became
    `TEAMID1234`.

## Remaining hits

| Hit | Where | Why it stays |
| --- | --- | --- |
| The originating company's name (4 lines) | `NOTICE.md` | Required: the notice states where the code comes from and that publishing needs written approval. |
| `fi` (case-insensitive word) | `Wi-Fi` in iOS proxy setup texts | The word Wi-Fi, not "financial institution". |
| `RELEASE-` (case-insensitive) | `Release-iphoneos` in `local_runner.dart` | The Xcode build-products folder name. |
| `slack`, `wiki` | this report | Generic words describing what was scanned and removed. |
| `lang` (matches a contributor's surname) | `java.lang.*`, `LANG` | Java package names and the locale variable, not a person. |
| `PRIVATE_AUTH_TOKEN`, `https://user:PRIVATE_AUTH_TOKEN@` | `test/src/lt_ios_runner_test.dart` | A placeholder the test uses to check that secrets are redacted from logs. |
| LambdaTest and Apple hosts (`*.lambdatest.com`, `api.hyperexecute.cloud`, `developer.apple.com`) | runners, tests | Public endpoints of the services the tool drives. |

The secret scanner reported no keys, tokens or private keys besides the placeholder above. Every high-entropy
hit was a code identifier, a path or a build setting.

The full scan ran again after project lessons were added and long lines were wrapped, with the same
results.

## Not covered

- The commit's author identity comes from the global git config, as requested. That identity is a work e-mail
  address, and it ends up in the commit metadata, not in any file.
- Behavioural names that describe generic mechanisms were kept, for example "tenant", "white-label" and
  "one-time code".
