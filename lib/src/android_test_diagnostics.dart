import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _maxReportBytes = 256 * 1024;
const _maxEntries = 512;
const _maxReports = 32;
const _maxDepth = 6;
const _maxErrors = 3;
const _maxSummaryLength = 240;
const _storageError = 'INSTALL_FAILED_INSUFFICIENT_STORAGE';
const _storageAdvice = '[android-utp] Free space on the selected Android device/emulator '
    '(Settings > Storage), remove unneeded apps/files, then retry. '
    'Do not wipe the device automatically.';

/// Reads bounded Android UTP platform-error summaries without dumping logs.
class AndroidTestDiagnostics {
  /// Summarizes reports written during the failed run.
  ///
  /// Call only after Android execution fails, passing the timestamp captured
  /// before execution. Missing, stale, changing, or malformed reports produce
  /// no diagnostic. The helper never invokes adb or changes device state.
  Future<List<String>> summarizeCurrentFailure({
    required String repo,
    required DateTime runStartedAt,
  }) async {
    final root = Directory(p.join(
      repo,
      'build/app/outputs/androidTest-results/connected/debug',
    ));
    final collectedAt = DateTime.now();
    final lines = <String>{};
    var storageFailure = false;
    final reports = await _findReports(root);
    for (final file in reports) {
      final text = await _readCurrentReport(file, runStartedAt, collectedAt);
      if (text == null) {
        continue;
      }
      for (final error in _parseErrors(text)) {
        storageFailure = storageFailure || error.isStorageFailure;
        if (lines.length < _maxErrors) {
          final summary = _safeSummary(error.message);
          final name = error.name;
          lines.add('[android-utp] $name: $summary');
        }
      }
    }
    return [...lines, if (storageFailure) _storageAdvice];
  }

  /// Reads a bounded, stable report only when it belongs to this attempt.
  Future<String?> readCurrentReport(
    File file, {
    required DateTime runStartedAt,
    required DateTime collectedAt,
  }) =>
      _readCurrentReport(file, runStartedAt, collectedAt);
}

Future<List<File>> _findReports(Directory root) async {
  final pending = <({Directory directory, int depth})>[
    (directory: root, depth: 0),
  ];
  final reports = <File>[];
  var entries = 0;
  while (pending.isNotEmpty && entries < _maxEntries) {
    final current = pending.removeLast();
    try {
      await for (final entity in current.directory.list(followLinks: false)) {
        entries++;
        if (entries > _maxEntries || reports.length >= _maxReports) {
          return reports;
        }
        if (entity is File && p.basename(entity.path) == 'test-result.textproto') {
          reports.add(entity);
        } else if (entity is Directory && current.depth < _maxDepth) {
          pending.add((directory: entity, depth: current.depth + 1));
        }
      }
    } on FileSystemException {
      // Missing/unreadable reports cannot establish a current-run cause.
      continue;
    }
  }
  reports.sort((left, right) => left.path.compareTo(right.path));
  return reports;
}

Future<String?> _readCurrentReport(
  File file,
  DateTime runStartedAt,
  DateTime collectedAt,
) async {
  try {
    final before = await file.stat();
    if (before.size > _maxReportBytes ||
        before.modified.isBefore(runStartedAt) ||
        before.modified.isAfter(collectedAt)) {
      return null;
    }
    final handle = await file.open();
    final List<int> bytes;
    try {
      bytes = await handle.read(_maxReportBytes + 1);
    } finally {
      await handle.close();
    }
    final after = await file.stat();
    if (bytes.length > _maxReportBytes ||
        bytes.length != before.size ||
        after.size != before.size ||
        after.modified != before.modified) {
      return null;
    }
    return utf8.decode(bytes);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

List<_PlatformError> _parseErrors(String text) {
  try {
    return _PlatformErrorParser(text).parse();
  } on FormatException {
    return const [];
  }
}

class _PlatformErrorParser {
  _PlatformErrorParser(String text)
      : tokens = RegExp(
          r'''#[^\r\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z0-9_]*|[^\s]''',
          dotAll: true,
        ).allMatches(text).map((match) => match.group(0)!).toList();

  final List<String> tokens;
  final _closing = <String>[];
  final _scopes = <String>[];
  final _errors = <_PlatformError>[];
  final _summaries = <({int depth, Map<String, String> fields})>[];
  Map<String, String>? _fields;
  int? _platformDepth;
  var _hasSummaries = false;
  var _index = 0;

  List<_PlatformError> parse() {
    for (_index = 0; _index < tokens.length; _index++) {
      final token = tokens[_index];
      if (token.startsWith('#')) {
        continue;
      }
      if (token == '{' || token == '<') {
        _open(token);
      } else if (token == '}' || token == '>') {
        _close(token);
      } else if (_currentFields != null && (token == 'error_name' || token == 'error_message')) {
        _readField(token);
      } else if (token.startsWith('"') || token.startsWith("'")) {
        _decodeQuoted(token);
      }
    }
    if (_closing.isNotEmpty || _fields != null) {
      throw const FormatException('Incomplete UTP report');
    }
    return _errors;
  }

  void _open(String token) {
    _closing.add(token == '{' ? '}' : '>');
    var fieldIndex = _index - 1;
    if (fieldIndex >= 0 && tokens[fieldIndex] == ':') {
      fieldIndex--;
    }
    final field = fieldIndex < 0 ? '' : tokens[fieldIndex];
    _scopes.add(field);
    if (_platformDepth != null && field == 'summary') {
      _summaries.add((depth: _closing.length, fields: <String, String>{}));
      _hasSummaries = true;
      return;
    }
    if (field != 'platform_error') {
      return;
    }
    if (_fields != null) {
      throw const FormatException('Nested platform errors are ambiguous');
    }
    _fields = {};
    _platformDepth = _closing.length;
    _hasSummaries = false;
  }

  void _close(String token) {
    if (_closing.isEmpty || _closing.last != token) {
      throw const FormatException('Unbalanced UTP report');
    }
    if (_summaries.isNotEmpty && _summaries.last.depth == _closing.length) {
      _appendError(_summaries.removeLast().fields, allowAnonymous: true);
    }
    if (_closing.length == _platformDepth) {
      if (_fields!.isNotEmpty || !_hasSummaries) {
        _appendError(_fields!);
      }
      _fields = null;
      _platformDepth = null;
    }
    _closing.removeLast();
    _scopes.removeLast();
  }

  Map<String, String>? get _currentFields {
    if (_summaries.isNotEmpty) {
      return _summaries.last.depth == _closing.length ? _summaries.last.fields : null;
    }
    final depth = _platformDepth;
    if (depth == null) {
      return null;
    }
    final legacyDetail = _closing.length == depth + 1 && _scopes.last == 'error_detail';
    return _closing.length == depth || legacyDetail ? _fields : null;
  }

  void _appendError(Map<String, String> fields, {bool allowAnonymous = false}) {
    final name = fields['error_name'];
    final message = fields['error_message'];
    if (name == null && allowAnonymous) {
      return;
    }
    if (name == null ||
        message == null ||
        !RegExp(r'^[A-Z][A-Z0-9_]{0,95}$').hasMatch(name) ||
        message.trim().isEmpty) {
      throw const FormatException('Incomplete platform error summary');
    }
    _errors.add(_PlatformError(name, message));
  }

  void _readField(String name) {
    final fields = _currentFields!;
    if (fields.containsKey(name) || _index + 2 >= tokens.length || tokens[_index + 1] != ':') {
      throw const FormatException('Malformed platform error field');
    }
    _index += 2;
    final value = StringBuffer(_decodeQuoted(tokens[_index]));
    while (_index + 1 < tokens.length && _isQuoted(tokens[_index + 1])) {
      _index++;
      value.write(_decodeQuoted(tokens[_index]));
    }
    fields[name] = value.toString();
  }
}

bool _isQuoted(String token) =>
    token.length >= 2 && (token.startsWith('"') || token.startsWith("'")) && token.endsWith(token[0]);

String _decodeQuoted(String token) {
  if (!_isQuoted(token)) {
    throw const FormatException('Expected a quoted textproto string');
  }
  final body = token.substring(1, token.length - 1);
  if (body.contains('\n') || body.contains('\r')) {
    throw const FormatException('Unescaped newline in textproto string');
  }
  return body.replaceAllMapped(
    RegExp(r'\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|[0-7]{1,3}|.)'),
    (match) => _decodeEscape(match.group(1)!),
  );
}

String _decodeEscape(String escaped) {
  const simple = {
    'a': '\x07',
    'b': '\b',
    'f': '\f',
    'n': '\n',
    'r': '\r',
    't': '\t',
    'v': '\x0b',
    '\\': '\\',
    '"': '"',
    "'": "'",
    '?': '?',
  };
  final value = simple[escaped];
  if (value != null) {
    return value;
  }
  final octal = RegExp(r'^[0-7]{1,3}$').hasMatch(escaped);
  final hex = RegExp(r'^[xuU][0-9a-fA-F]+$').hasMatch(escaped);
  if (!octal && !hex) {
    throw const FormatException('Unsupported textproto escape');
  }
  final number = int.parse(
    octal ? escaped : escaped.substring(1),
    radix: octal ? 8 : 16,
  );
  if (number > 0x10ffff || (number >= 0xd800 && number <= 0xdfff)) {
    throw const FormatException('Invalid textproto character');
  }
  return String.fromCharCode(number);
}

String _safeSummary(String message) {
  var summary = message.replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '');
  summary = summary.replaceAll(
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    '[url redacted]',
  );
  summary = summary.replaceAll(
    RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  summary = summary.replaceAllMapped(
    RegExp(
      r'\b(authorization|(?:access[_-]?|refresh[_-]?|api[_-]?)?token|password|secret|api[_-]?key)\b'
      r'''\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
    ),
    (match) {
      final key = match.group(1);
      return '$key=[redacted]';
    },
  );
  summary = summary.replaceAll(
    RegExp(r'\b[A-Za-z0-9_+/=-]{32,}\b'),
    '[opaque value redacted]',
  );
  summary = summary.split(RegExp(r'[\r\n]')).first;
  summary = summary.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (summary.length > _maxSummaryLength) {
    summary = '${summary.substring(0, _maxSummaryLength)}...';
  }
  return summary.isEmpty ? '(no printable platform-error summary)' : summary;
}

class _PlatformError {
  const _PlatformError(this.name, this.message);

  final String name;
  final String message;

  bool get isStorageFailure => name == _storageError || message.contains(_storageError);
}
