import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_flutter/src/shield/jose.dart';

/// Vectors produced by node:crypto with the backend's exact formulas
/// (modules/shield/domain/challenge.ts + jose.ts), so the SDK and the server
/// can never silently disagree on a hash or a signature encoding.
void main() {
  const x = 'rMum7zxotSjUgGOzNoM8ehbOvkgLoqOUez_sEXKnqTs';
  const y = '7MFs2Te7FkGw38onERNenrvGW159Xi-xPomcMM2hQkk';

  test('RFC 7638 thumbprint matches the backend', () {
    expect(jwkThumbprint(x, y), 'Daqbq5hitJRmNCWOdroSsdxTCEIdWd9qPlXs-pzER5c');
  });

  test('binding hashes match the backend', () {
    String hex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    expect(hex(bindingHash('CH', 'Daqbq5hitJRmNCWOdroSsdxTCEIdWd9qPlXs-pzER5c')), '95f7ed718bb832a584b18fc6d67bf690d5e69645fcbcd8e27d97025798e5cd6c');
    expect(hex(keyAttestationChallenge('CH')), '18c60d03f850f41618e24af0ea65e15b09381a200afd80caec17c05ffc849a7e');
  });

  test('DER ECDSA converts to a 64-byte JOSE signature', () {
    final jose = derToJose(base64.decode('MEUCIQCGadBmPJ8yCrz4Tynr0i9fMqBImP2ZjWjuKXxgPzwcwQIgXMjaOKb1WLFyCvaLViT17uetdnvNpC3BDbFZsw05NMI='));
    expect(jose.length, 64);
  });

  test('proof-of-work counts leading zero bits', () {
    final b = bindingHash('c', 'k');
    final n = solvePow({'binding': b, 'difficulty': 10});
    expect(powBits(b, n), greaterThanOrEqualTo(10));
  });
}
