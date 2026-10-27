import 'package:mplatrol/src/android_patrol_runner.dart';
import 'package:mplatrol/src/ios_patrol_runner.dart';
import 'package:test/test.dart';

void main() {
  test('iOS Boolean-only recipe is invalidated by typed skip generation', () {
    expect(iosPatrolGeneratorIdentity(), isNot('7765c8983e04905c'));
  });
  test('canonical identities are stable across repeated rendering', () {
    expect(iosPatrolGeneratorIdentity(), iosPatrolGeneratorIdentity());
    expect(androidPatrolGeneratorIdentity(), androidPatrolGeneratorIdentity());
  });

  test('Android credentials and runtime ports do not affect compiled identity', () {
    final identity = androidPatrolGeneratorIdentity();
    expect(
        androidPatrolGeneratorIdentity(env: {
          'E2E_USERNAME': 'another-user',
          'E2E_PASSWORD': 'another-password',
          'E2E_CREDENTIALS_URL': 'http://127.0.0.1:12345',
        }),
        identity);
  });

  test('Android timeout changes compiled identity only when its resolved value changes', () {
    final identity = androidPatrolGeneratorIdentity();
    expect(androidPatrolGeneratorIdentity(env: {e2eTestTimeoutMsEnv: '600000'}), isNot(identity));
    for (final timeout in ['', 'invalid', '0', '-1', '240000']) {
      expect(androidPatrolGeneratorIdentity(env: {e2eTestTimeoutMsEnv: timeout}), identity);
    }
  });
}
