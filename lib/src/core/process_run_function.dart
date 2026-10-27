import 'dart:io';

/// Runs a process to completion, like [Process.run].
///
/// Registered as a GetIt singleton so tests can stub processes that `MplatrolShell.runArgs` cannot run, e.g. ones that
/// need their own environment.
typedef ProcessRunFunction = Future<ProcessResult> Function(String executable, List<String> arguments,
    {String? workingDirectory, Map<String, String>? environment});
