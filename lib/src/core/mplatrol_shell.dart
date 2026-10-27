// coverage:ignore-file

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:mplatrol/src/build_log_filter.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/process_result.dart';
import 'package:process_run/shell_run.dart';
// ignore: implementation_imports
import 'package:process_run/src/which.dart' as process_run_which;

class MplatrolShell {
  /// This should only be used to create one single
  ///   instance in the [MplatrolCommandRunner]
  MplatrolShell.constructGlobalInstance();

  /// How many trailing lines of a failed quiet build's captured output to print
  /// (the filter hid them while it ran, so surface enough to diagnose).
  static const _buildFailureTailLines = 50;

  static const _exceptionOutputTailLines = 80;
  static const _exceptionOutputMaxChars = 12000;
  static const _exceptionLineMaxChars = 1000;

  /// Run a process in a shell on the machine
  ///
  /// [script] - the actual script to run on the machine
  ///
  /// [silent] - used to run commands that should always have silent output
  ///
  /// [throwOnError] - throw an error if the process throws
  ///     this may be useful when an error is expected etc...
  ///
  /// [workingDirectory] - the directory to run this shell command in
  Future<ProcessResultX> run(
    String script, {
    bool throwOnError = true,
    bool forceVerbose = false,
    bool silent = false,
    bool quietBuild = false,
    bool surfaceFailureOutput = false,
    String? workingDirectory,
  }) async {
    final logger = getDep<MplatrolLogger>();

    final stdoutController = ShellLinesController();
    final stderrController = ShellLinesController();

    final workingDir = workingDirectory ?? Directory.current.path;

    final shell = Shell(
      throwOnError: false,
      workingDirectory: workingDir,
      verbose: false,
      stderr: stderrController.sink,
      stdout: stdoutController.sink,
    );

    // quietBuild hides high-volume build chatter (keeping test/Patrol lines) and
    // shows a spinner over silent stretches so a long build does not look hung.
    // The shell still captures all output, so a failure's tail can be surfaced
    // below. The spinner only animates on a terminal (piped/CI output stays
    // clean).
    Progress? spinner;
    var lastShownAt = DateTime.now();
    final spinnerEnabled = quietBuild && stdout.hasTerminal;
    Timer? silenceTimer;
    if (spinnerEnabled) {
      silenceTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (spinner == null && DateTime.now().difference(lastShownAt) >= const Duration(seconds: 2)) {
          spinner = logger.progress('building (run with --verbose for the full build log)');
        }
      });
    }

    void display(String rawText, {required bool isError}) {
      // Without trimRight the printed log wraps oddly (line-length setting).
      final text = rawText.trimRight();
      final bool show;
      if (silent && !forceVerbose) {
        show = false;
      } else if (forceVerbose) {
        show = true;
      } else if (quietBuild) {
        // --verbose (debug level) shows everything, so the "run with --verbose
        // for the full log" guidance is honest; otherwise hide build noise.
        show = logger.level.index <= Level.debug.index || !isBuildNoise(text);
      } else {
        show = logger.level.index <= Level.debug.index;
      }
      if (!show) {
        return;
      }
      spinner?.cancel();
      spinner = null;
      lastShownAt = DateTime.now();
      if (isError && !forceVerbose) {
        logger.info(lightRed.wrap(text));
      } else if (isError) {
        logger.err(text);
      } else {
        logger.info(text);
      }
    }

    stdoutController.stream.listen((rawText) => display(rawText, isError: false));
    stderrController.stream.listen((rawText) => display(rawText, isError: true));

    final List<ProcessResult> processResult;
    try {
      processResult = await shell.run(script);
    } finally {
      // Always tear down the listeners + quiet-build spinner/timer, even if
      // shell.run throws (process_run rethrows ProcessException regardless of
      // throwOnError) — a live periodic timer would otherwise keep the event
      // loop alive and hang the CLI at exit.
      stdoutController.close();
      stderrController.close();
      silenceTimer?.cancel();
      spinner?.cancel();
    }

    final result = processResult.first;

    _surfaceFailureOutput(
      logger: logger,
      result: result,
      quietBuild: quietBuild,
      surfaceFailureOutput: surfaceFailureOutput,
    );

    if (throwOnError && result.exitCode != ExitCode.success.code) {
      throw ShellException(
        formatShellExceptionMessage(
          command: script,
          workingDirectory: workingDir,
          exitCode: result.exitCode,
          outText: result.outText,
          errText: result.errText,
        ),
        result,
      );
    }

    return ProcessResultX.from(result);
  }

  /// Start a long-running process in the background (e.g. the LambdaTest tunnel)
  /// WITHOUT awaiting it, teeing its stdout+stderr into a buffer readable via
  /// [MplatrolProcess.output]. Call [MplatrolProcess.kill] when finished.
  Future<MplatrolProcess> start(String executable, List<String> arguments, {String? workingDirectory}) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory ?? Directory.current.path,
      );
    } on ProcessException catch (error) {
      throw redactProcessException(error);
    }
    final buffer = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(buffer.write);
    process.stderr.transform(utf8.decoder).listen(buffer.write);
    return MplatrolProcess(process, buffer);
  }

  /// Run [executable] attached to this terminal (stdin, stdout and stderr are
  /// inherited) and return its exit code. For interactive tools the user drives
  /// directly, such as `patrol develop` and its hot-restart keys.
  Future<int> runInteractive(String executable, List<String> arguments, {String? workingDirectory}) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory ?? Directory.current.path,
        mode: ProcessStartMode.inheritStdio,
      );
    } on ProcessException catch (error) {
      throw redactProcessException(error);
    }
    return process.exitCode;
  }

  /// Start a long-running process that the CLI does not own after launch.
  ///
  /// Use this only for tools that should survive the command, such as a local
  /// Android emulator cold start. For processes the CLI must later stop, use
  /// [start] and keep the returned handle.
  Future<void> startDetached(String executable, List<String> arguments, {String? workingDirectory}) async {
    try {
      await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory ?? Directory.current.path,
        mode: ProcessStartMode.detached,
      );
    } on ProcessException catch (error) {
      throw redactProcessException(error);
    }
  }

  /// Run [executable] with [arguments] as an exact argument vector (NOT parsed
  /// by a shell), capturing output. Use this instead of [run] when arguments
  /// contain spaces, quotes, or JSON that a shell-string parse would mangle
  /// (curl, codesign, zip, ...); no shell features (redirects/pipes/globs/&) are
  /// applied.
  Future<ProcessResultX> runArgs(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool throwOnError = true,
    bool forceVerbose = false,
    bool silent = false,
    bool quietBuild = false,
    bool surfaceFailureOutput = false,
    Duration? timeout,
    Future<void>? cancelOn,
  }) async {
    final logger = getDep<MplatrolLogger>();
    final result = await _runProcessArgs(
      executable,
      arguments,
      workingDirectory: workingDirectory ?? Directory.current.path,
      timeout: timeout,
      cancelOn: cancelOn,
    );
    if (!silent && forceVerbose) {
      final captured = ProcessResultX.from(result);
      captured.outLines.forEach(logger.info);
      captured.errLines.forEach(logger.err);
    }
    _surfaceFailureOutput(
      logger: logger,
      result: result,
      quietBuild: quietBuild,
      surfaceFailureOutput: surfaceFailureOutput,
    );
    if (throwOnError && result.exitCode != ExitCode.success.code) {
      throw ShellException(
        'command: ${formatRedactedCommandArgs(executable, arguments)}\n'
        'exitCode: ${result.exitCode}\n'
        'stderr: ${_formatExceptionOutput(result.stderr.toString())}',
        result,
      );
    }
    return ProcessResultX.from(result);
  }

  String? whichSync(String command) => process_run_which.whichSync(command);
}

void _surfaceFailureOutput({
  required MplatrolLogger logger,
  required ProcessResult result,
  required bool quietBuild,
  required bool surfaceFailureOutput,
}) {
  if (result.exitCode == ExitCode.success.code) {
    return;
  }
  if (!quietBuild && !surfaceFailureOutput) {
    return;
  }
  final captured = ProcessResultX.from(result);
  final lines = [...captured.outLines, ...captured.errLines];
  formatQuietBuildFailureTail(lines: lines, exitCode: result.exitCode).forEach(logger.err);
}

Future<ProcessResult> _runProcessArgs(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Duration? timeout,
  Future<void>? cancelOn,
}) async {
  try {
    if (timeout != null || cancelOn != null) {
      return await _runStoppableProcessArgs(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        timeout: timeout,
        cancelOn: cancelOn,
      );
    }
    return await Process.run(executable, arguments, workingDirectory: workingDirectory);
  } on ProcessException catch (error) {
    throw redactProcessException(error);
  }
}

/// Runs a process that is stopped (whole process tree) when [timeout] elapses
/// or [cancelOn] completes, whichever comes first.
Future<ProcessResult> _runStoppableProcessArgs(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Duration? timeout,
  Future<void>? cancelOn,
}) async {
  final process = await Process.start(executable, arguments, workingDirectory: workingDirectory);
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final stdoutDone = process.stdout.transform(utf8.decoder).forEach(stdoutBuffer.write);
  final stderrDone = process.stderr.transform(utf8.decoder).forEach(stderrBuffer.write);

  final stop = Completer<String>();
  void stopWith(String reason) {
    if (!stop.isCompleted) {
      stop.complete(reason);
    }
  }

  final timer = timeout == null ? null : Timer(timeout, () => stopWith('Timed out after ${timeout.inSeconds}s'));
  unawaited(cancelOn?.then((_) => stopWith('Stopped by caller')));
  final outcome = await Future.any<Object>([process.exitCode, stop.future]);
  timer?.cancel();

  var exitCode = ExitCode.tempFail.code;
  if (outcome is int) {
    exitCode = outcome;
  } else {
    await _terminateProcessTree(process.pid);
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        Process.killPid(process.pid, ProcessSignal.sigkill);
        return ExitCode.tempFail.code;
      },
    );
  }
  await Future.wait([stdoutDone, stderrDone]).timeout(const Duration(seconds: 5), onTimeout: () => const <void>[]);

  if (outcome is int) {
    return ProcessResult(process.pid, exitCode, stdoutBuffer.toString(), stderrBuffer.toString());
  }

  final command = formatRedactedCommandArgs(executable, arguments);
  return ProcessResult(
    process.pid,
    exitCode,
    stdoutBuffer.toString(),
    '$stderrBuffer$outcome: $command',
  );
}

Future<void> _terminateProcessTree(int rootPid) async => _terminate([...await _descendantPids(rootPid), rootPid]);

/// Stops every process [rootPid] started, and every process those started (SIGTERM, then SIGKILL after
/// 300 ms), but not [rootPid] itself: e.g. `mplatrol run` stopping its builds and test runs on SIGTERM.
Future<void> terminateDescendantProcesses(int rootPid) async => _terminate(await _descendantPids(rootPid));

Future<void> _terminate(List<int> targets) async {
  for (final pid in targets) {
    _killPid(pid, ProcessSignal.sigterm);
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final pid in targets) {
    _killPid(pid, ProcessSignal.sigkill);
  }
}

Future<List<int>> _descendantPids(int pid) async {
  final result = await Process.run('pgrep', ['-P', '$pid']);
  if (result.exitCode != ExitCode.success.code) {
    return const [];
  }
  final directChildren = const LineSplitter()
      .convert(result.stdout.toString())
      .map((line) => int.tryParse(line.trim()))
      .whereType<int>()
      .toList();
  final descendants = <int>[];
  for (final childPid in directChildren) {
    descendants.addAll(await _descendantPids(childPid));
    descendants.add(childPid);
  }
  return descendants;
}

void _killPid(int pid, ProcessSignal signal) {
  try {
    Process.killPid(pid, signal);
  } on ProcessException {
    // The process may have exited between discovery and signalling.
  }
}

@visibleForTesting
String formatShellExceptionMessage({
  required String command,
  required String workingDirectory,
  required int exitCode,
  required String outText,
  required String errText,
}) =>
    '''
command: ${_redactSensitiveText(command)}
workingDirectory: $workingDirectory
exitCode: $exitCode
outText:
${_formatExceptionOutput(outText)}
errText:
${_formatExceptionOutput(errText)}''';

/// All of [text], line by line as a shell exception shows it (ANSI codes stripped, secrets redacted, binary
/// output suppressed), without the exception's tail truncation: for a side file next to the exception.
String formatFullShellOutput(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return const LineSplitter().convert(normalized).map(_sanitizeExceptionLine).join('\n');
}

String _formatExceptionOutput(String text) {
  if (text.trim().isEmpty) {
    return '<empty>';
  }

  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = const LineSplitter().convert(normalized).map(_sanitizeExceptionLine).toList();
  final start = lines.length > MplatrolShell._exceptionOutputTailLines
      ? lines.length - MplatrolShell._exceptionOutputTailLines
      : 0;

  final buffer = StringBuffer();
  if (start > 0) {
    buffer.writeln('[output truncated to last ${MplatrolShell._exceptionOutputTailLines} of ${lines.length} lines]');
  }
  buffer.write(lines.skip(start).join('\n'));

  final output = buffer.toString();
  if (output.length <= MplatrolShell._exceptionOutputMaxChars) {
    return output;
  }
  return '[output truncated to last ${MplatrolShell._exceptionOutputMaxChars} chars]\n'
      '${output.substring(output.length - MplatrolShell._exceptionOutputMaxChars)}';
}

/// [value] quoted for a POSIX shell.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The last [maxLines] distinct non-noise lines of a failed quiet build, under a header naming [exitCode].
List<String> formatQuietBuildFailureTail({
  required List<String> lines,
  required int exitCode,
  int maxLines = MplatrolShell._buildFailureTailLines,
}) {
  final seen = <String>{};
  final filtered = [
    for (final line in lines)
      if (!isBuildNoise(line) && seen.add(line)) line,
  ];
  final tailSource = filtered.isEmpty ? const ['[build log contained only filtered xcodebuild chatter]'] : filtered;
  final start = tailSource.length > maxLines ? tailSource.length - maxLines : 0;
  final tailLineCount = tailSource.length - start;
  return [
    '— last $tailLineCount build-log line(s) (exit $exitCode); run with --verbose for the full log —',
    ...tailSource.skip(start),
  ];
}

String _sanitizeExceptionLine(String line) {
  final withoutAnsi = line.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  if (_looksLikeBinaryOutput(withoutAnsi)) {
    return '[non-text output suppressed]';
  }

  final withoutControls = withoutAnsi.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '?');
  final redacted = _redactSensitiveText(withoutControls);
  if (redacted.length <= MplatrolShell._exceptionLineMaxChars) {
    return redacted;
  }
  return '${redacted.substring(0, MplatrolShell._exceptionLineMaxChars)}... [line truncated]';
}

@visibleForTesting
String formatRedactedCommandArgs(String executable, List<String> arguments) =>
    [executable, ...redactSensitiveArguments(arguments)].join(' ');

@visibleForTesting
List<String> redactSensitiveArguments(List<String> arguments) {
  final redacted = <String>[];
  var redactNext = false;
  for (final argument in arguments) {
    if (redactNext) {
      redacted.add('[REDACTED]');
      redactNext = false;
      continue;
    }
    final lower = argument.toLowerCase();
    final inlineMatch = RegExp('^(--?(?:key|password|token|access-key|api-key|private-token))(=).+').firstMatch(lower);
    if (inlineMatch != null) {
      final separator = argument.indexOf('=');
      redacted.add('${argument.substring(0, separator + 1)}[REDACTED]');
      continue;
    }
    redacted.add(argument);
    redactNext = _isSensitiveFlag(lower);
  }
  return redacted;
}

@visibleForTesting
ProcessException redactProcessException(ProcessException error) => ProcessException(
      error.executable,
      redactSensitiveArguments(error.arguments),
      _redactSensitiveText(error.message),
      error.errorCode,
    );

bool _looksLikeBinaryOutput(String line) {
  if (line.isEmpty) {
    return false;
  }
  if (line.contains('\x00') || line.startsWith('\u0089PNG')) {
    return true;
  }
  if (line.contains('IHDR') && line.contains('IDAT')) {
    return true;
  }

  var suspicious = 0;
  var total = 0;
  for (final codeUnit in line.codeUnits) {
    total++;
    if (codeUnit == 0xfffd || codeUnit < 0x09 || (codeUnit > 0x0d && codeUnit < 0x20) || codeUnit == 0x7f) {
      suspicious++;
    }
  }
  return suspicious > 4 && suspicious / total > 0.02;
}

String _redactSensitiveText(String text) {
  var redacted = text;
  final patterns = <RegExp>[
    RegExp(r'(authorization:\s*(?:basic|bearer)\s+)[^\s]+', caseSensitive: false),
    RegExp(r'(private[-_]?token(?:=|:)\s*)[^\s&]+', caseSensitive: false),
    RegExp(r'(password(?:=|:)\s*)[^\s&]+', caseSensitive: false),
    RegExp(r'(api[-_]?key(?:=|:)\s*)[^\s&]+', caseSensitive: false),
    RegExp(r'(token=)[^\s&]+', caseSensitive: false),
    RegExp(r'(--key\s+)[^\]\s"]+', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    redacted = redacted.replaceAllMapped(pattern, (match) => '${match.group(1)}[REDACTED]');
  }
  return redacted;
}

bool _isSensitiveFlag(String argument) =>
    argument == '--key' ||
    argument == '-key' ||
    argument == '--password' ||
    argument == '-password' ||
    argument == '--token' ||
    argument == '-token' ||
    argument == '--access-key' ||
    argument == '-access-key' ||
    argument == '--api-key' ||
    argument == '-api-key' ||
    argument == '--private-token' ||
    argument == '-private-token';

/// A handle to a process started in the background via [MplatrolShell.start].
/// Exposes the accumulated stdout+stderr ([output]) and a [kill].
class MplatrolProcess {
  MplatrolProcess(this._process, this._outputBuffer);

  final Process _process;
  final StringBuffer _outputBuffer;

  /// All stdout+stderr captured from the process so far.
  String get output => _outputBuffer.toString();

  /// Terminate the process.
  void kill() => _process.kill();
}
