/// Heuristic filter that decides whether a build-tool output line is noise that
/// can be hidden when running an iOS build/test "quietly" (see
/// [MplatrolShell.run]'s `quietBuild`).
///
/// It targets the high-volume xcodebuild and compiler output (per-file compile
/// commands and their cd/export preamble, Xcode build-phase headers, compiler
/// notes/warnings) while deliberately KEEPING everything else — Flutter/Dart
/// `print` output, package:test progress, XCTest results, `** BUILD FAILED **`,
/// and Patrol logs — so no test line is ever swallowed. The patterns therefore
/// err toward suppressing only lines that are unambiguously build-tool output;
/// a little build chatter leaking through is acceptable, hiding a test line is
/// not.
library;

/// Xcode build-phase task names that head a (usually large) build step.
/// xcodebuild prints these at the very start of a line.
const _xcodePhases = <String>[
  'CompileC',
  'CompileSwift',
  'CompileSwiftSources',
  'SwiftCompile',
  'SwiftDriver',
  'SwiftDriverJobDiscovery',
  'SwiftEmitModule',
  'SwiftMergeGeneratedHeaders',
  'EmitSwiftModule',
  'MergeSwiftModule',
  'Ld',
  'Libtool',
  'GenerateDSYMFile',
  'Strip',
  'CodeSign',
  'ProcessInfoPlistFile',
  'ProcessProductPackaging',
  'ProcessProductPackagingDER',
  'PhaseScriptExecution',
  'CpResource',
  'CpHeader',
  'Copy',
  'CopyPNGFile',
  'CopySwiftLibs',
  'CompileAssetCatalog',
  'CompileStoryboard',
  'CompileXIB',
  'LinkStoryboards',
  'Touch',
  'RegisterExecutionPolicyException',
  'RegisterWithLaunchServices',
  'Validate',
  'ValidateEmbeddedBinary',
  'CreateBuildDirectory',
  'WriteAuxiliaryFile',
  'MkDir',
  'SymLink',
  'ProcessPCH',
  'ProcessPCH++',
  'PrecompileSwiftBridgingHeader',
  'ExtractAppIntentsMetadata',
  'AppIntentsSSUTraining',
  'ProcessXCFramework',
  'ScanDependencies',
  'ClangStatCache',
  'ConstructStubExecutorLinkFileList',
  'CompileMetalFile',
  'MetalLink',
];

// Escape each verb — some (e.g. ProcessPCH++) contain regex-special chars.
// Require a build OPERAND after the verb (a path, quoted path, bracketed script
// tag, or `normal <arch>`) so a test/Dart line that merely starts with a word
// like "Copy"/"Touch"/"Validate"/"Strip" is NOT hidden.
final _phasePattern = RegExp(
  '^(${_xcodePhases.map(RegExp.escape).join('|')}) '
  r'(/|"|\[|normal\b|arm64\b|x86_64\b|i386\b|armv7\b)',
);

/// Indented cd/export/setenv preamble + the compiler/linker command echoes that
/// follow each Xcode phase — the single biggest source of xcodebuild volume.
final _commandEchoPattern = RegExp(
  r'^\s+(cd|export|setenv) '
  r'|^\s*/\S*/(usr/bin/)?(clang\+\+|clang|swiftc|swift-frontend|swift|ld|'
  r'libtool|actool|ibtool|dsymutil|lipo|metal|metallib)\b'
  r'|^\s+\(in target ',
);

/// Compiler diagnostics (`file:line:col: warning:`/`note:`, but NOT `error:` —
/// build errors are kept) and xcodebuild's build-system preamble.
final _diagnosticPattern = RegExp(
  r':\d+:\d+:\s+(warning|note):'
  r'|^\s*(warning|note): ' // bare xcodebuild/module-cache warnings + notes
  r'|^(ld|clang|clang\+\+): warning:' // tool-prefixed linker/compiler warnings
  r'|^\d+ (warning|note)s? generated\.'
  '|^(Build description|Build system information|Resolve Package Graph|'
  'Resolved source packages|Prepare packages|Computing target dependency|'
  'Create build description|GatherProvisioningInputs|Prepare build|'
  'Building targets in dependency order)',
);

/// xcodebuild echoes its command-line build settings before building (a header
/// plus a large indented `KEY = VALUE` block) and the full xcodebuild
/// invocation — the "build settings junk". `-quiet` suppresses these where we
/// can pass it; this also hides them on paths that cannot (e.g. flutter's own
/// xcodebuild call). KEY is upper-snake (≥3 chars) at indent, so test output
/// (prefixed by the reporter / `flutter:` / `I/flutter`) is not matched.
final _xcodeSettingsPattern = RegExp(
  '^(Command line invocation:'
  '|User defaults from command line:'
  '|Build settings from command line:'
  '|Build settings for action'
  '|Resolved source packages:)'
  r'|^\s+[A-Z][A-Z0-9_]{2,} = '
  r'|^\s+\S*/xcodebuild\b',
);

/// actool (asset-catalog) output that `-quiet` does not suppress: path-prefixed
/// `warning:`/`notice:` lines, its `/* com.apple.actool.* */` section markers,
/// and the build-intermediate file paths it lists. `error:` is deliberately NOT
/// matched (build errors must show), and these all start with `/` or `/*`, so
/// test/Patrol output (never does) is safe.
final _assetCatalogPattern = RegExp(
  '^/.*: (warning|notice): '
  r'|^/\*.*\*/\s*$'
  r'|^\s*/\S*(Intermediates\.noindex|assetcatalog_output|assetcatalog_generated)'
  r'\S*\s*$',
);

/// Compiler diagnostic context lines that follow a warning/note. Xcode's
/// `-quiet` mode still prints source snippets, caret/tilde markers, and
/// "In module ..." include chains for third-party warnings. The actual
/// `warning:` / `note:` line is handled above, and `error:` lines are
/// deliberately not matched.
const _swiftKeywordContextPattern = r'^\s*(extension|public|private|internal|open|class|func|let|var|return|'
    r'switch|case|catch|try|await|guard|if|else|for|while|self\.)\b';

const _diagnosticContextPatterns = [
  "^In module '[^']+' imported from ",
  "^While building module '[^']+':",
  '^In file included from ',
  r'^\s*\d+\s*\|\s*',
  r'^\s*\| ',
  r'^\s*[\^~` -]+\s*$',
  r'^\s*:\s*$',
  r'^\s*`- (warning|note):',
  r'^\s*(@available|@MainActor|@preconcurrency|@retroactive)\b',
  r'^\s*(#import|@interface)\b',
  r'^\s*static\s+(let|var)\b',
  _swiftKeywordContextPattern,
  r'^\s*\.[A-Za-z_][A-Za-z0-9_]*\b',
  r'^\s*[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\b',
  r'^\s*[A-Za-z_][A-Za-z0-9_]*(\?|\!)?\.[A-Za-z_][A-Za-z0-9_]*\(',
  r'^\s*[A-Za-z_][A-Za-z0-9_]*\[[^\]]+\]\s*=',
  r'^\s*clearCache\(',
  r'^\s*k[A-Z][A-Za-z0-9]+(,|\b)',
  r'^\s*(Sec[A-Za-z0-9_]+|ASWebAuthenticationSession)\b',
  r'^\s*(weak\s+var|optional\s+func)\b',
  r'^\s*(SecRequestSharedWebCredential|SecTrustEvaluate|completionHandler|print)\(',
  r'^\s*SecTrustEvaluateWithError\b',
  r'^\s*String\(describing:',
  r'^\s*,\s*default: <#default value#>',
  r'^\s*\?\? <#default value#>',
  r'^\s*AnyObject\s*$',
  r'^\s*authorizationMethod:',
  r'^\s*}\s*catch\b',
  r'^\s*}\s*else if\b',
  r'^\s*_[A-Za-z_][A-Za-z0-9_]*\(',
  r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*[A-Za-z_][A-Za-z0-9_.!?]*',
  r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*\.',
  r'^\s*_\s*$',
];

final _diagnosticContextPattern = RegExp(_diagnosticContextPatterns.join('|'));

/// Whether [line] is build-tool noise that may be hidden in a quiet build.
bool isBuildNoise(String line) =>
    _phasePattern.hasMatch(line) ||
    _commandEchoPattern.hasMatch(line) ||
    _diagnosticPattern.hasMatch(line) ||
    _xcodeSettingsPattern.hasMatch(line) ||
    _assetCatalogPattern.hasMatch(line) ||
    _diagnosticContextPattern.hasMatch(line);
