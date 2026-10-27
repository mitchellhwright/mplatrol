import 'dart:io';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:mplatrol/src/patrol_sdk_selection.dart';
import 'package:mplatrol/src/patrol_test_discovery.dart';
import 'package:mplatrol/src/test_order.dart';
import 'package:mplatrol/src/write_if_changed.dart';
import 'package:path/path.dart' as p;

/// Generates the Android Patrol runner classes so their `@Test` methods track
/// Patrol `*_test.dart` files automatically — the COUNT, the NAMES, and the
/// CLASS each test is grouped under. The iOS counterpart is
/// [generateIosPatrolRunner].
///
/// Layout: one `public class <fileBasename> extends PatrolDartTest` per dart
/// test file (so the LambdaTest/JUnit report groups each file's tests under that
/// file's name, not a single `MainActivityTest`), plus the shared abstract
/// `PatrolDartTest` base.
///
/// Why generate concrete classes (vs. patrol's stock `@RunWith(Parameterized)`
/// runner): LambdaTest extracts `@Test` methods STATICALLY from the
/// instrumentation `.dex` before launching, so a runner that builds its cases at
/// runtime from `listDartTests()` yields zero cases on LT. The methods must be
/// CONCRETE, and LT shards one device session per `@Test` method.
///
/// Each method runs its Dart test by RESOLVING the full name at runtime: it
/// matches the file group + the `patrolTest` description against
/// `listDartTests()` (the listed name ends with the description), so enclosing
/// `group('...')` calls and mplatrol's filtered target wrapper are handled without
/// source parsing.
/// [target] restricts generation to one Patrol `*_test.dart` file.
/// Returns the total number of `@Test` methods generated.
/// Env var overriding the per-`@Test` JUnit timeout in milliseconds. The
/// default (240s) can be exceeded by the first (cold-start) test on a slow
/// local emulator — set this higher (e.g. 600000) for local runs.
const e2eTestTimeoutMsEnv = 'MPLATROL_E2E_TEST_TIMEOUT_MS';
const _defaultTestTimeoutMs = 240000;

/// Env var that keeps app data between a local Android run's tests.
///
/// `1` or `true` writes `clearPackageData: "false"`: the orchestrator still
/// starts every `@Test` in a new app process, but app data survives, so a later
/// test (in name order) can cold-start from the state an earlier test left.
const e2eKeepAppDataEnv = 'MPLATROL_E2E_KEEP_APP_DATA';

/// Whether [env] asks to keep app data between tests ([e2eKeepAppDataEnv]).
bool resolveAndroidKeepAppData(Map<String, String>? env) {
  final value = (env?[e2eKeepAppDataEnv] ?? '').trim().toLowerCase();
  return value == '1' || value == 'true';
}

/// Returns the identity of canonical compiled Android runner output.
///
/// Args:
///   env: Build environment containing the compiled JUnit test timeout.
String androidPatrolGeneratorIdentity({Map<String, String>? env}) {
  final file = PatrolTestFile(basename: 'identity_test', tests: [
    PatrolTest(method: 'testIdentity', description: 'identity journey'),
  ]);
  return (FingerprintBuilder()
        ..addString(_renderBase())
        ..addString(_renderTestOrder())
        ..addString(_renderTestClass(file, resolveAndroidTestTimeoutMs(env)))
        ..addString(_renderTestClass(file, resolveAndroidTestTimeoutMs(env), realPermissionDialogs: true)))
      .finish();
}

/// Resolves the per-test timeout from [env] ([e2eTestTimeoutMsEnv]), falling
/// back to [_defaultTestTimeoutMs] when unset or non-positive.
int resolveAndroidTestTimeoutMs(Map<String, String>? env) {
  final parsed = int.tryParse((env?[e2eTestTimeoutMsEnv] ?? '').trim()) ?? 0;
  return parsed > 0 ? parsed : _defaultTestTimeoutMs;
}

/// Generates concrete Android runners for discovered or explicitly selected tests.
///
/// Returns the total number of generated test methods.
int generateAndroidPatrolRunner(String repo,
    {String? target,
    String? targetRegex,
    String? sdk,
    PatrolSelectionPlan? selection,
    String patrolRunner = androidPatrolRunner,
    Map<String, String>? env}) {
  final files = discoverPatrolTestFiles(
    repo,
    target: target,
    targetRegex: targetRegex,
    sdk: sdk,
    selection: selection,
    environment: env,
  );
  if (files.isEmpty) {
    throw StateError(
      'No patrolTest() found in ${target ?? patrolTestDirectoryPath(repo)} '
      '${targetRegex == null ? '' : 'matching /$targetRegex/ '}'
      '${sdk == null ? '' : 'for SDK "$sdk" '}— '
      'nothing to generate. Patrol runner left unchanged.',
    );
  }
  _rejectDuplicateManualTests(repo, files);
  final timeoutMs = resolveAndroidTestTimeoutMs(env);
  final realPermissionDialogs = patrolRealPermissionDialogFiles(repo);
  final keepAppData = resolveAndroidKeepAppData(env);
  ensureAndroidPatrolGradleConfig(repo, patrolRunner: patrolRunner, clearPackageData: !keepAppData);
  final dir = Directory(p.join(repo, _runnerDir))..createSync(recursive: true);
  _deleteStaleGenerated(dir);
  writeIfChanged(File(p.join(dir.path, 'PatrolDartTest.java')), _renderBase());
  writeIfChanged(File(p.join(dir.path, '$_testOrderClass.java')), _renderTestOrder());
  for (final file in files) {
    writeIfChanged(
        File(p.join(dir.path, '${androidPatrolTestClassName(file.basename)}.java')),
        _renderTestClass(file, timeoutMs,
            realPermissionDialogs: realPermissionDialogs.contains(file.basename), nameOrder: keepAppData));
  }
  return files.fold(0, (sum, file) => sum + file.tests.length);
}

void _rejectDuplicateManualTests(String repo, List<PatrolTestFile> files) {
  final root = Directory(p.join(repo, 'android', 'app', 'src', 'androidTest'));
  if (!root.existsSync()) {
    return;
  }
  final groups = files.map((file) => file.basename).toSet();
  for (final entry in root.listSync(recursive: true, followLinks: false)) {
    if (entry is! File || !entry.path.endsWith('.java')) {
      continue;
    }
    final source = entry.readAsStringSync();
    if (source.startsWith(_marker) || !source.contains('extends PatrolDartTest')) {
      continue;
    }
    final group = RegExp(r'dartFileGroup\(\)\s*\{\s*return\s+"([^"]+)"').firstMatch(source)?.group(1);
    if (groups.contains(group) && source.contains('@Test')) {
      throw FormatException('Handwritten ${p.relative(entry.path, from: repo)} '
          'duplicates selected Dart group $group. Remove the legacy duplicate '
          'or select a different group before generating cloud shards.');
    }
  }
}

/// The Java package of the generated Android test classes, owned by mplatrol and separate from the app's own.
const androidPatrolTestPackage = 'mplatrol.e2e';

const _runnerDir = 'android/app/src/androidTest/java/mplatrol/e2e';
const androidPatrolRunner = 'pl.leancode.patrol.PatrolJUnitRunner';
const androidLambdaTestPatrolRunner = 'pl.leancode.patrol.LambdaTestPatrolJUnitRunner';
const _orchestratorDependency = 'androidx.test:orchestrator:1.5.1';

/// First line of every file this generator writes — used to recognise (and so
/// clean up) previously generated classes without touching hand-written files
/// in the same directory.
const _marker = '// GENERATED by `mplatrol`';

/// Reads the app's literal application ID (after the prepare step) before building Patrol.
///
/// Throws [FormatException] when the package cannot be resolved, preventing Patrol
/// from silently targeting the pubspec package.
String androidPatrolPackageName(String repo) {
  final file = File(p.join(repo, 'android', 'app', 'build.gradle'));
  final source = file.existsSync() ? file.readAsStringSync() : '';
  final match = RegExp(
    r'''^\s*applicationId\s*(?:=\s*)?["']([A-Za-z][A-Za-z0-9_.]*)["']''',
    multiLine: true,
  ).firstMatch(source);
  if (match == null) {
    throw const FormatException('Cannot resolve the Android applicationId from '
        'android/app/build.gradle. Set a literal applicationId (or let the prepare command write one).');
  }
  return match.group(1)!;
}

/// Ensures the generated Android JUnit test classes are launched through
/// Patrol's instrumentation runner. A prepare step may rewrite `android/app/build.gradle`,
/// so this must be idempotently restored every time the runner is generated.
/// [clearPackageData] false keeps app data between orchestrated tests.
void ensureAndroidPatrolGradleConfig(String repo,
    {String patrolRunner = androidPatrolRunner, bool clearPackageData = true}) {
  final file = File(p.join(repo, 'android', 'app', 'build.gradle'));
  if (!file.existsSync()) {
    return;
  }

  var content = file.readAsStringSync();
  content = _ensureDefaultConfigLine(
    content,
    RegExp(r"""^[ \t]*testInstrumentationRunner[ \t]+["'][^"']+["'][ \t]*$""", multiLine: true),
    'testInstrumentationRunner "$patrolRunner"',
  );
  content = _ensureDefaultConfigLine(
    content,
    RegExp(r"""^[ \t]*testInstrumentationRunnerArguments[ \t]+clearPackageData:\s*["'](?:true|false)["'][^\n]*$""",
        multiLine: true),
    'testInstrumentationRunnerArguments clearPackageData: "$clearPackageData", '
    '$androidTestOrderArgument: (System.getenv("$testOrderEnv") ?: "$testOrderDeclared")',
  );
  content = _ensureLambdaTestAbiFilter(content, enabled: patrolRunner == androidLambdaTestPatrolRunner);
  content = _ensureAndroidTestOptionsExecution(content);
  content = _ensureDependencyLine(content, 'androidTestUtil "$_orchestratorDependency"');
  content = _ensureVersionedManifestExclusion(content);
  writeIfChanged(file, content);
}

String _ensureVersionedManifestExclusion(String content) {
  const manifest = 'META-INF/versions/9/OSGI-INF/MANIFEST.MF';
  if (content.contains(manifest)) {
    return content;
  }
  final packaging = RegExp(r'packagingOptions\s*\{').firstMatch(content);
  const rule = '\n        exclude "$manifest"';
  if (packaging != null) {
    return content.replaceRange(packaging.end, packaging.end, rule);
  }
  return content.replaceFirst(
    RegExp(r'android\s*\{'),
    'android {\n    packagingOptions {$rule\n    }',
  );
}

final _lambdaTestAbiFilterLine = RegExp(r"""^\s*ndk\.abiFilters\s+["']arm64-v8a["']\s*$""", multiLine: true);
final _lambdaTestAbiFilterLineWithBreak =
    RegExp(r"""^[ \t]*ndk\.abiFilters\s+["']arm64-v8a["'][ \t]*\n""", multiLine: true);

/// LambdaTest's real Android devices are all arm64, so LambdaTest builds keep
/// only that ABI: every plugin ships native libraries for arm, arm64 and x86_64,
/// and dropping the unused two removes about a third of the debug APK uploaded
/// on each run. Local builds remove the filter again, since local emulators may
/// be x86_64.
String _ensureLambdaTestAbiFilter(String content, {required bool enabled}) {
  if (enabled) {
    return _ensureDefaultConfigLine(content, _lambdaTestAbiFilterLine, "ndk.abiFilters 'arm64-v8a'");
  }
  return content.replaceAll(_lambdaTestAbiFilterLineWithBreak, '');
}

String _ensureDefaultConfigLine(String content, RegExp existingLine, String desiredLine) {
  final range = _namedBlockRange(content, 'defaultConfig');
  if (range == null) {
    return content;
  }
  final block = content.substring(range.start, range.end);
  final indent = _childIndent(block);
  final desired = '$indent$desiredLine';
  if (existingLine.hasMatch(block)) {
    final updatedBlock = block.replaceFirst(existingLine, desired);
    return content.replaceRange(range.start, range.end, updatedBlock);
  }
  final insertAt = _closingLineStart(content, range.end - 1);
  return content.replaceRange(insertAt, insertAt, '$desired\n');
}

String _ensureAndroidTestOptionsExecution(String content) {
  final androidRange = _namedBlockRange(content, 'android');
  if (androidRange == null) {
    return content;
  }
  final androidBlock = content.substring(androidRange.start, androidRange.end);
  final existingTestOptions = _namedBlockRange(androidBlock, 'testOptions');
  if (existingTestOptions != null) {
    final testOptionsBlock = androidBlock.substring(existingTestOptions.start, existingTestOptions.end);
    final executionLine = RegExp(r"""^\s*execution\s+["']ANDROIDX_TEST_ORCHESTRATOR["']\s*$""", multiLine: true);
    if (executionLine.hasMatch(testOptionsBlock)) {
      return content;
    }
    final indent = _childIndent(testOptionsBlock);
    final insertAt = _closingLineStart(testOptionsBlock, existingTestOptions.end - existingTestOptions.start - 1);
    final updatedTestOptionsBlock = testOptionsBlock.replaceRange(
      insertAt,
      insertAt,
      '${indent}execution "ANDROIDX_TEST_ORCHESTRATOR"\n',
    );
    final updatedAndroidBlock = androidBlock.replaceRange(
      existingTestOptions.start,
      existingTestOptions.end,
      updatedTestOptionsBlock,
    );
    return content.replaceRange(androidRange.start, androidRange.end, updatedAndroidBlock);
  }

  final indent = _childIndent(androidBlock);
  final child = '$indent    ';
  final testOptionsBlock = '$indent'
      'testOptions {\n'
      '${child}execution "ANDROIDX_TEST_ORCHESTRATOR"\n'
      '$indent}\n';
  final insertAt = _closingLineStart(content, androidRange.end - 1);
  return content.replaceRange(insertAt, insertAt, testOptionsBlock);
}

String _ensureDependencyLine(String content, String desiredLine) {
  final existingLine = RegExp(
    r"""^\s*androidTestUtil\s+["']androidx\.test:orchestrator:[^"']+["'][ \t]*$""",
    multiLine: true,
  );
  if (existingLine.hasMatch(content)) {
    return content.replaceFirst(existingLine, '    $desiredLine');
  }
  final dependenciesRange = _namedBlockRange(content, 'dependencies');
  if (dependenciesRange == null) {
    return content;
  }
  final block = content.substring(dependenciesRange.start, dependenciesRange.end);
  final indent = _childIndent(block);
  final insertAt = _closingLineStart(content, dependenciesRange.end - 1);
  return content.replaceRange(insertAt, insertAt, '$indent$desiredLine\n');
}

({int start, int end})? _namedBlockRange(String content, String name) {
  final match = RegExp('\\b$name\\s*\\{').firstMatch(content);
  if (match == null) {
    return null;
  }
  final openBrace = content.indexOf('{', match.start);
  var depth = 0;
  for (var index = openBrace; index < content.length; index++) {
    final char = content[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return (start: match.start, end: index + 1);
      }
    }
  }
  return null;
}

String _childIndent(String block) {
  final closingIndent = RegExp(r'\n([ \t]*)}\s*$').firstMatch(block)?.group(1) ?? '';
  return '$closingIndent    ';
}

int _closingLineStart(String content, int closeBraceIndex) {
  final previousNewline = content.lastIndexOf('\n', closeBraceIndex);
  return previousNewline == -1 ? closeBraceIndex : previousNewline + 1;
}

/// Removes runner classes from a previous generation so renamed/removed dart
/// test files do not leave stale `.java` behind (which would still compile into
/// the dex and run an outdated test). Only files starting with [_marker] are
/// deleted; hand-written files are left untouched.
void _deleteStaleGenerated(Directory dir) {
  for (final entry in dir.listSync().whereType<File>()) {
    if (entry.path.endsWith('.java') && entry.readAsStringSync().startsWith(_marker)) {
      entry.deleteSync();
    }
  }
}

String _renderTestClass(PatrolTestFile file, int timeoutMs,
    {bool realPermissionDialogs = false, bool nameOrder = false}) {
  final className = androidPatrolTestClassName(file.basename);
  final methods = file.tests
      .map(
        (test) => '    @Test(timeout = $timeoutMs)\n'
            '    public void ${test.method}() throws ClassNotFoundException {\n'
            '        runDartTest("${_escapeJava(test.description)}");\n'
            '    }',
      )
      .join('\n\n');
  final pregrantOverride = realPermissionDialogs
      ? '''
    // $realPermissionDialogsKey in $patrolSdkRequirementsPath: this journey
    // drives the real location dialog, so nothing is pre-granted.
    @Override
    protected boolean pregrantLocation() {
        return false;
    }

'''
      : '';
  // Name order only for $e2eKeepAppDataEnv runs; every other run orders its
  // tests at runtime by the seeded list in $androidTestOrderArgument.
  final order = nameOrder
      ? '''
import org.junit.FixMethodOrder;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.JUnit4;
import org.junit.runners.MethodSorters;

// Name order: tests sharing app data ($e2eKeepAppDataEnv) build on earlier ones.
@RunWith(JUnit4.class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)'''
      : '''
import org.junit.Test;
import org.junit.runner.OrderWith;
import org.junit.runner.RunWith;
import org.junit.runners.JUnit4;

@RunWith(JUnit4.class)
@OrderWith($_testOrderClass.class)''';
  return '''$_marker — do not edit by hand. Regenerated to match
// $defaultPatrolTestDirectory/${file.basename}.dart on every `mplatrol` run, so the app
// gitignores it. See android_patrol_runner.dart.
package mplatrol.e2e;

$order
public class $className extends PatrolDartTest {
    @Override
    protected String dartFileGroup() {
        return "${file.basename}";
    }

$pregrantOverride$methods
}
''';
}

/// Native JUnit class generated for a Patrol test file.
String androidPatrolTestClassName(String basename) {
  final words = basename.split(RegExp('[^A-Za-z0-9]+')).where((word) => word.isNotEmpty);
  final buffer = StringBuffer();
  for (final word in words) {
    buffer.write(word[0].toUpperCase());
    if (word.length > 1) {
      buffer.write(word.substring(1));
    }
  }
  if (buffer.isEmpty) {
    return 'GeneratedTest';
  }
  final name = buffer.toString();
  return name.endsWith('Test') ? name : '${name}Test';
}

String _renderBase() => '''$_marker — do not edit by hand. See
// android_patrol_runner.dart.
//
// Base for the generated per-file Patrol test classes. Resolves each Dart test
// by matching its file group + description against listDartTests() at runtime,
// so enclosing group('...') calls and mplatrol's filtered target wrapper are
// handled automatically. The Android Test Orchestrator
// (build.gradle: ANDROIDX_TEST_ORCHESTRATOR +
// clearPackageData) runs each @Test in a fresh process; LambdaTest shards one
// device session per @Test method.
package mplatrol.e2e;

import static org.junit.Assert.assertTrue;

import android.util.Log;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.UiDevice;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import pl.leancode.patrol.Automator;
import pl.leancode.patrol.PatrolJUnitRunner;

public abstract class PatrolDartTest {
    // The only permissions ever pre-granted. LambdaTest's popup handler cannot
    // dismiss the post-login location dialog, which pauses the activity and
    // stalls Flutter frames. Journeys that test the dialog opt out through
    // pregrantLocation().
    private static final String[] LOCATION_PERMISSIONS = {
        "android.permission.ACCESS_FINE_LOCATION",
        "android.permission.ACCESS_COARSE_LOCATION",
    };

    private static Runnable installNativeDiagnostics(PatrolJUnitRunner instrumentation) {
        try {
            Class<?> observer = Class.forName(
                "mplatrol.e2e.NativeActivityDiagnostics");
            Object cleanup = observer.getMethod("install", android.app.Instrumentation.class)
                .invoke(null, instrumentation);
            if (!(cleanup instanceof Runnable)) {
                throw new IllegalStateException("Native diagnostics did not provide cleanup");
            }
            return (Runnable) cleanup;
        } catch (ClassNotFoundException absent) {
            Log.i("PatrolDartTest", "native-diagnostics-not-packaged");
            return () -> {};
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Native diagnostics installation failed", error);
        }
    }

    /** The dart file basename the subclass's tests are grouped under. */
    protected abstract String dartFileGroup();

    /** False for journeys that exercise the real location permission dialog. */
    protected boolean pregrantLocation() {
        return true;
    }

    // Reuses Patrol's UiDevice singleton; a second automation connection
    // would disconnect Patrol's automator.
    private static void grantLocation(
            PatrolJUnitRunner instrumentation, String appPackage) {
        UiDevice device = UiDevice.getInstance(instrumentation);
        for (String permission : LOCATION_PERMISSIONS) {
            try {
                String output = device.executeShellCommand(
                    "pm grant " + appPackage + " " + permission);
                Log.i("PatrolDartTest", "location-pregrant " + permission
                    + " output=" + output.trim());
            } catch (IOException error) {
                throw new IllegalStateException(
                    "Location pre-grant failed for " + permission, error);
            }
        }
    }

    protected void runDartTest(String description) throws ClassNotFoundException {
        PatrolJUnitRunner instrumentation =
            (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        String appPackage =
            instrumentation.getTargetContext().getPackageName();
        Class<?> mainActivity = Class.forName(appPackage + ".MainActivity");
        Runnable cleanup = installNativeDiagnostics(instrumentation);
        try {
            executeDartTest(instrumentation, appPackage, mainActivity, description);
        } finally {
            cleanup.run();
        }
    }

    private void executeDartTest(PatrolJUnitRunner instrumentation, String appPackage,
            Class<?> mainActivity, String description) {
        Automator.Companion.getInstance().initialize();
        if (pregrantLocation()) {
            grantLocation(instrumentation, appPackage);
        }
        instrumentation.setUp(mainActivity);
        instrumentation.waitForPatrolAppService();

        Object[] dartTests = instrumentation.listDartTests();
        String prefix = dartFileGroup() + " ";
        String groupToken = " " + dartFileGroup() + " ";
        String suffix = " " + description;
        List<String> matches = new ArrayList<>();
        for (Object dartTest : dartTests) {
            String name = (String) dartTest;
            boolean inFileGroup = name.startsWith(prefix)
                || name.contains(groupToken);
            if (inFileGroup && name.endsWith(suffix)) {
                matches.add(name);
            }
        }
        assertTrue("Expected exactly 1 Dart test in group '" + dartFileGroup()
            + "' ending with '" + description + "', found " + matches.size()
            + " — regenerate the runner (mplatrol). Listed: "
            + Arrays.toString(dartTests), matches.size() == 1);
        instrumentation.runDartTest(matches.get(0));
    }
}
''';

const _testOrderClass = 'MplatrolTestOrder';

String _renderTestOrder() => '''$_marker — do not edit by hand. See
// android_patrol_runner.dart and test_order.dart.
//
// Orders each generated class's tests by the comma-separated
// "<Class>.<method>" list in the $androidTestOrderArgument instrumentation
// argument (build.gradle fills it from $testOrderEnv, which `mplatrol run`
// sets from --seed). Tests it does not name keep their JUnit order after the
// named ones; without the argument nothing moves (LambdaTest, --order=declared).
package mplatrol.e2e;

import android.os.Bundle;
import androidx.test.platform.app.InstrumentationRegistry;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import org.junit.runner.Description;
import org.junit.runner.manipulation.Ordering;

public final class $_testOrderClass implements Ordering.Factory {
    @Override
    public Ordering create(Ordering.Context context) {
        Bundle arguments = InstrumentationRegistry.getArguments();
        String raw = arguments == null ? null : arguments.getString("$androidTestOrderArgument");
        final List<String> requested = Arrays.asList(raw == null ? new String[0] : raw.split(","));
        return new Ordering() {
            @Override
            protected List<Description> orderItems(Collection<Description> descriptions) {
                List<Description> ordered = new ArrayList<>(descriptions);
                Collections.sort(ordered, new Comparator<Description>() {
                    @Override
                    public int compare(Description left, Description right) {
                        return Integer.compare(rank(requested, left), rank(requested, right));
                    }
                });
                return ordered;
            }
        };
    }

    private static int rank(List<String> requested, Description description) {
        String className = description.getClassName();
        String key = className.substring(className.lastIndexOf('.') + 1) + "." + description.getMethodName();
        int index = requested.indexOf(key);
        return index < 0 ? Integer.MAX_VALUE : index;
    }
}
''';

/// Escapes [value] for a Java double-quoted string literal.
String _escapeJava(String value) => value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
