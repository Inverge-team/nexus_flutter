import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/identity.dart';

void main() {
  group('NexusIdentity.wireContext', () {
    test('only exposes API-accepted keys (drops deviceModel etc.)', () {
      final id = NexusIdentity();
      id.deviceContext = {
        'osType': 'android',
        'osVersion': '14',
        'appVersion': '1.2.3+45',
        'deviceModel':
            'Samsung SM-A256E', // must NOT be sent — the strict API 400s on it
        'installTime': 1700000000000,
      };

      final wire = id.wireContext;

      expect(wire.keys, containsAll(['osType', 'osVersion', 'appVersion']));
      expect(wire.containsKey('deviceModel'), isFalse);
      expect(wire.containsKey('installTime'), isFalse);
    });

    test('omits absent keys rather than sending nulls', () {
      final id = NexusIdentity()..deviceContext = {'osType': 'ios'};
      final wire = id.wireContext;
      expect(wire, {'osType': 'ios'});
    });
  });
}
