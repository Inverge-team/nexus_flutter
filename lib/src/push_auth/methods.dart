/// An approval method the app can render. The backend only sends a device
/// challenges whose method (at that version or older) the device advertised,
/// so an app never receives something it can't show.
class NexusPushAuthMethod {
  const NexusPushAuthMethod(this.id, this.version, {required this.interactive, required this.requiresUserPresence});

  final String id;

  /// The highest protocol version of this method the app renders.
  final int version;

  /// Shows UI (a sheet); false = answered in the background.
  final bool interactive;

  /// Signed with the presence key (biometric / device credential prompt).
  final bool requiresUserPresence;

  Map<String, Object> toJson() => {'id': id, 'v': version};
}

/// The methods this SDK renders. Built-ins mirror the backend's registry
/// (`modules/push-auth/domain/methods`); [register] adds one an app renders
/// itself (with its own UI and `approve(response: …)`).
class NexusPushAuthMethods {
  NexusPushAuthMethods._();

  static const tap = NexusPushAuthMethod('tap', 1, interactive: true, requiresUserPresence: true);
  static const numberMatch = NexusPushAuthMethod('number_match', 1, interactive: true, requiresUserPresence: true);
  static const codeDisplay = NexusPushAuthMethod('code_display', 1, interactive: true, requiresUserPresence: true);
  static const silent = NexusPushAuthMethod('silent', 1, interactive: false, requiresUserPresence: false);

  static final Map<String, NexusPushAuthMethod> _all = {
    for (final m in [tap, numberMatch, codeDisplay, silent]) m.id: m,
  };

  static NexusPushAuthMethod? byId(String id) => _all[id];

  static List<NexusPushAuthMethod> get all => List.unmodifiable(_all.values);

  /// Add (or override) a method the app knows how to render. Takes effect at
  /// the next start / enrollment, when capabilities are sent to Nexus.
  static void register(NexusPushAuthMethod method) => _all[method.id] = method;
}
