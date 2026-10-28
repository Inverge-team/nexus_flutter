import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The small slice of JOSE Shield needs on the client: base64url, RFC 7638
/// thumbprints, DER → JOSE (r‖s) signature conversion, and the binding hashes
/// the backend expects (see the backend's `domain/challenge.ts`).

String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String b64urlJson(Object json) => b64url(utf8.encode(jsonEncode(json)));

Uint8List sha256Bytes(List<int> data) => Uint8List.fromList(sha256.convert(data).bytes);

Uint8List sha256Of(String s) => sha256Bytes(utf8.encode(s));

/// RFC 7638 JWK thumbprint: SHA-256 over the required members in lexicographic order.
String jwkThumbprint(String x, String y) =>
    b64url(sha256.convert(utf8.encode('{"crv":"P-256","kty":"EC","x":"$x","y":"$y"}')).bytes);

/// `SHA-256("nexus-shield/v1\n" ‖ challenge ‖ "\n" ‖ jkt)` — what App Attest,
/// Play Integrity, Turnstile and proof-of-work commit to.
Uint8List bindingHash(String challenge, String jkt) => sha256Of('nexus-shield/v1\n$challenge\n$jkt');

/// `SHA-256("nexus-shield/v1/ka\n" ‖ challenge)` — the Android Keystore
/// attestation challenge for a NEW device key.
Uint8List keyAttestationChallenge(String challenge) => sha256Of('nexus-shield/v1/ka\n$challenge');

/// ECDSA DER `SEQUENCE { INTEGER r, INTEGER s }` → 64-byte r‖s (JWS ES256).
Uint8List derToJose(Uint8List der) {
  var i = 0;
  if (der[i++] != 0x30) throw const FormatException('not a DER sequence');
  var len = der[i++];
  if (len & 0x80 != 0) i += len & 0x7f; // long-form length (never > 2 bytes here)
  Uint8List readInt() {
    if (der[i++] != 0x02) throw const FormatException('not a DER integer');
    final n = der[i++];
    var v = der.sublist(i, i + n);
    i += n;
    while (v.length > 32 && v[0] == 0) {
      v = v.sublist(1);
    }
    if (v.length > 32) throw const FormatException('integer too long');
    return Uint8List(32)..setRange(32 - v.length, 32, v);
  }

  final r = readInt();
  final s = readInt();
  return Uint8List.fromList([...r, ...s]);
}

final _rng = Random.secure();

String randomId([int bytes = 16]) => b64url(List<int>.generate(bytes, (_) => _rng.nextInt(256)));

/// Leading zero bits of SHA-256(binding ‖ nonce) — the proof-of-work check.
int powBits(Uint8List binding, String nonce) {
  final h = sha256.convert([...binding, ...utf8.encode(nonce)]).bytes;
  var bits = 0;
  for (final b in h) {
    if (b == 0) {
      bits += 8;
      continue;
    }
    var v = b;
    while (v & 0x80 == 0) {
      bits++;
      v <<= 1;
    }
    break;
  }
  return bits;
}

/// Find a nonce meeting [difficulty]. Runs in an isolate (see shield_service).
String solvePow(Map<String, Object> args) {
  final binding = args['binding'] as Uint8List;
  final difficulty = args['difficulty'] as int;
  for (var n = 0; ; n++) {
    final s = n.toRadixString(36);
    if (powBits(binding, s) >= difficulty) return s;
  }
}
