import 'dart:convert';

import 'package:flutter/foundation.dart';

/// When a WebView that opened on an error page gets one recovery reload.
///
/// A probe script reports the page state as a signal string; an error page
/// reports a signal starting with [errorSignalPrefix]. A transient backend or
/// network error on the first page load is worth one reload, but only on the
/// steps listed in [retryableSteps], and never when the test injected the error.
@immutable
class WebViewErrorRetryPolicy {
  /// Creates a policy.
  ///
  /// Args:
  ///   retryableSteps: Journey step names on which an initial error page may be reloaded.
  ///   errorSignalPrefix: Prefix of the probe signal that reports an error page.
  const WebViewErrorRetryPolicy({required this.retryableSteps, this.errorSignalPrefix = 'ERRPAGE:'});

  /// Journey step names on which an initial error page may be reloaded.
  final Set<String> retryableSteps;

  /// Prefix of the probe signal that reports an error page.
  final String errorSignalPrefix;

  /// Whether [signal], seen on [stepName], earns the one recovery reload.
  ///
  /// Args:
  ///   signal: What the page probe reported.
  ///   stepName: The journey step that saw it.
  ///   environmentAllowsRetry: False where an error page is a real finding,
  ///     e.g. an environment whose error pages are never transient.
  ///   injectedFault: True when the test itself forced the error page.
  bool shouldRetry({
    required String signal,
    required String stepName,
    bool environmentAllowsRetry = true,
    bool injectedFault = false,
  }) =>
      signal.startsWith(errorSignalPrefix) &&
      environmentAllowsRetry &&
      !injectedFault &&
      retryableSteps.contains(stepName);

  /// JavaScript for the recovery: navigate to [reloadUrl] when the page is an
  /// error page and a URL is known, else reload the current page.
  String recoveryScript(String signal, {String? reloadUrl}) {
    final url = reloadUrl?.trim() ?? '';
    if (signal.startsWith(errorSignalPrefix) && url.isNotEmpty) {
      return 'window.location.replace(${jsonEncode(url)});';
    }
    return 'window.location.reload();';
  }
}
