import 'package:mplatrol/src/it_variant.dart';
import 'package:test/test.dart';

void main() {
  group('ItVariant', () {
    group('id and label', () {
      test('androidLocal exposes its tokens', () {
        expect(ItVariant.androidLocal.id, 'android');
        expect(ItVariant.androidLocal.label, 'Local Android device/emulator');
      });

      test('iosLocal exposes its tokens', () {
        expect(ItVariant.iosLocal.id, 'ios');
        expect(ItVariant.iosLocal.label, 'Local iOS device/simulator');
      });

      test('ltAndroid exposes its tokens', () {
        expect(ItVariant.ltAndroid.id, 'lt-android');
        expect(ItVariant.ltAndroid.label, 'LambdaTest Android (real device)');
      });

      test('ltIos exposes its tokens', () {
        expect(ItVariant.ltIos.id, 'lt-ios');
        expect(ItVariant.ltIos.label, 'LambdaTest iOS (real device)');
      });
    });

    group('fromId', () {
      test('returns the matching variant for each valid id', () {
        expect(ItVariant.fromId('android'), ItVariant.androidLocal);
        expect(ItVariant.fromId('ios'), ItVariant.iosLocal);
        expect(ItVariant.fromId('lt-android'), ItVariant.ltAndroid);
        expect(ItVariant.fromId('lt-ios'), ItVariant.ltIos);
      });

      test('returns null for an unknown id', () {
        expect(ItVariant.fromId('windows'), isNull);
      });

      test('returns null for an empty id', () {
        expect(ItVariant.fromId(''), isNull);
      });
    });

    group('ids', () {
      test('lists every variant id in declaration order', () {
        expect(ItVariant.ids, ['android', 'ios', 'lt-android', 'lt-ios']);
      });
    });
  });
}
