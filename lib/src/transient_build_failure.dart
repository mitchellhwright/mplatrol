/// Substrings that mark a transient Gradle/Maven dependency-resolution failure
/// (a flapping repo, dropped artifact download, a proxy-feed gateway timeout)
/// rather than a real compile or test failure — safe to retry the build for. A
/// flaky tenant Maven fetch (e.g. the Adobe SDK proxy feed) disables the repo for
/// the rest of that build and fails the whole run, but the next attempt can
/// resolve cleanly.
///
/// These are deliberately Gradle/Maven build-phase phrasings only. Generic
/// network phrases ("Connection timed out", "Connection reset") are excluded:
/// `patrol test` output also contains the TEST phase, where a flaky staging
/// request would emit those — retrying the whole build+suite for a test-phase
/// blip would waste CI time and mask a real test failure.
const transientBuildFailureMarkers = <String>[
  'Repository maven2 is disabled due to earlier error',
  'Failed to list versions for',
  'Could not resolve all files for configuration',
  "Could not GET '",
  "Could not HEAD '",
  'Could not download ',
];

/// Whether [output] (combined build stdout+stderr) contains any
/// [transientBuildFailureMarkers], i.e. the build failed on a transient
/// dependency/network error worth retrying.
bool isTransientBuildFailure(String output) => transientBuildFailureMarkers.any(output.contains);
