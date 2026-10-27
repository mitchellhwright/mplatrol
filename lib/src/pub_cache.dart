import 'package:path/path.dart' as p;

/// The pub cache directory for [environment]: `PUB_CACHE` when set, otherwise
/// `$HOME/.pub-cache`; null when neither is available.
String? pubCacheRoot(Map<String, String> environment) {
  final pubCache = environment['PUB_CACHE'];
  if (pubCache != null && pubCache.isNotEmpty) {
    return pubCache;
  }
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    return null;
  }
  return p.join(home, '.pub-cache');
}
