import 'package:mplatrol/src/lt_run_support.dart';
import 'package:test/test.dart';

class _Support with LtRunSupport {
  @override
  Duration get pollDelay => Duration.zero;
}

void main() {
  test('names the build identity of a record, also a negative hash and without an inputs revision', () {
    final support = _Support();
    expect(support.shortIdentity('/c/ios--1c08c20c5ebda92e-inputs-48b9c3d9.json'), '-1c08c20c5eb');
    expect(support.shortIdentity('/c/android-0183843bc7e1aa-inputs-48b9c3d9.json'), '0183843bc7e1');
    expect(support.shortIdentity('/c/ios-abc123.json'), 'abc123');
  });
}
