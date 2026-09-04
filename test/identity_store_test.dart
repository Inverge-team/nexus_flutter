import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/identity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('IdentityStore', () {
    test('load returns null when the user was never identified (anonymous)', () async {
      expect(await IdentityStore.load(), isNull);
    });

    test('save then load restores the identity across a launch', () async {
      await IdentityStore.save(
        distinctId: 'user-42',
        name: 'Sam',
        traits: {'plan': 'pro'},
      );
      final restored = await IdentityStore.load();
      expect(restored, isNotNull);
      expect(restored!.distinctId, 'user-42');
      expect(restored.name, 'Sam');
      expect(restored.traits['plan'], 'pro');
    });

    test('clear forgets the identity — next launch starts anonymous', () async {
      await IdentityStore.save(distinctId: 'user-42');
      await IdentityStore.clear();
      expect(await IdentityStore.load(), isNull);
    });
  });
}
