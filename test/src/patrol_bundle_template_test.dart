// Runs the real globally activated patrol_cli, which the Linux CI image does not have.
@TestOn('mac-os')
library;

import 'package:get_it/get_it.dart';
import 'package:mplatrol/src/core/mplatrol_shell.dart';
import 'package:mplatrol/src/core/platform_wrapper.dart';
import 'package:mplatrol/src/patrol_test_bundle.dart';
import 'package:test/test.dart';

import '../helpers/helpers.dart';

void main() {
  setUp(() async {
    await scaffoldMockDependencies();
    GetIt.I
      ..allowReassignment = true
      ..registerSingleton<MplatrolShell>(MplatrolShell.constructGlobalInstance())
      ..registerSingleton<PlatformWrapper>(PlatformWrapper.constructGlobalInstance());
  });

  test('generates Patrol scaffolding from the activated patrol_cli without a build', () async {
    final bundle = await generatePatrolBundleTemplatrole('patrol_login_test');

    expect(bundle, contains('// START: GENERATED TEST IMPORTS'));
    expect(bundle, contains('// END: GENERATED TEST GROUPS'));
    expect(bundle, contains('patrol_runtime_ports.dart'));
    expect(bundle, contains("import 'patrol_login_test.dart' as patrol_login_test;"));
  });
}
