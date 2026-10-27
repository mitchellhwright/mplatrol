import 'dart:io';

/// How many colours the output sink can show.
enum ColorDepth { none, ansi16, ansi256, trueColor }

/// What the sink `mplatrol` writes to can show, detected once from the environment.
///
/// Every decision about colour, glyphs, links, wrapping and spinners reads this
/// one object, so tests inject a fake instead of touching the real terminal.
class TerminalCapabilities {
  const TerminalCapabilities({
    this.colorDepth = ColorDepth.none,
    this.unicode = false,
    this.hyperlinks = false,
    this.width,
    this.interactive = false,
    this.ci = false,
    this.teamCity = false,
  });

  /// Detects the capabilities from process signals.
  ///
  /// [environment] is the process environment, [stdoutIsTty] whether stdout is a terminal and
  /// [columns] its width when known.
  factory TerminalCapabilities.detect(
    Map<String, String> environment, {
    required bool stdoutIsTty,
    int? columns,
    bool isWindows = false,
  }) {
    final env = _Env(environment);
    final teamCity = env['TEAMCITY_VERSION'] != null;
    final ci = env.isTrue('CI') || env.isTrue('MPLATROL_NON_INTERACTIVE') || teamCity || env['GITLAB_CI'] != null;
    final interactive = stdoutIsTty && !ci && env['TERM'] != 'dumb';
    return TerminalCapabilities(
      colorDepth: _colorDepth(env, stdoutIsTty: stdoutIsTty, ci: ci, isWindows: isWindows),
      unicode: _isUnicode(env, isWindows: isWindows),
      hyperlinks: interactive && _supportsHyperlinks(env),
      width: _width(env, columns),
      interactive: interactive,
      ci: ci,
      teamCity: teamCity,
    );
  }

  static const minWidth = 40;

  final ColorDepth colorDepth;

  /// Whether the locale is UTF-8 so glyphs such as the check mark render.
  final bool unicode;

  /// Whether OSC 8 clickable links are safe to emit.
  final bool hyperlinks;

  /// The line width to wrap prose to; null when unknown (piped output with no `COLUMNS`), so
  /// machine-read output is never reflowed.
  final int? width;

  /// A person is watching a live terminal: spinners and redraws are allowed.
  final bool interactive;
  final bool ci;
  final bool teamCity;

  bool get color => colorDepth != ColorDepth.none;

  static ColorDepth _colorDepth(_Env env, {required bool stdoutIsTty, required bool ci, required bool isWindows}) {
    if (env['NO_COLOR'] != null) {
      return ColorDepth.none;
    }
    final force = env['FORCE_COLOR'];
    if (force != null) {
      return switch (force) {
        '0' || 'false' => ColorDepth.none,
        '2' => ColorDepth.ansi256,
        '3' => ColorDepth.trueColor,
        _ => ColorDepth.ansi16,
      };
    }
    if (env['CLICOLOR'] == '0') {
      return ColorDepth.none;
    }
    if (env['CLICOLOR_FORCE'] != null && env['CLICOLOR_FORCE'] != '0') {
      return ColorDepth.ansi16;
    }
    if (!stdoutIsTty) {
      // GitLab CI and TeamCity render ANSI colours although stdout is a pipe.
      return env['GITLAB_CI'] != null || env['TEAMCITY_VERSION'] != null ? ColorDepth.ansi16 : ColorDepth.none;
    }
    if (env['TERM'] == 'dumb') {
      return ColorDepth.none;
    }
    final colorTerm = env['COLORTERM']?.toLowerCase();
    if (colorTerm == 'truecolor' || colorTerm == '24bit' || env['WT_SESSION'] != null) {
      return ColorDepth.trueColor;
    }
    if (const {'iTerm.app', 'ghostty', 'WarpTerminal', 'vscode', 'WezTerm'}.contains(env['TERM_PROGRAM'])) {
      return ColorDepth.trueColor;
    }
    if ((env['TERM'] ?? '').contains('256color') || env['TERM_PROGRAM'] == 'Apple_Terminal') {
      return ColorDepth.ansi256;
    }
    return ColorDepth.ansi16;
  }

  static bool _isUnicode(_Env env, {required bool isWindows}) {
    if (isWindows && (env['WT_SESSION'] != null || env['TERM_PROGRAM'] == 'vscode')) {
      return true;
    }
    final locale = env['LC_ALL'] ?? env['LC_CTYPE'] ?? env['LANG'] ?? '';
    final lower = locale.toLowerCase();
    return lower.contains('utf-8') || lower.contains('utf8');
  }

  static bool _supportsHyperlinks(_Env env) {
    if (env['NO_HYPERLINKS'] != null) {
      return false;
    }
    final program = env['TERM_PROGRAM'];
    if (program == 'tmux') {
      final version = double.tryParse((env['TERM_PROGRAM_VERSION'] ?? '').replaceAll(RegExp('[^0-9.]'), ''));
      return version != null && version >= 3.4;
    }
    if (env['TERM']?.startsWith('screen') ?? false) {
      return false;
    }
    final vte = int.tryParse(env['VTE_VERSION'] ?? '') ?? 0;
    return const {'iTerm.app', 'ghostty', 'WarpTerminal', 'vscode', 'WezTerm', 'Apple_Terminal'}.contains(program) ||
        env['WT_SESSION'] != null ||
        env['KITTY_WINDOW_ID'] != null ||
        vte >= 5000;
  }

  static int? _width(_Env env, int? columns) {
    final width = columns ?? int.tryParse(env['COLUMNS'] ?? '');
    if (width == null) {
      return null;
    }
    return width < minWidth ? minWidth : width;
  }
}

/// Environment lookups that treat empty values as unset (the `NO_COLOR` convention).
class _Env {
  _Env(this._values);

  final Map<String, String> _values;

  String? operator [](String name) {
    final value = _values[name];
    return value == null || value.isEmpty ? null : value;
  }

  bool isTrue(String name) => this[name]?.toLowerCase() == 'true';
}

/// The capabilities of the real process: its environment, stdout and platform.
// coverage:ignore-start
TerminalCapabilities detectTerminalCapabilities() {
  final isTty = stdout.hasTerminal;
  return TerminalCapabilities.detect(
    Platform.environment,
    stdoutIsTty: isTty,
    columns: isTty ? stdout.terminalColumns : null,
    isWindows: Platform.isWindows,
  );
}
// coverage:ignore-end
