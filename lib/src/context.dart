import 'package:flutter/widgets.dart';

import 'nexus.dart';
import 'replay/replay_controller.dart';

/// Makes the initialised [Nexus] available through the widget tree, and — when
/// session replay is enabled — installs the RepaintBoundary + pointer listener
/// the recorder captures from. Optional for access (`context.nexus` falls back
/// to the global [Nexus.instance]), but **required** for replay.
///
/// ```dart
/// runApp(NexusScope(child: MyApp()));
/// ```
class NexusScope extends StatelessWidget {
  const NexusScope({super.key, this.nexus, required this.child});

  /// Override instance (e.g. in tests). Defaults to [Nexus.instance].
  final Nexus? nexus;

  final Widget child;

  Nexus get _resolved => nexus ?? Nexus.instance;

  static Nexus of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_NexusInherited>();
    return scope?.nexus ?? Nexus.instance;
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolved;
    Widget tree = child;

    final replay = _replayController(resolved);
    if (replay != null) {
      // A translucent top-level Listener still receives pointer events even when
      // children handle them (all listeners on the hit path are notified), so
      // taps/drags are captured without interfering with the app.
      tree = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => replay.onPointerDown(e.localPosition),
        onPointerMove: (e) => replay.onPointerMove(e.localPosition),
        onPointerUp: (e) => replay.onPointerUp(e.localPosition),
        child: RepaintBoundary(key: replay.repaintBoundaryKey, child: child),
      );
    }

    return _NexusInherited(nexus: resolved, child: tree);
  }

  /// The replay controller iff replay is enabled and the instance is ready.
  static NexusReplayController? _replayController(Nexus nexus) {
    try {
      return nexus.config.replayEnabled ? nexus.replay.controller : null;
    } catch (_) {
      return null; // instance not fully initialised (e.g. in a test)
    }
  }
}

class _NexusInherited extends InheritedWidget {
  const _NexusInherited({required this.nexus, required super.child});

  final Nexus nexus;

  @override
  bool updateShouldNotify(_NexusInherited oldWidget) => nexus != oldWidget.nexus;
}

/// `context.nexus` — access the SDK from any widget.
extension NexusBuildContext on BuildContext {
  /// The app-wide Nexus instance. Use it as `context.nexus.realtime`,
  /// `context.nexus.events`, `context.nexus.errors`, …
  Nexus get nexus => NexusScope.of(this);
}
