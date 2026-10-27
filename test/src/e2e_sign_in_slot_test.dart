import 'dart:io';

import 'package:mplatrol/src/e2e_sign_in_slot.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final shared in [false, true]) {
    group(shared ? 'kept in a file' : 'kept in this process', () => _slotCases(shared: shared));
  }

  test('two slots on one file are one slot', () {
    final dir = Directory.systemTemp.createTempSync('mplatrol_slot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'slots', 'user.json');
    final ios = E2eSignInSlot(file: file);
    final android = E2eSignInSlot(file: file);

    expect(ios.acquire('ios-1').granted, isTrue);
    expect(android.acquire('android-1').granted, isFalse);
    expect(ios.release('ios-1'), isTrue);
    expect(android.acquire('android-1').granted, isTrue);
    expect(File('$file.lock').existsSync(), isFalse);
  });

  test('a stale lock and an unreadable slot file are recovered', () {
    final dir = Directory.systemTemp.createTempSync('mplatrol_slot');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'user.json');
    File(file).writeAsStringSync('not json');
    File('$file.lock')
      ..writeAsStringSync('')
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 1)));

    expect(E2eSignInSlot(file: file).acquire('a').granted, isTrue);
  });
}

void _slotCases({required bool shared}) {
  late DateTime now;
  late E2eSignInSlot slot;
  late Directory dir;

  setUp(() {
    now = DateTime.utc(2026, 10, 2, 20, 38, 20);
    dir = Directory.systemTemp.createTempSync('mplatrol_slot');
    slot = E2eSignInSlot(clock: () => now, file: shared ? p.join(dir.path, 'user.json') : null);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('grants a free slot for the default hold', () {
    expect(slot.hold, e2eSignInSlotHold);
    expect(slot.acquire('device-a'), (granted: true, wait: Duration.zero));
  });

  test('makes a second device wait until the first releases', () {
    slot.acquire('device-a');
    now = now.add(const Duration(seconds: 15));

    expect(slot.acquire('device-b'), (granted: false, wait: const Duration(seconds: 45)));
    expect(slot.release('device-b'), isFalse, reason: 'only the holder can release');
    expect(slot.release('device-a'), isTrue);
    expect(slot.acquire('device-b').granted, isTrue);
  });

  test('the holder asking again renews its hold', () {
    slot.acquire('device-a');
    now = now.add(const Duration(seconds: 50));
    expect(slot.acquire('device-a').granted, isTrue);
    now = now.add(const Duration(seconds: 50));

    expect(slot.acquire('device-b'), (granted: false, wait: const Duration(seconds: 10)));
  });

  test('an expired hold passes to the next device, so a dead device stalls no one for long', () {
    slot.acquire('device-a');
    now = now.add(e2eSignInSlotHold);

    expect(slot.acquire('device-b').granted, isTrue);
    expect(slot.release('device-a'), isFalse);
  });

  test('releasing a free slot is a no-op', () {
    expect(slot.release('device-a'), isFalse);
    expect(E2eSignInSlot().acquire('device-a').granted, isTrue);
  });
}
