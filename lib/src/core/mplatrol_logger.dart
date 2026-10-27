import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/plain_progress.dart';
import 'package:mplatrol/src/core/terminal_capabilities.dart';
import 'package:mplatrol/src/core/terminal_text.dart';

/// The CLI's logger: every message goes through [TerminalText.render] (glyph fallbacks, tag styles,
/// wrapping and signature redaction) so call sites stay plain.
class MplatrolLogger extends Logger {
  /// Only [Dependencies] creates the single instance.
  MplatrolLogger.constructGlobalInstance();

  TerminalCapabilities get _capabilities => getDep<TerminalCapabilities>();

  TerminalText get _text => TerminalText(_capabilities);

  @override
  void info(String? message, {LogStyle? style}) => super.info(_render(message), style: style);

  @override
  void detail(String? message, {LogStyle? style}) => super.detail(_render(message), style: style);

  @override
  void alert(String? message, {LogStyle? style}) => super.alert(_render(message), style: style);

  @override
  void success(String? message, {LogStyle? style}) => super.success(_render(message), style: style);

  @override
  void err(String? message, {LogStyle? style}) => super.err(_render(message), style: style);

  @override
  void warn(String? message, {String tag = 'warn', LogStyle? style}) =>
      super.warn(_render(message?.replaceFirst(_leadingWarnGlyph, '')), tag: tag, style: style);

  /// The `[warn]` tag already says it, so a leading warning glyph would only repeat it.
  static final _leadingWarnGlyph = RegExp(r'^\s*⚠️?\s*');

  String? _render(String? message) => message == null ? null : _text.render(message);

  /// A spinner on a live terminal that can redraw the line; otherwise [PlainProgress] prints a
  /// start line and an end line with the duration, so logs never hold `\r` redraws or frames.
  @override
  Progress progress(String message, {ProgressOptions? options}) {
    final capabilities = _capabilities;
    final text = _text;
    final fitsOneLine = message.length + 12 <= (capabilities.width ?? double.infinity);
    if (capabilities.interactive && fitsOneLine) {
      return super.progress(
        message,
        options: options ?? ProgressOptions(animation: ProgressAnimation(frames: text.spinnerFrames)),
      );
    }
    return PlainProgress(message, info, text, teamCityBlocks: capabilities.teamCity);
  }
}
