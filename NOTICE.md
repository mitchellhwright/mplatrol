# NOTICE

mplatrol originates from internal work done at Alkami Technology, Inc. The code in this repository was
extracted from that work and generalized (product names, hosts, credentials and internal integrations removed), and
is published with Alkami Technology, Inc.'s approval under the Apache License 2.0 in [LICENSE](LICENSE).

| Item | Status |
| --- | --- |
| Approval from Alkami Technology, Inc. | Granted (recorded 2026-10-27) |

## Third-party material

- `test/fixtures/patrol_*` hold excerpts of the [Patrol](https://github.com/leancodepl/patrol) sources (Copyright
  LeanCode, Apache License 2.0) that the patch tests apply mplatrol's Patrol patches to.
- `test/fixtures/android_patrol_diagnostics` and `test/fixtures/patrol_android_native_views/jvm` hold minimal
  stand-ins for Android and AndroidX APIs so the generated Java compiles in tests.
