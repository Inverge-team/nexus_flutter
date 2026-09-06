import 'package:flutter/widgets.dart';

import '../inapp/inapp_overlay.dart';
import '../surveys/survey_overlay.dart';

/// Auto-mounts the survey + in-app message overlays without the app touching
/// `MaterialApp.builder`. It locates the app's root [Overlay] (by walking the
/// element tree) and inserts a single transparent entry that hosts both
/// overlays. Touches pass through when nothing is showing.
///
/// Opt out with `NexusConfig(autoShowOverlay: false)` and mount
/// `NexusSurveyOverlay` / `NexusInAppOverlay` yourself.
class NexusAutoOverlay {
  OverlayEntry? _entry;
  int _tries = 0;

  /// Ensure the host entry is inserted into the root overlay. Safe to call
  /// repeatedly — it re-attaches if the entry was disposed (e.g. hot reload).
  void ensureAttached() {
    if (_entry != null && _entry!.mounted) return;
    final overlay = _findRootOverlay();
    if (overlay == null) {
      // The app may not have built its Overlay yet — retry on the next frames.
      if (_tries++ < 30) {
        WidgetsBinding.instance.addPostFrameCallback((_) => ensureAttached());
      }
      return;
    }
    _tries = 0;
    _entry = OverlayEntry(
      opaque: false,
      maintainState: true,
      builder: (_) => const Positioned.fill(
        child: NexusSurveyOverlay(
          child: NexusInAppOverlay(child: SizedBox.expand()),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void detach() {
    _entry?.remove();
    _entry = null;
  }

  /// Depth-first search for the first [OverlayState] under the root element —
  /// the root navigator's overlay in a MaterialApp/CupertinoApp/WidgetsApp.
  OverlayState? _findRootOverlay() {
    OverlayState? found;
    void visit(Element el) {
      if (found != null) return;
      if (el is StatefulElement && el.state is OverlayState) {
        found = el.state as OverlayState;
        return;
      }
      el.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }
}
