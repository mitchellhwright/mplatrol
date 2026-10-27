/// The four targets the unified login E2E can run on: a local Android device or emulator,
/// a local iOS device or simulator, and a LambdaTest real device for each
/// platform.
///
/// One Patrol test (`patrol_test/patrol_login_test.dart`) drives all four;
/// the variant only changes where it runs and how the device reaches staging.
enum ItVariant {
  androidLocal('android', 'Local Android device/emulator'),
  iosLocal('ios', 'Local iOS device/simulator'),
  ltAndroid('lt-android', 'LambdaTest Android (real device)'),
  ltIos('lt-ios', 'LambdaTest iOS (real device)');

  const ItVariant(this.id, this.label);

  /// CLI token, e.g. `lt-android`.
  final String id;

  /// Human-readable label shown in the interactive picker.
  final String label;

  /// The variant whose [id] matches [id], or null if none does.
  static ItVariant? fromId(String id) {
    for (final variant in ItVariant.values) {
      if (variant.id == id) {
        return variant;
      }
    }
    return null;
  }

  /// All variant ids, in declaration order, for help text and validation.
  static List<String> get ids => ItVariant.values.map((variant) => variant.id).toList();

  /// Pseudo-variant token used by `mplatrol run all`.
  static const String allId = 'all';

  /// Pseudo-variant token used by `mplatrol run lt-all`.
  static const String ltAllId = 'lt-all';

  /// Pseudo-variant token: the fastest available Android and iOS targets.
  static const String autoId = 'auto';

  /// Pseudo-variant token: the fastest available Android target.
  static const String autoAndroidId = 'auto-android';

  /// Pseudo-variant token: the fastest available iOS target.
  static const String autoIosId = 'auto-ios';

  /// The `auto` tokens, which pick local or LambdaTest per platform at run time.
  static const List<String> autoIds = [autoId, autoAndroidId, autoIosId];

  /// All accepted run target ids, including the concurrent all-variant and
  /// auto-selected modes.
  static List<String> get runIds => [...ids, ltAllId, allId, ...autoIds];
}
