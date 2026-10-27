import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mplatrol/src/fingerprint_builder.dart';
import 'package:test/test.dart';

String _reference(Iterable<int> bytes) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  for (final byte in bytes) {
    hash = ((hash ^ BigInt.from(byte)) * prime).toUnsigned(64);
  }
  return hash.toSigned(64).toRadixString(16).padLeft(16, '0');
}

class _ThrowingBytes extends ListBase<int> {
  @override
  int get length => 2;

  @override
  set length(int value) => throw UnsupportedError('Fixed length');

  @override
  int operator [](int index) {
    if (index == 1) {
      throw StateError('Unreadable element');
    }
    return 7;
  }

  @override
  void operator []=(int index, int value) => throw UnsupportedError('Read only');
}

void main() {
  test('preserves existing signed hexadecimal known vectors', () {
    expect(FingerprintBuilder().finish(), '-340d631b7bdddcdb');
    expect((FingerprintBuilder()..addBytes(Uint8List(0))).finish(), '-509c42b379fe4821');
    expect((FingerprintBuilder()..addBytes(Uint8List.fromList([0, 1, 127, 128, 255]))).finish(), '0-a2c3d22bb17ebe');
    expect((FingerprintBuilder()..addString('hello')).finish(), '-7566754884f0f83d');
  });

  test('typed and ordinary lists match an independent 64-bit reference at boundaries', () {
    for (final length in [0, 1, 7, 8, 9, 15, 16, 17, 63, 64, 65, 255, 256, 257, 32769]) {
      final bytes = List.generate(length, (i) => (i * 131 + i ~/ 256) & 255);
      final expected = _reference([...bytes, 0]);
      expect((FingerprintBuilder()..addBytes(bytes)).finish(), expected);
      expect((FingerprintBuilder()..addBytes(Uint8List.fromList(bytes))).finish(), expected);
    }
  });

  test('nonzero-offset typed views hash only the selected bytes', () {
    final backing = Uint8List.fromList(List.generate(300, (i) => i & 255));
    final view = Uint8List.sublistView(backing, 11, 279);
    expect((FingerprintBuilder()..addBytes(view)).finish(), _reference([...view, 0]));
  });

  test('successive typed byte values retain a separator after each value', () {
    final builder = FingerprintBuilder()
      ..addBytes(Uint8List.fromList([1, 2]))
      ..addBytes(Uint8List(0))
      ..addBytes(Uint8List.fromList([3]));
    expect(builder.finish(), _reference([1, 2, 0, 0, 3, 0]));
    expect(builder.finish(), isNot((FingerprintBuilder()..addBytes([1, 2, 3])).finish()));
  });

  test('strings retain UTF-8 bytes and both existing separators', () {
    final value = String.fromCharCodes([65, 0x00e9, 0x1f680]);
    final builder = FingerprintBuilder()
      ..addString(value)
      ..addBytes(Uint8List.fromList([9]))
      ..addString('');
    expect(builder.finish(), _reference([...utf8.encode(value), 0, 0, 9, 0, 0, 0]));
  });

  test('every possible byte mutation changes the shared fingerprint', () {
    final bytes = Uint8List.fromList(List.generate(256, (i) => i));
    final original = (FingerprintBuilder()..addBytes(bytes)).finish();
    for (var i = 0; i < bytes.length; i++) {
      final changed = Uint8List.fromList(bytes);
      changed[i] ^= 1;
      final digest = (FingerprintBuilder()..addBytes(changed)).finish();
      expect(digest, isNot(original));
      expect(digest, _reference([...changed, 0]));
    }
  });

  test('ordinary lists retain existing non-byte integer behavior', () {
    final bytes = [-1, 256, 0x7fffffffffffffff, -0x7fffffffffffffff];
    expect((FingerprintBuilder()..addBytes(bytes)).finish(), _reference([...bytes, 0]));
  });

  test('ordinary list read errors propagate without appending a separator', () {
    final builder = FingerprintBuilder();
    expect(() => builder.addBytes(_ThrowingBytes()), throwsStateError);
    builder.addBytes([9]);
    expect(builder.finish(), _reference([7, 9, 0]));
  });
}
