import 'package:flutter/widgets.dart';

/// Redact a widget from session replay. The wrapped subtree renders normally to
/// the user, but its on-screen area is painted over with a solid block in every
/// captured replay frame — so sensitive pixels (card numbers, tokens, PII)
/// never leave the device.
///
/// ```dart
/// NexusMask(child: Text(order.cardNumber))
/// ```
class NexusMask extends StatefulWidget {
  const NexusMask({super.key, required this.child});

  final Widget child;

  @override
  State<NexusMask> createState() => _NexusMaskState();
}

class _NexusMaskState extends State<NexusMask> {
  @override
  void initState() {
    super.initState();
    NexusMaskRegistry.instance.add(this);
  }

  @override
  void dispose() {
    NexusMaskRegistry.instance.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tracks the currently-mounted [NexusMask]s so the replay recorder can find
/// their bounds and redact them at capture time. Process-wide (the SDK is a
/// single instance).
class NexusMaskRegistry {
  NexusMaskRegistry._();

  static final NexusMaskRegistry instance = NexusMaskRegistry._();

  final Set<State> _masks = <State>{};

  void add(State s) => _masks.add(s);
  void remove(State s) => _masks.remove(s);

  bool get isEmpty => _masks.isEmpty;

  /// Bounds of every visible mask expressed in the coordinate space of
  /// [ancestor] (the replay RepaintBoundary), in logical pixels. Unmounted or
  /// un-laid-out masks are skipped.
  List<Rect> rectsIn(RenderObject ancestor) {
    final out = <Rect>[];
    for (final s in _masks) {
      if (!s.mounted) continue;
      final box = s.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      try {
        final topLeft = box.localToGlobal(Offset.zero, ancestor: ancestor);
        out.add(topLeft & box.size);
      } catch (_) {
        // Not in the same layer tree / not currently laid out — skip it.
      }
    }
    return out;
  }
}
