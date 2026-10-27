import 'package:flutter_test/flutter_test.dart';
import 'package:mplatrol_harness/mplatrol_harness.dart';

void main() {
  group('skipMarker', () {
    test('prefixes the message with the marker mplatrol reads', () {
      expect(
        skipMarker(SkipCode.credentialsUnavailable, 'login: no server'),
        'MPLATROL_TEST_SKIPPED CREDENTIALS_UNAVAILABLE login: no server',
      );
    });

    test('matches the pattern the CLI parses from the device log', () {
      final marker = skipMarker(SkipCode.deviceNoBiometrics, 'biometric sign-in');
      final parsed = RegExp(r'MPLATROL_TEST_SKIPPED ([A-Z][A-Z0-9_]{2,}[^\n]*)').firstMatch(marker);
      expect(parsed?.group(1), 'DEVICE_NO_BIOMETRICS biometric sign-in');
    });
  });

  group('skipMessage', () {
    test('collapses the reason onto one trimmed line', () {
      expect(skipMessage(SkipCode.testDataMissing, '  case-1:\n  no\t accounts \n'),
          'TEST_DATA_MISSING case-1: no accounts');
    });

    test('rejects a blank reason', () {
      expect(() => skipMessage(SkipCode.featureNotBuilt, ' \n\t'), throwsArgumentError);
    });

    test('accepts an app-defined code', () {
      expect(skipMessage(const SkipCode('MY_APP_CODE', 'App specific.'), 'why'), 'MY_APP_CODE why');
    });

    for (final invalid in ['lower_case', 'AB', '1ABC', 'HAS SPACE', '']) {
      test('rejects the code "$invalid"', () {
        expect(() => skipMessage(SkipCode(invalid, 'meaning'), 'why'), throwsArgumentError);
      });
    }
  });

  group('SkipCode', () {
    test('built-in codes are unique and valid', () {
      final codes = SkipCode.builtIn.map((code) => code.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
      for (final code in SkipCode.builtIn) {
        expect(code.meaning, isNotEmpty);
        expect(() => skipMessage(code, 'why'), returnsNormally);
      }
    });

    test('equality is by code', () {
      expect(const SkipCode('FEATURE_NOT_BUILT', 'other words'), SkipCode.featureNotBuilt);
      expect(const SkipCode('FEATURE_NOT_BUILT', 'x').hashCode, SkipCode.featureNotBuilt.hashCode);
      expect(SkipCode.featureNotBuilt, isNot(SkipCode.featureNotConfigured));
    });
  });
}
