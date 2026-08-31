import 'package:flutter/widgets.dart';

import 'nexus.dart';

/// Makes the initialised [Nexus] available through the widget tree. Optional —
/// `context.nexus` falls back to the global [Nexus.instance] when no scope is
/// present — but wrapping your app lets you inject a test instance.
///
/// ```dart
/// runApp(NexusScope(child: MyApp()));
/// ```
class NexusScope extends InheritedWidget {
  const NexusScope({super.key, this.nexus, required super.child});

  /// Override instance (e.g. in tests). Defaults to [Nexus.instance].
  final Nexus? nexus;

  Nexus get _resolved => nexus ?? Nexus.instance;

  static Nexus of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<NexusScope>();
    return scope?._resolved ?? Nexus.instance;
  }

  @override
  bool updateShouldNotify(NexusScope oldWidget) => nexus != oldWidget.nexus;
}

/// `context.nexus` — access the SDK from any widget.
extension NexusBuildContext on BuildContext {
  /// The app-wide Nexus instance. Use it as `context.nexus.realtime`,
  /// `context.nexus.events`, `context.nexus.errors`, …
  Nexus get nexus => NexusScope.of(this);
}
