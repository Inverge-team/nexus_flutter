import 'package:flutter/material.dart';

import '../nexus.dart';
import 'inapp_models.dart';
import 'inapp_view.dart';

/// Bring your own in-app message UI. Return a widget; drive it with the provided
/// callbacks (button tap / dismiss).
typedef NexusInAppBuilder = Widget Function(
  BuildContext context,
  NexusInAppMessage message,
  void Function(NexusInAppButton button) onButton,
  VoidCallback onDismiss,
);

/// Hosts the currently-active in-app message above your app. Add it via
/// `MaterialApp.builder` so it has a Material/Overlay/MediaQuery ancestor:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => NexusInAppOverlay(child: child!),
///   // ...
/// )
/// ```
class NexusInAppOverlay extends StatefulWidget {
  const NexusInAppOverlay({super.key, required this.child, this.messageBuilder});

  final Widget child;
  final NexusInAppBuilder? messageBuilder;

  @override
  State<NexusInAppOverlay> createState() => _NexusInAppOverlayState();
}

class _NexusInAppOverlayState extends State<NexusInAppOverlay> {
  ValueNotifier<NexusInAppMessage?>? _current;

  @override
  void initState() {
    super.initState();
    if (Nexus.isInitialized) {
      _current = Nexus.instance.inApp.current;
      _current!.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _current?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final message = _current?.value;
    final inApp = Nexus.isInitialized ? Nexus.instance.inApp : null;
    return Stack(
      children: [
        widget.child,
        if (message != null && inApp != null)
          Positioned.fill(
            child: Stack(
              children: [
                // Scrim for modal/center/fullscreen (not banners).
                if (message.layout != 'banner_top' && message.layout != 'banner_bottom')
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => inApp.dismiss(message),
                      child: ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
                    ),
                  ),
                Align(
                  alignment: _alignment(message.layout),
                  child: widget.messageBuilder?.call(
                        context,
                        message,
                        (b) => inApp.tapButton(message, b),
                        () => inApp.dismiss(message),
                      ) ??
                      NexusInAppView(
                        message: message,
                        onButton: (b) => inApp.tapButton(message, b),
                        onDismiss: () => inApp.dismiss(message),
                      ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Alignment _alignment(String layout) {
    switch (layout) {
      case 'banner_top':
        return Alignment.topCenter;
      case 'banner_bottom':
        return Alignment.bottomCenter;
      case 'fullscreen':
        return Alignment.center;
      case 'center':
      case 'modal':
      default:
        return Alignment.center;
    }
  }
}
