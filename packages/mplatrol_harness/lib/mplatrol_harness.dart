/// In-app side of the `mplatrol` Patrol E2E orchestrator.
///
/// Fetches test logins from the runtime credential server, takes turns at
/// sign-in with sessions that share a login, reports runtime skips in the form
/// `mplatrol` reads from the device log, and wraps Patrol native automation
/// with deadline-bounded helpers.
library;

export 'package:mplatrol_harness/src/credentials/e2e_credentials.dart';
export 'package:mplatrol_harness/src/credentials/e2e_credentials_client.dart';
export 'package:mplatrol_harness/src/credentials/e2e_runtime_config.dart';
export 'package:mplatrol_harness/src/credentials/e2e_sign_in_slot_lease.dart';
export 'package:mplatrol_harness/src/credentials/runtime_server_transport.dart';
export 'package:mplatrol_harness/src/http/http_delegates.dart';
export 'package:mplatrol_harness/src/native/native_dialog_watchdog.dart';
export 'package:mplatrol_harness/src/native/native_element_visibility.dart';
export 'package:mplatrol_harness/src/native/native_operation_lifecycle.dart';
export 'package:mplatrol_harness/src/native/system_permission_dialog_page.dart';
export 'package:mplatrol_harness/src/skip/test_skip.dart';
export 'package:mplatrol_harness/src/webview/js_escape.dart';
export 'package:mplatrol_harness/src/webview/webview_error_retry_policy.dart';
export 'package:mplatrol_harness/src/widgets/keyed_page_object.dart';
export 'package:mplatrol_harness/src/widgets/page_leaf_route.dart';
export 'package:mplatrol_harness/src/widgets/screen_text.dart';
