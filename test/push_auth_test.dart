import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/push_auth/canonical.dart';
import 'package:nexus_flutter/src/push_auth/methods.dart';
import 'package:nexus_flutter/src/shield/jose.dart';

void main() {
  group('canonical details hash', () {
    test('sorts keys, keeps array order, no whitespace', () {
      expect(canonicalJson({'b': 1, 'a': [2, {'d': true, 'c': null}]}), '{"a":[2,{"c":null,"d":true}],"b":1}');
    });

    test('matches the backend vector (modules/push-auth/domain/push-auth.spec.ts)', () {
      // Change BOTH sides together — a mismatch makes every approval fail with details_mismatch.
      expect(
        detailsHash(
          message: 'Sign in to Banzeeni',
          fields: [
            {'label': 'Amount', 'value': '25,000 IQD'},
            {'label': 'Payee', 'value': 'Erbil Coffee'},
          ],
          context: {'ip': '203.0.113.7', 'location': 'Erbil, IQ', 'device': 'Chrome on macOS'},
        ),
        'LASlr5ptK3dwvTNsx1wBiRDig8FpcPrMBb9kp2Td5es',
      );
    });

    test('non-ASCII text hashes like the backend (UTF-8, unescaped)', () {
      expect(canonicalJson({'m': 'تسجيل الدخول — ✓'}), '{"m":"تسجيل الدخول — ✓"}');
    });
  });

  group('methods', () {
    test('built-ins advertise id + version, silent needs no user', () {
      expect(NexusPushAuthMethods.all.map((m) => m.toJson()).toList(), [
        {'id': 'tap', 'v': 1},
        {'id': 'number_match', 'v': 1},
        {'id': 'code_display', 'v': 1},
        {'id': 'silent', 'v': 1},
      ]);
      expect(NexusPushAuthMethods.silent.requiresUserPresence, isFalse);
      expect(NexusPushAuthMethods.numberMatch.requiresUserPresence, isTrue);
    });

    test('register adds a custom method', () {
      NexusPushAuthMethods.register(const NexusPushAuthMethod('qr_cross_device', 1, interactive: true, requiresUserPresence: true));
      expect(NexusPushAuthMethods.byId('qr_cross_device'), isNotNull);
    });
  });

  test('enrollment attestation challenge is SHA-256 of the domain-separated token', () {
    expect(b64url(sha256Of('nexus-push-auth/v1/ka\npaet_fixture_enrollment_token')).length, 43);
  });
}
