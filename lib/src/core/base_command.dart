import 'dart:async';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:meta/meta.dart';
import 'package:mplatrol/src/core/dependencies.dart';
import 'package:mplatrol/src/core/file_system.dart';
import 'package:mplatrol/src/core/mplatrol_logger.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';

/// Base class of every `mplatrol` command: resolves the shared services and validates input before running.
abstract class BaseCommand extends Command<int> {
  @protected
  MplatrolLogger get logger => getDep<MplatrolLogger>();
  @protected
  MplatrolShell get shell => getDep<MplatrolShell>();
  @protected
  FileSystem get fileSystem => getDep<FileSystem>();
  @protected
  PlatformWrapper get platformWrapper => getDep<PlatformWrapper>();

  /// Runs this command.
  Future<int> runCommand();

  /// Throws a [UsageException] when the parsed arguments are invalid.
  void validateInput();

  @override
  ArgResults get argResults => super.argResults!;

  /// Override [runCommand] rather than this method.
  @override
  FutureOr<int>? run() async {
    validateInput();
    return runCommand();
  }
}
