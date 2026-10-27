import 'dart:convert';
import 'dart:typed_data';

const _hashOffset = 0xcbf29ce484222325;
const _hashPrime = 0x100000001b3;
const _hashMask = 0xffffffffffffffff;

/// Order-sensitive 64-bit FNV-1a digest of strings and bytes.
///
/// Used to detect whether integration-test inputs changed between runs; it is
/// not a cryptographic hash.
class FingerprintBuilder {
  int _hash = _hashOffset;

  /// Adds [value] followed by a separator so adjacent values cannot merge.
  void addString(String value) {
    addBytes(utf8.encode(value));
    _addByte(0);
  }

  /// Adds [bytes] followed by a separator so adjacent values cannot merge.
  void addBytes(List<int> bytes) {
    if (bytes is Uint8List) {
      var hash = _hash;
      for (var i = 0; i < bytes.length; i++) {
        hash = ((hash ^ bytes[i]) * _hashPrime) & _hashMask;
      }
      _hash = (hash * _hashPrime) & _hashMask;
      return;
    }
    bytes.forEach(_addByte);
    _addByte(0);
  }

  /// The digest as 16 lowercase hex characters.
  String finish() => _hash.toRadixString(16).padLeft(16, '0');

  void _addByte(int byte) {
    _hash ^= byte;
    _hash = (_hash * _hashPrime) & _hashMask;
  }
}
