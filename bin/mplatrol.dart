import 'dart:io';

import 'package:mplatrol/mplatrol.dart';

Future<void> main(List<String> args) async {
  final code = await MplatrolCommandRunner().run(args);
  await Future.wait<void>([stdout.close(), stderr.close()]);
  exit(code);
}
