import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The identified end-user, restored from disk.
class StoredIdentity {
  const StoredIdentity({
    required this.distinctId,
    this.email,
    this.name,
    this.traits = const {},
  });

  final String distinctId;
  final String? email;
  final String? name;
  final Map<String, Object?> traits;
}

/// Persists the identified end-user across app launches. Once
/// [NexusSessions.identify] has named the user, this remembers them (on device)
/// so every future session — including after a cold start — is attributed to the
/// same person, instead of starting anonymous. Cleared by [NexusSessions.reset].
///
/// Best-effort: any storage failure degrades to the previous behavior (the user
/// is simply not remembered), never an error on the telemetry path.
class IdentityStore {
  IdentityStore._();

  static const _key = 'nexus_identity';

  static Future<void> save({
    required String distinctId,
    String? email,
    String? name,
    Map<String, Object?> traits = const {},
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({
          'distinctId': distinctId,
          'email': ?email,
          'name': ?name,
          if (traits.isNotEmpty) 'traits': traits,
        }),
      );
    } catch (_) {
      /* best-effort — identity just won't persist this launch */
    }
  }

  static Future<StoredIdentity?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final map = (jsonDecode(raw) as Map).cast<String, Object?>();
      final id = map['distinctId'] as String?;
      if (id == null || id.isEmpty) return null;
      return StoredIdentity(
        distinctId: id,
        email: map['email'] as String?,
        name: map['name'] as String?,
        traits: (map['traits'] as Map?)?.cast<String, Object?>() ?? const {},
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      /* best-effort */
    }
  }
}
