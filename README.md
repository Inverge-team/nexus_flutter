# Nexus — Flutter SDK

One SDK for **all** Inverge Nexus services — realtime, sessions, analytics
events, errors, logs, feature flags, links (deep-linking & attribution) and
session replay. Everything is correlated to a single journey session, so a
user's realtime activity, errors, logs, events and replay line up on the
timeline automatically.

Works on **Android, iOS, Web, macOS, Windows and Linux**. Native platforms add
device context and native session-replay capture; every other service is pure
Dart and runs everywhere.

## Install

```yaml
dependencies:
  nexus: ^0.1.0
```

## Initialise once

Like the WebSocket SDK, you initialise a single instance at startup and access
it anywhere — through the app context.

```dart
import 'package:nexus/nexus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Nexus.init(const NexusConfig(
    apiKey: 'nxs_your_api_key',
    baseUrl: 'https://api.nexus.inverge.net',
  ));

  // optional: identify the end-user — everything after is attributed to them
  await Nexus.instance.identify('user_123', email: 'alice@shopper.com');

  runApp(const NexusScope(child: MyApp()));
}
```

## Use any service via `context.nexus`

```dart
// analytics
context.nexus.events.track('order_placed', properties: {'total': 129});

// errors — nothing to call: with autoCaptureErrors (default), EVERY uncaught
// error is reported automatically. Manual capture is only for handled errors.
try { risky(); } catch (e, s) { context.nexus.errors.capture(e, s); }

// logs
context.nexus.logs.info('checkout opened', source: 'ui');

// realtime
context.nexus.realtime.connect();
context.nexus.realtime.join('orders:42');
context.nexus.realtime.on('order.updated', (data) => print(data));
context.nexus.realtime.emit('orders:42', 'ping', {'hi': true});

// feature flags & remote config
await context.nexus.flags.load();
if (context.nexus.flags.isEnabled('new-checkout')) { /* … */ }
final banner = context.nexus.flags.payload('homepage-banner');

// links / attribution (e.g. from a deep link)
final deepLink = await context.nexus.links.handleDeepLink(incomingUri);

// session replay (native-backed on Android/iOS)
await context.nexus.replay.start();
```

`context.nexus` reads the `NexusScope` if present, otherwise falls back to the
global `Nexus.instance` — so it works with or without the scope widget.

## Automatic error & crash capture

With `autoCaptureErrors: true` (the default), you don't call anything — the SDK
reports **every** uncaught error with a full stacktrace:

- **Flutter framework errors** (build/layout/paint, gesture callbacks) via `FlutterError.onError`.
- **Uncaught async / Dart errors** via `PlatformDispatcher.onError`.
- **Native crashes** (Java/Kotlin, Swift/ObjC, background/native code) — the
  native SDK installs uncaught-exception + signal handlers, persists the crash
  to disk, and the SDK forwards it to Nexus on the **next launch** (you can't
  network during a crash — same persist-and-forward model as Crashlytics/Sentry).

Dart stacktraces are parsed into structured frames for the console's stack view.

## Offline-first delivery

Telemetry (events, logs, errors, replay) is never lost on a flaky network. Each
request is written to a durable **outbox** (persisted with `shared_preferences`),
delivered when the network is up, and retried with exponential backoff — it
survives app restarts. Request/response calls (flags, links, `sessions.track`)
stay direct.

```dart
Nexus.instance.pendingUploads; // requests still queued (e.g. while offline)
```

## Lifecycle

```dart
await Nexus.instance.flush();  // before backgrounding/exit
Nexus.instance.reset();        // on logout — forgets the user, new session
```

## Architecture

- `lib/src/nexus.dart` — the umbrella (`Nexus`), holds shared identity + all services.
- `lib/src/services/*` — one client per service, all correlated via the session.
- `lib/nexus_platform_interface.dart` + method channel — the native surface
  (device info + session-replay capture).
- `android/` (Kotlin) + `ios/` (Swift) bridge to the native **nexus-android**
  (Java) and **nexus-ios** (Swift) SDKs, which do the native session-replay
  capture.

See the sibling `nexus-android` and `nexus-ios` packages for the native cores.
