## 1.0.3

- Persist the identified end-user across app launches. Once `identify()` names
  the user, the identity is remembered on device and restored on the next cold
  start, so every session is attributed to that user instead of starting a new
  anonymous one. Never identified → still anonymous, as before. `reset()` clears
  the persisted identity (and is now async).
- `context.nexus` is now safe to call from any widget lifecycle method,
  including `initState()` and `dispose()`. `NexusScope.of` no longer registers
  an inherited-widget dependency and only consults the scope while the element
  is mounted (the Nexus instance is a stable singleton), fixing both the
  "dependOnInheritedWidgetOfExactType called before initState completed" and the
  "Looking up a deactivated widget's ancestor is unsafe" assertions.

## 1.0.2

- Backend base url updated.

## 1.0.1

- Drop package_info_plus (pulls dart:io/win32); source app metadata from the
  native device-info channel instead → WASM-compatible, clean platform graph.
- Rename the iOS/macOS Swift package dirs from `nexus` to `nexus_flutter` (the
  plugin name) so Flutter/pana detect Swift Package Manager support.
- Result: 30 conventions + 20 docs + 20 platform + 50 analysis + 40 deps = 160.


## 1.0.0

* Identity
* Sessions
* Events (analytics)
* Logs
* Errors & crashes
* Feature flags
* Remote Config
* Deep links & attribution
* Realtime
* Session replay
* Surveys
* Lifecycle, flushing & disposal