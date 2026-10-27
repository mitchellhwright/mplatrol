import 'package:mplatrol/src/core/terminal_capabilities.dart';

/// Turns plain messages into what the current sink can show: ASCII glyph fallbacks, tag colours,
/// wrapping to the terminal width, OSC 8 links and aligned tables.
class TerminalText {
  const TerminalText(this.capabilities);

  final TerminalCapabilities capabilities;

  static final _ansi = RegExp('\u001B\\[[0-9;]*m');
  static final _signature = RegExp(r'(verify=)[^&\s)\]]+');
  static final _leadingTag = RegExp(r'^(\s*)\[([A-Za-z0-9_-]+)\]');
  static final _wrapToken = RegExp(r'`[^`]*`|\S+');
  static final _spinnerGlyph = RegExp('[⠀-⣿]');
  static const _tagColors = {'ok': '32', 'warn': '33', 'fail': '31', 'error': '31'};

  /// The check mark, cross and warning marks for the sink's locale.
  String get ok => capabilities.unicode ? '✓' : '[ok]';
  String get fail => capabilities.unicode ? '✗' : '[fail]';
  String get warn => capabilities.unicode ? '⚠' : '[warn]';

  /// The spinner frames: braille on UTF-8 terminals, ASCII otherwise.
  List<String> get spinnerFrames =>
      capabilities.unicode ? const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'] : const ['-', '\\', '|', '/'];

  /// [message] ready to print: signatures redacted, glyphs mapped, tags styled and lines wrapped.
  String render(String message) {
    final lines = [for (final line in message.split('\n')) _styleTag(_wrap(_glyphs(_redact(line))))];
    return lines.join('\n');
  }

  /// Wraps [text] in [url] as a clickable link where the terminal supports it, else `text (url)`
  /// when the text differs from the URL, else the plain URL.
  String link(String text, String url) {
    final safe = _redact(url);
    if (capabilities.hyperlinks) {
      return '\u001B]8;;$safe\u001B\\$text\u001B]8;;\u001B\\';
    }
    return text == url || text == safe ? safe : '$text ($safe)';
  }

  /// Rows of `label  count` with the labels padded and the counts right-aligned.
  List<String> table(List<(String, int)> rows, {String indent = '  '}) {
    final labelWidth = rows.fold(0, (widest, row) => row.$1.length > widest ? row.$1.length : widest);
    final countWidth = rows.fold(0, (widest, row) => '${row.$2}'.length > widest ? '${row.$2}'.length : widest);
    return [for (final (label, count) in rows) '$indent${label.padRight(labelWidth)}  ${'$count'.padLeft(countWidth)}'];
  }

  /// [text] in the dim style, or unchanged without colour.
  String dim(String text) => _paint('2', text);

  /// The visible length of [text] without colour codes.
  static int visibleLength(String text) => text.replaceAll(_ansi, '').length;

  String _redact(String text) => text.replaceAllMapped(_signature, (match) => '${match[1]}REDACTED');

  String _glyphs(String line) {
    if (capabilities.unicode) {
      return line;
    }
    return line
        .replaceAll('⚠️', '[warn]')
        .replaceAll('⚠', '[warn]')
        .replaceAll('✓', '[ok]')
        .replaceAll('✗', '[fail]')
        .replaceAll('→', '->')
        .replaceAll('…', '...')
        .replaceAll('·', '-')
        .replaceAll(_spinnerGlyph, '-');
  }

  String _wrap(String line) {
    final width = capabilities.width;
    if (width == null || visibleLength(line) <= width) {
      return line;
    }
    final indent = _hangingIndent(line);
    final rows = <StringBuffer>[StringBuffer()];
    var rowLength = 0;
    for (final token in _wrapToken.allMatches(line).map((match) => match[0]!)) {
      final length = visibleLength(token);
      final isFirstOnRow = rowLength == 0;
      if (!isFirstOnRow && rowLength + 1 + length > width) {
        rows.add(StringBuffer(indent));
        rowLength = indent.length;
      } else if (!isFirstOnRow) {
        rows.last.write(' ');
        rowLength++;
      } else if (rows.length == 1) {
        rows.last.write(line.substring(0, line.length - line.trimLeft().length));
        rowLength = line.length - line.trimLeft().length;
      }
      rows.last.write(token);
      rowLength += length;
    }
    return rows.join('\n');
  }

  String _hangingIndent(String line) {
    final leading = line.length - line.trimLeft().length;
    final tag = _leadingTag.firstMatch(line);
    return ' ' * (leading + (tag == null ? 0 : tag[2]!.length + 3));
  }

  String _styleTag(String line) {
    final tag = _leadingTag.firstMatch(line);
    if (tag == null || !capabilities.color) {
      return line;
    }
    final color = _tagColors[tag[2]] ?? '2';
    return '${tag[1]}${_paint(color, '[${tag[2]}]')}${line.substring(tag.end)}';
  }

  String _paint(String code, String text) => capabilities.color ? '\u001B[${code}m$text\u001B[0m' : text;
}
