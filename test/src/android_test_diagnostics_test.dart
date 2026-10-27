import 'dart:io';

import 'package:mplatrol/src/android_test_diagnostics.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;
  late DateTime startedAt;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('android_utp_diagnostics');
    startedAt = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    ).subtract(const Duration(seconds: 10));
  });

  tearDown(() => repo.deleteSync(recursive: true));

  Future<List<String>> summarize() => AndroidTestDiagnostics().summarizeCurrentFailure(
        repo: repo.path,
        runStartedAt: startedAt,
      );

  File writeReport(
    String text, {
    String device = 'device',
    DateTime? modifiedAt,
  }) {
    final file = File(p.join(
      repo.path,
      'build/app/outputs/androidTest-results/connected/debug',
      device,
      'test-result.textproto',
    ))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text)
      ..setLastModifiedSync(
        modifiedAt ?? startedAt.add(const Duration(seconds: 1)),
      );
    return file;
  }

  const storageReport = '''
platform_error {
  error_detail {
    error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
    error_message: "Failed to install APK: INSTALL_FAILED_INSUFFICIENT_STORAGE"
  }
}
''';

  for (final (label, seconds, accepted) in [
    ('at attempt start', 0, true),
    ('current', 1, true),
    ('stale', -1, false),
    ('future', 3, false),
  ]) {
    test('shared report reader uses fixed timestamps: $label', () async {
      final attemptStart = DateTime.utc(2020);
      const text = 'INSTALL_FAILED_VERSION_DOWNGRADE';
      final report = writeReport(text, modifiedAt: attemptStart.add(Duration(seconds: seconds)));

      final result = await AndroidTestDiagnostics().readCurrentReport(
        report,
        runStartedAt: attemptStart,
        collectedAt: attemptStart.add(const Duration(seconds: 2)),
      );

      expect(result, accepted ? text : isNull);
    });
  }

  test('missing report directories produce no claimed cause', () async {
    expect(await summarize(), isEmpty);
  });

  test('current nested report yields storage cause and manual remediation', () async {
    writeReport(storageReport, device: 'device/results');
    final lines = await summarize();
    expect(lines, hasLength(2));
    expect(lines.first, contains('INSTALL_FAILED_INSUFFICIENT_STORAGE'));
    expect(lines.first, contains('Failed to install APK'));
    expect(lines.last, contains('Settings > Storage'));
    expect(lines.last, contains('Do not wipe the device automatically'));
  });

  test('stale report is not attributed to the current run', () async {
    writeReport(storageReport, modifiedAt: startedAt.subtract(const Duration(seconds: 1)));
    expect(await summarize(), isEmpty);
  });

  const nestedCauseReport = r'''
test_result {
  error_name: "UNRELATED_TEST_ERROR"
  error_message: "unrelated-test-details"
}
platform_error {
  errors {
    summary {
      error_name: "PLUGIN_ERROR"
      error_message: "Android APK installer plugin failed"
      namespace: "unrelated-namespace-details"
      metadata {
        error_name: "UNRELATED_METADATA_ERROR"
        error_message: "unrelated-metadata-details"
      }
    }
    cause {
      summary {
        error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
        error_message: "Failed to install APK: INSTALL_FAILED_INSUFFICIENT_STORAGE\nprivate-install-stack"
      }
      cause {
        summary {
          error_message: "anonymous-cause-details token=private-anonymous-token"
        }
      }
    }
  }
}
''';

  test('realistic nested UTP summaries report storage cause without unrelated fields', () async {
    writeReport(nestedCauseReport, device: 'Pixel_9(AVD) - 16');

    final lines = await summarize();
    final output = lines.join('\n');

    expect(lines, hasLength(3));
    expect(lines.first, '[android-utp] PLUGIN_ERROR: Android APK installer plugin failed');
    expect(lines[1], startsWith('[android-utp] INSTALL_FAILED_INSUFFICIENT_STORAGE:'));
    expect(lines[1], contains('Failed to install APK'));
    expect(lines.last, contains('Settings > Storage'));
    for (final value in [
      'UNRELATED_TEST_ERROR',
      'unrelated-test-details',
      'unrelated-namespace-details',
      'UNRELATED_METADATA_ERROR',
      'unrelated-metadata-details',
      'private-install-stack',
      'anonymous-cause-details',
      'private-anonymous-token',
    ]) {
      expect(output, isNot(contains(value)));
    }
  });

  test('stale nested cause report is not attributed to the current run', () async {
    writeReport(nestedCauseReport, modifiedAt: startedAt.subtract(const Duration(seconds: 1)));
    expect(await summarize(), isEmpty);
  });

  test('duplicate fields within one summary remain malformed', () async {
    writeReport('''
platform_error {
  errors {
    summary {
      error_name: "PLUGIN_ERROR"
      error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
      error_message: "Ambiguous error"
    }
  }
}
''');
    expect(await summarize(), isEmpty);
  });

  test('sibling errors retain separate summaries without storage advice', () async {
    writeReport('''
platform_error {
  errors {
    summary {
      error_name: "DEVICE_CONNECTION_FAILED"
      error_message: "Device disconnected"
    }
  }
  errors {
    summary {
      error_name: "TEST_EXECUTION_FAILED"
      error_message: "Test execution failed"
    }
  }
}
''');
    expect(await summarize(), [
      '[android-utp] DEVICE_CONNECTION_FAILED: Device disconnected',
      '[android-utp] TEST_EXECUTION_FAILED: Test execution failed',
    ]);
  });

  test('report at the run-start threshold is current', () async {
    final file = writeReport(storageReport, modifiedAt: startedAt);
    startedAt = file.statSync().modified;
    expect(await summarize(), hasLength(2));
  });

  test('future-dated report cannot establish a current cause', () async {
    writeReport(storageReport, modifiedAt: DateTime.now().add(const Duration(hours: 1)));
    expect(await summarize(), isEmpty);
  });

  test('escaped summary is decoded without dumping later stack lines', () async {
    writeReport(r'''
platform_error {
  error_name: "DEVICE_CONNECTION_FAILED"
  error_message: "Device \"emulator\" disconnected\tunexpectedly\nstack trace private"
}
''');
    final lines = await summarize();
    const expected = '[android-utp] DEVICE_CONNECTION_FAILED: '
        'Device "emulator" disconnected unexpectedly';
    expect(lines, [expected]);
    expect(lines.join(), isNot(contains('stack trace')));
  });

  test('adjacent strings and protobuf numeric escapes are decoded', () async {
    writeReport(r'''
platform_error: <
  error_name: 'DEVICE_CONNECTION_FAILED'
  error_message: "Device\x20" "\145mulator\u0020lost"
>
''');
    expect(await summarize(), [
      '[android-utp] DEVICE_CONNECTION_FAILED: Device emulator lost',
    ]);
  });

  test('nonstorage error does not receive storage instructions', () async {
    writeReport('''
platform_error {
  error_name: "INSTALL_FAILED_UPDATE_INCOMPATIBLE"
  error_message: "Existing package signature does not match"
}
''');
    const expected = '[android-utp] INSTALL_FAILED_UPDATE_INCOMPATIBLE: '
        'Existing package signature does not match';
    expect(await summarize(), [expected]);
  });

  test('storage detail inside a generic platform error still gives remediation', () async {
    writeReport('''
platform_error {
  error_name: "INSTALL_APK_FAILED"
  error_message: "Install failed\\nINSTALL_FAILED_INSUFFICIENT_STORAGE"
}
''');
    expect((await summarize()).last, contains('Settings > Storage'));
  });

  test('malformed report is not presented as a current cause', () async {
    for (final text in [
      'platform_error { error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"',
      'platform_error { error_name: "INSTALL_FAILED" error_message: not_quoted }',
      'platform_error { error_name: "INSTALL_FAILED" error_message: "bad\\qescape" }',
      'platform_error { error_name: "INSTALL_FAILED" }',
      'platform_error { error_name: "INSTALL_FAILED" error_message: "" }',
    ]) {
      writeReport(text);
      expect(await summarize(), isEmpty);
    }
  });

  test('matching text outside platform_error is not a platform diagnosis', () async {
    writeReport('''
test_result {
  error_name: "INSTALL_FAILED_INSUFFICIENT_STORAGE"
  error_message: "Unrelated test text"
}
''');
    expect(await summarize(), isEmpty);
  });

  test('summary redacts credentials and URLs and remains a single bounded line', () async {
    writeReport('''
platform_error {
  error_name: "DEVICE_CONNECTION_FAILED"
  error_message: "Failed token=private-token password=private-password Bearer private-auth https://example.test/?token=private-query"
}
''');
    final text = (await summarize()).join('\n');
    expect(text, contains('token=[redacted]'));
    expect(text, contains('password=[redacted]'));
    expect(text, contains('Bearer [redacted]'));
    for (final value in ['private-token', 'private-password', 'private-auth', 'private-query']) {
      expect(text, isNot(contains(value)));
    }
    expect(text, isNot(contains('\n')));
  });

  test('duplicate reports produce one cause and one storage instruction', () async {
    writeReport(storageReport, device: 'first');
    writeReport(storageReport, device: 'second');
    expect(await summarize(), hasLength(2));
  });

  test('malformed UTF-8 and oversized reports are ignored', () async {
    final file = writeReport(storageReport);
    file
      ..writeAsBytesSync([0xff, 0xfe])
      ..setLastModifiedSync(startedAt.add(const Duration(seconds: 1)));
    expect(await summarize(), isEmpty);
    writeReport('x' * (256 * 1024 + 1));
    expect(await summarize(), isEmpty);
  });

  test('directory traversal is depth-bounded and does not follow symlinks', () async {
    writeReport(storageReport, device: List.filled(8, 'nested').join('/'));
    final outside = Directory(p.join(repo.path, 'outside'))..createSync();
    File(p.join(outside.path, 'test-result.textproto')).writeAsStringSync(storageReport);
    final root = p.join(
      repo.path,
      'build/app/outputs/androidTest-results/connected/debug',
    );
    Link(p.join(root, 'linked')).createSync(outside.path);
    expect(await summarize(), isEmpty);
  });

  test('long summaries and number of diagnoses are bounded', () async {
    final message = 'word ' * 100;
    for (var index = 0; index < 5; index++) {
      writeReport('''
platform_error {
  error_name: "ERROR_$index"
  error_message: "Failed $message"
}
''', device: 'device_$index');
    }
    final lines = await summarize();
    expect(lines, hasLength(3));
    expect(lines.every((line) => line.length < 300), isTrue);
    expect(lines.every((line) => line.endsWith('...')), isTrue);
  });
}
