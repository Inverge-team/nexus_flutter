import 'dart:convert';

import '../shield/jose.dart';

/// What the device shows is what the device signs. The approval signs the
/// SHA-256 of the canonical details the device DISPLAYED — computed here, on
/// the device, never taken from the server — so details altered after display
/// can't be approved. Must match the backend's `canonical.ts` byte for byte;
/// `test/push_auth_test.dart` pins the shared vector.
String canonicalJson(Object? value) {
  if (value == null) return 'null';
  if (value is String || value is bool) return jsonEncode(value);
  if (value is int) return value.toString();
  if (value is num) {
    if (!value.isFinite) throw ArgumentError('non-finite number');
    return value == value.truncate() ? value.toInt().toString() : jsonEncode(value);
  }
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(value[k])}').join(',')}}';
  }
  throw ArgumentError('unsupported type ${value.runtimeType}');
}

const detailsVersion = 1;

/// base64url SHA-256 of the canonical details — the `dh` every approval signs.
String detailsHash({required String message, required List<Map<String, String>> fields, required Map<String, String> context}) =>
    b64url(sha256Of(canonicalJson({'v': detailsVersion, 'message': message, 'fields': fields, 'context': context})));
