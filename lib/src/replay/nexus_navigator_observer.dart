import 'package:flutter/widgets.dart';

import '../nexus.dart';

/// Reports route changes to Nexus so session replay's **Pages** tab shows the
/// screens a user moved through. Add it to your app's navigator:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [NexusNavigatorObserver()],
///   ...
/// )
/// ```
///
/// Uses each route's `settings.name`, so name your routes (or push with
/// `RouteSettings(name: ...)`); unnamed routes fall back to a generic label.
/// For custom navigation, call `context.nexus.trackScreen('...')` directly.
class NexusNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _track(newRoute);
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(previousRoute); // the route we're returning to becomes current
    super.didPop(route, previousRoute);
  }

  void _track(Route<dynamic>? route) {
    if (route is! PageRoute) return; // ignore dialogs, popups, etc.
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) {
      _safeTrack(name);
    } else {
      _safeTrack('screen');
    }
  }

  void _safeTrack(String name) {
    if (!Nexus.isInitialized) return;
    Nexus.instance.trackScreen(name);
  }
}
