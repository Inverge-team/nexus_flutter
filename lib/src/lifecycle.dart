import 'package:flutter/widgets.dart';

/// Observes app foreground/background transitions and invokes the callbacks on
/// edges only (so a single background → foreground fires each once). Built on
/// [AppLifecycleListener]; safe to construct after `WidgetsFlutterBinding`.
class NexusLifecycle {
  NexusLifecycle({required this.onBackground, required this.onForeground}) {
    _listener = AppLifecycleListener(onStateChange: _onState);
  }

  final Future<void> Function() onBackground;
  final Future<void> Function() onForeground;

  late final AppLifecycleListener _listener;
  bool _backgrounded = false;

  void _onState(AppLifecycleState state) {
    final isBackground =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden;
    if (isBackground && !_backgrounded) {
      _backgrounded = true;
      onBackground();
    } else if (!isBackground && _backgrounded) {
      _backgrounded = false;
      onForeground();
    }
    // AppLifecycleState.inactive is a transient state — ignored.
  }

  void dispose() => _listener.dispose();
}
