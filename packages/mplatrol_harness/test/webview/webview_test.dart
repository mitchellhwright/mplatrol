import 'package:flutter_test/flutter_test.dart';
import 'package:mplatrol_harness/mplatrol_harness.dart';

void main() {
  const policy = WebViewErrorRetryPolicy(retryableSteps: {'login_form'});

  group('WebViewErrorRetryPolicy.shouldRetry', () {
    test('retries an error page on a retryable step', () {
      expect(policy.shouldRetry(signal: 'ERRPAGE:502', stepName: 'login_form'), isTrue);
    });

    test('does not retry a page that is not an error page', () {
      expect(policy.shouldRetry(signal: 'READY', stepName: 'login_form'), isFalse);
    });

    test('does not retry on other steps', () {
      expect(policy.shouldRetry(signal: 'ERRPAGE:502', stepName: 'home'), isFalse);
    });

    test('does not retry where the environment disallows it', () {
      expect(
        policy.shouldRetry(signal: 'ERRPAGE:502', stepName: 'login_form', environmentAllowsRetry: false),
        isFalse,
      );
    });

    test('does not retry an injected fault', () {
      expect(policy.shouldRetry(signal: 'ERRPAGE:502', stepName: 'login_form', injectedFault: true), isFalse);
    });

    test('honours a custom signal prefix', () {
      const custom = WebViewErrorRetryPolicy(retryableSteps: {'a'}, errorSignalPrefix: 'ERR/');
      expect(custom.shouldRetry(signal: 'ERR/x', stepName: 'a'), isTrue);
      expect(custom.shouldRetry(signal: 'ERRPAGE:x', stepName: 'a'), isFalse);
    });
  });

  group('WebViewErrorRetryPolicy.recoveryScript', () {
    test('navigates to the reload URL, JSON-quoted', () {
      expect(policy.recoveryScript('ERRPAGE:1', reloadUrl: ' https://example.com/a?b="c" '),
          r'window.location.replace("https://example.com/a?b=\"c\"");');
    });

    test('reloads without a URL', () {
      expect(policy.recoveryScript('ERRPAGE:1', reloadUrl: '  '), 'window.location.reload();');
      expect(policy.recoveryScript('ERRPAGE:1'), 'window.location.reload();');
    });

    test('reloads when the page is not an error page', () {
      expect(policy.recoveryScript('READY', reloadUrl: 'https://example.com'), 'window.location.reload();');
    });
  });

  group('jsEscape', () {
    test('leaves plain text alone', () {
      expect(jsEscape('plain text 123'), 'plain text 123');
    });

    test('escapes backslashes before quotes', () {
      expect(jsEscape(r"a\'b"), r"a\\\'b");
    });

    test('escapes every line terminator', () {
      expect(jsEscape('a\nb\rc\u2028d\u2029e'), r'a\nb\rc\u2028d\u2029e');
    });

    test('handles an empty string', () {
      expect(jsEscape(''), '');
    });
  });
}
