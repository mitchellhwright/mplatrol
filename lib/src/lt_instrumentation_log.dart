import 'dart:convert';

/// The runner output carried by a LambdaTest instrumentation log.
///
/// Some iOS real devices (seen on iOS 16) publish the log as JSON lines, one
/// record per chunk of runner output:
/// `{"fields.msg":"<output>\n",...,"msg":"outputReceived:fromProcess:atTime:"}`.
/// Their `fields.msg` chunks are joined back into the plain text other devices
/// publish, so `Test Case`, `PATROL_RESULT` and skip markers parse the same on
/// every device. A log without such records is returned unchanged; any other
/// line in a JSON-lines log is kept on its own line.
String plainLtInstrumentationLog(String rawLog) {
  final log = repairMojibake(rawLog);
  if (!log.contains('"fields.msg"')) {
    return log;
  }
  final plain = StringBuffer();
  var atLineStart = true;
  for (final line in const LineSplitter().convert(log)) {
    final chunk = _outputChunk(line);
    if (chunk == null && !atLineStart) {
      plain.writeln();
    }
    final text = chunk ?? '$line\n';
    plain.write(text);
    atLineStart = text.isEmpty ? atLineStart : text.endsWith('\n');
  }
  return plain.toString();
}

String? _outputChunk(String line) {
  if (!line.startsWith('{')) {
    return null;
  }
  try {
    final record = jsonDecode(line);
    final chunk = record is Map ? record['fields.msg'] : null;
    return chunk is String ? chunk : null;
  } on FormatException {
    // A line that only looks like JSON is runner output, kept verbatim.
    return null;
  }
}

/// UTF-8 text that was decoded as Latin-1 and encoded as UTF-8 again: a lead byte (`Â`, `Ã`, `â`) followed by
/// a C1 control or Latin-1 punctuation character, as in `âââ¡` for the box drawing of Flutter's banner.
final _mojibake = RegExp('[\u00C2-\u00F4][\u0080-\u00BF]');

/// [text] with a double-encoded UTF-8 log repaired (Latin-1 bytes decoded as UTF-8 again), or [text] itself
/// when it shows no sign of that or is not wholly Latin-1 (so it was not double-encoded).
String repairMojibake(String text) {
  if (!_mojibake.hasMatch(text) || text.runes.any((rune) => rune > 0xFF)) {
    return text;
  }
  try {
    return utf8.decode(latin1.encode(text));
  } on FormatException {
    return text;
  }
}

final _flutterFailure = RegExp(r'The following (\w+) was thrown running a test:\r?\n((?:[^\r\n]+\r?\n?)+)');

const _maxFailureMessageLength = 400;

/// The failure Flutter's test framework printed in [log] as `Type: message` (Patrol wraps the message over
/// several lines; they are joined), without the screen dump that follows `screen shows`, or null when the log
/// has no Flutter test exception.
String? flutterTestFailureMessage(String log) {
  final match = _flutterFailure.firstMatch(log);
  if (match == null) {
    return null;
  }
  final message =
      match[2]!.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty).join(' ');
  final withoutScreen = message.split(' screen shows [').first.trim();
  final text = '${match[1]}: $withoutScreen';
  return text.length > _maxFailureMessageLength ? '${text.substring(0, _maxFailureMessageLength)}...' : text;
}
