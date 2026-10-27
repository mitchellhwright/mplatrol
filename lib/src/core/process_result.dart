import 'dart:convert';
import 'dart:io';

/// An adapter to the [ProcessResult] class.
///
/// Having this wrapper allows us to test and mock various states easier, especially since the [ProcessResult] class is
///   final beyond Dart version 3.5
class ProcessResultX {
  ProcessResultX({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.pid,
    this.processResult,
  });

  /// Exit code for the process.
  ///
  /// See [Process.exitCode] for more information in the exit code
  /// value.
  final int exitCode;

  /// Standard output from the process. The value used for the
  /// `stdoutEncoding` argument to `Process.run` determines the type. If
  /// `null` was used, this value is of type `List<int>` otherwise it is
  /// of type `String`.
  final dynamic stdout;

  /// Standard error from the process. The value used for the
  /// `stderrEncoding` argument to `Process.run` determines the type. If
  /// `null` was used, this value is of type `List<int>`
  /// otherwise it is of type `String`.
  final dynamic stderr;

  /// Process id of the process.
  final int pid;

  /// The original [ProcessResult] this was constructed from.
  final ProcessResult? processResult;

  Iterable<String> _outStringToLines(String out) => LineSplitter.split(out);

  /// Join the out lines for a quick string access.
  String get outText => outLines.join('\n');

  /// Join the out lines for a quick string access.
  String get errText => errLines.join('\n');

  /// Out line lists
  Iterable<String> get outLines => _outStringToLines(stdout.toString());

  /// Line lists
  Iterable<String> get errLines => _outStringToLines(stderr.toString());

  factory ProcessResultX.from(ProcessResult result) {
    return ProcessResultX(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      pid: result.pid,
      processResult: result,
    );
  }
}
