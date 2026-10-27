import 'package:mplatrol/src/build_log_filter.dart';
import 'package:test/test.dart';

void main() {
  group('isBuildNoise', () {
    // The hard invariant: test / Patrol / Flutter output and build FAILURES are
    // never hidden — only xcodebuild/compiler chatter is.
    const kept = [
      'flutter: LoginFlow booting',
      'I/flutter ( 1234): PATROL_RESULT name=patrol_login_test passed=1',
      '00:03 +1: patrol_login_test reaches accounts after credentials + MFA',
      "Test Case '-[login_faults_test test_fast_fails]' passed (1.2 seconds)",
      'Test Suite RunnerUITests.xctest started',
      '** BUILD FAILED **',
      '** TEST FAILED **',
      '/Users/me/app/lib/foo.swift:10:5: error: use of undeclared identifier',
      'PATROL_APPREADY_TIMEOUT: app never completed the handshake',
      'RunnerUITests running Dart test: patrol_login_test happy path',
      'flutter: loaded accounts = 3', // ' = ' but not an indented upper-snake key
      'flutter: showing warning: low balance banner', // warning: not at line start
      'Copy completed for 5 accounts', // phase verb but no build operand
      'Validate that the error banner is shown',
      'All tests passed!',
      'Some tests failed.',
    ];
    for (final line in kept) {
      test('keeps: $line', () => expect(isBuildNoise(line), isFalse));
    }

    final moduleCacheWarningLine = [
      'warning: /Users/runner/Library/Developer/Xcode/DerivedData/',
      'ModuleCache.noindex/X/OpenTelemetryApi-Y.pcm: No such file or ',
      'directory',
    ].join();
    final appIconWarningLine = [
      '/Users/me/app/ios/Runner/Assets.xcassets:./AppIcon.appiconset/',
      '(null)[2d][Icon-App-1024x1024@1x.png]: warning: The app icon set ',
      '"AppIcon" has 16 unassigned children.',
    ].join();
    final appIconNoticeLine = [
      '/Users/me/app/ios/Runner/Assets.xcassets:./AppIcon.appiconset/',
      '[][ipad][76x76]: notice: 76x76@1x app icons only apply to iPad apps',
    ].join();
    final assetsCarLine = [
      '/Users/me/app/ios/build/xcui-lt/Build/Intermediates.noindex/',
      'Runner.build/Profile-iphoneos/Runner.build/assetcatalog_output/',
      'thinned/Assets.car',
    ].join();
    final sslSnippetLine = [
      '  7069 |                         status = ',
      'SSLSetProtocolVersionMax(sslContext, maxProtocol);',
    ].join();
    final sharedWebCredentialLine = [
      '        SecRequestSharedWebCredential(domain as CFString?, ',
      'account as CFString?) { (credentials, error) -> () in',
    ].join();
    final notificationDelegateLine = [
      '  optional func application(_ application: UIApplication, ',
      'didReceiveRemoteNotification userInfo: [AnyHashable : Any], ',
      'fetchCompletionHandler completionHandler: @escaping ',
      '(UIBackgroundFetchResult) -> Void) -> Bool}',
    ].join();
    final targetViewControllerLine = [
      '            targetVC = ',
      'UIApplication.shared.keyWindow!.rootViewController!',
    ].join();

    final hidden = [
      'CompileSwift normal arm64 /Users/me/app/Runner.swift',
      'CompileC /path/x.o /path/x.m normal arm64 objective-c',
      '    cd /Users/me/app/ios',
      '    export PATH=/usr/bin:/bin',
      '    /Applications/Xcode.app/Contents/Developer/usr/bin/clang -x objc -c a.m',
      'Ld /path/Runner.app/Runner normal',
      'CodeSign /path/Runner.app',
      'ProcessInfoPlistFile /path/Info.plist /path/src/Info.plist',
      'CompileAssetCatalog /path/Assets.car /path/Assets.xcassets',
      'note: Building targets in dependency order',
      '/Users/me/app/lib/foo.swift:10:5: warning: unused variable',
      '12 warnings generated.',
      'Build description signature: abc123',
      // xcodebuild's command-line settings echo (the "build settings junk").
      'Build settings from command line:',
      'Command line invocation:',
      '    SDKROOT = iphoneos',
      '    PRODUCT_BUNDLE_IDENTIFIER = com.example.demo.staging.Runner',
      '    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing',
      // xcodebuild module-cache + linker warnings ('-quiet' keeps warnings).
      moduleCacheWarningLine,
      'ld: warning: directory not found for option',
      // actool asset-catalog noise (path-prefixed warning/notice, markers, paths).
      appIconWarningLine,
      appIconNoticeLine,
      '/* com.apple.actool.compilation-results */',
      assetsCarLine,
      // Swift/Clang diagnostic context lines that follow warnings/notes.
      "In module 'Security' imported from /Users/me/Pods/GCDAsyncSocket.h:12:",
      "While building module 'CardAppMobile':",
      'In file included from <module-includes>:1:',
      sslSnippetLine,
      '       |                                  ^',
      'extension MessageCenter: MessageCenterProtocol {',
      '                         ^',
      '                         @MainActor',
      '@MainActor @objc public func display()}',
      '        switch (result) {',
      '            self.pushsdkDelegate.messageCenterInboxUpdated()',
      'public class PushSdkProxy {',
      'private let UseOperationPrompt = String(kSecUseOperationPrompt)',
      'button.contentEdgeInsets = .init(top: 6, left: 16, bottom: 6, right: 16)',
      '            kUTTypeItem, kUTTypeContent, kUTTypeCompositeContent,',
      sharedWebCredentialLine,
      '        weak var weakSelf = self',
      notificationDelegateLine,
      '    print("CardAppSDK - publicKeyPath: \\(publicKeyPath)")',
      targetViewControllerLine,
      '                                                       ?? <#default value#>',
      [
        '                                                            ',
        '                        , default: <#default value#>',
      ].join(),
      '                                         String(describing:  )',
      '      completionHandler([.alert, .badge, .sound])',
      '    _',
      '            .carrierName',
      '            guard let activity = provider.getActivity(),',
      '            _pushsdkCheckActivities(activityBlock: activityBlock)',
      '            } else if #available(iOS 15.4, macCatalyst 15.4, *) {',
      '^                               ~~~~~~~~~~~~~~~~~~~~~~~',
      '                                @retroactive CustomStringConvertible',
      '3 |',
      '     :',
      ' 987 |',
      '                                                   AnyObject',
      '                    } catch let error as SecureConversations.PendingInteraction.Error {',
      '            authorizationMethod: .siteApiKey(',
      '        contentEdgeInsets = .init(top: 6, left: 16, bottom: 6, right: 16)',
      '    SecTrustEvaluate(trust, &result)',
      '           SecTrustCopyCertificateChain',
      '    static let sharedProcessPool = WKProcessPool()',
      '                clearCache()',
      '            realSettings["selectionGranularity"] = configuration.selectionGranularity.rawValue',
      '            webView?.clearCache()',
      '                                                                     ASWebAuthenticationSession',
      '^                     ~~~~~~~~~',
      '                      @retroactive Encodable',
    ];
    for (final line in hidden) {
      test('hides: $line', () => expect(isBuildNoise(line), isTrue));
    }
  });
}
