import 'package:mason_logger/mason_logger.dart';
import 'package:mplatrol/src/ci_report/teamcity_messages.dart';
import 'package:mplatrol/src/core/terminal_text.dart';

/// A [Progress] for sinks that cannot redraw (pipes, CI logs, `tee`): no spinner and no `\r`.
///
/// It prints one start line and one end line with the duration. In TeamCity the pair is wrapped
/// in a collapsible `blockOpened`/`blockClosed` section when [teamCityBlocks] is set.
class PlainProgress implements Progress {
  PlainProgress(
    this._message,
    this._write,
    this._text, {
    this.teamCityBlocks = false,
  }) {
    if (teamCityBlocks) {
      _write("##teamcity[blockOpened name='${escapeTeamCityValue(_message)}']");
    }
    _write('$_message...');
  }

  final String _message;
  final void Function(String) _write;
  final TerminalText _text;
  final bool teamCityBlocks;
  final _stopwatch = Stopwatch()..start();
  late String _current = _message;
  var _done = false;

  @override
  void update(String update) => _current = update;

  @override
  void complete([String? update]) => _finish(_text.ok, update);

  @override
  void fail([String? update]) => _finish(_text.fail, update);

  @override
  void cancel() => _finish(null, null);

  void _finish(String? mark, String? update) {
    if (_done) {
      return;
    }
    _done = true;
    if (mark != null) {
      final seconds = (_stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      _write('$mark ${update ?? _current} (${seconds}s)');
    }
    if (teamCityBlocks) {
      _write("##teamcity[blockClosed name='${escapeTeamCityValue(_message)}']");
    }
  }
}
