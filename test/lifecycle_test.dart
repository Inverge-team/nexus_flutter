import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexus_flutter/src/lifecycle.dart';

void main() {
  testWidgets('fires background/foreground on edges only', (tester) async {
    var background = 0;
    var foreground = 0;
    final lifecycle = NexusLifecycle(
      onBackground: () async => background++,
      onForeground: () async => foreground++,
    );
    addTearDown(lifecycle.dispose);

    final binding = tester.binding;
    // Flutter enforces adjacent transitions in this order:
    // detached, resumed, inactive, hidden, paused.
    void set(AppLifecycleState s) => binding.handleAppLifecycleStateChanged(s);

    void goBackground() {
      set(AppLifecycleState.inactive); // transient — no edge
      set(AppLifecycleState.hidden); // background edge
      set(AppLifecycleState.paused); // already background — no edge
    }

    void goForeground() {
      set(AppLifecycleState.hidden); // still background — no edge
      set(AppLifecycleState.inactive); // foreground edge
      set(AppLifecycleState.resumed); // already foreground — no edge
    }

    goBackground();
    expect(background, 1);
    expect(foreground, 0);

    goForeground();
    expect(foreground, 1);

    goBackground();
    goForeground();
    expect(background, 2);
    expect(foreground, 2);
  });
}
