# Nexus Flutter SDK — Full Reference

`nexus_flutter` is the umbrella client for the Inverge Nexus platform. One
initialization gives you **sessions, product analytics, structured logging,
error/crash monitoring, feature flags, remote config, deep‑link attribution,
realtime messaging, session replay, in‑product surveys, and push notifications** — all correlated to
a single user journey.

- Package: `nexus_flutter` · version `1.0.4`
- Platforms: Android, iOS, Web, macOS, Windows, Linux
- Dart SDK: `^3.13.0`

---

## Table of contents

1. [Installation](#1-installation)
2. [Initialization](#2-initialization)
3. [Configuration reference](#3-configuration-reference)
4. [Accessing the SDK](#4-accessing-the-sdk)
5. [Identity](#5-identity)
6. [Sessions](#6-sessions)
7. [Events (analytics)](#7-events-analytics)
8. [Logs](#8-logs)
9. [Errors & crashes](#9-errors--crashes)
10. [Feature flags](#10-feature-flags)
11. [Remote Config](#11-remote-config)
12. [Deep links & attribution](#12-deep-links--attribution)
13. [Realtime](#13-realtime)
14. [Session replay](#14-session-replay)
15. [Surveys](#15-surveys)
16. [Push notifications](#16-push-notifications)
17. [Lifecycle, flushing & disposal](#17-lifecycle-flushing--disposal)

---

## 1. Installation

Add the dependency (from a path, git, or pub once published):

```yaml
dependencies:
  nexus_flutter: ^1.0.1
```

```bash
flutter pub get
```

No native setup is required for the core products. Session replay and native
crash capture work out of the box through the bundled platform channel.

---

## 2. Initialization

Call `Nexus.init` **once**, before `runApp`, then wrap your app in `NexusScope`
(required for session replay and for `context.nexus`).

```dart
import 'package:flutter/material.dart';
import 'package:nexus_flutter/nexus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Nexus.init(const NexusConfig(
    apiKey: 'nxs_live_xxx',
    baseUrl: 'https://services.inverge.net',
    // opt‑in products:
    remoteConfigEnabled: true,
    surveysEnabled: true,
    replayEnabled: false,
  ));

  runApp(const NexusScope(child: MyApp()));
}
```

`Nexus.init(NexusConfig)` → `Future<Nexus>`. Re‑calling `init` disposes the
previous instance. `Nexus.isInitialized` reports whether it has run.

---

## 3. Configuration reference

Every field of `NexusConfig` (all optional except `apiKey`):

| Field | Type | Default | Purpose |
|---|---|---|---|
| `apiKey` | `String` | — | Tenant API key (`nxs_…`). Sent as `x-api-key` and in the socket handshake. |
| `baseUrl` | `String` | `https://services.inverge.net` | API origin. Partner endpoints live under `/partner`. |
| `realtimeUrl` | `String?` | `baseUrl` | Socket.IO origin, if different. |
| `autoTrackSessions` | `bool` | `true` | Start & keep a journey session automatically. |
| `autoCaptureErrors` | `bool` | `true` | Install Flutter/Dart error handlers. |
| `autoConnectRealtime` | `bool` | `false` | Open the socket at startup (connection‑minutes are billed). |
| `manageRealtimeWithLifecycle` | `bool` | `true` | Disconnect on background / reconnect (rejoining rooms) on foreground for accurate metering. |
| `flushOnBackground` | `bool` | `true` | Flush queued telemetry when backgrounded. |
| `flushInterval` | `Duration` | `10s` | Batch flush cadence for events/logs. |
| `maxBatch` | `int` | `50` | Max items per flush. |
| `logging` | `bool` | `false` | Shorthand for `debug` log level. |
| `logLevel` | `NexusLogLevel?` | `warn` | SDK diagnostic verbosity. |
| `onLog` | `NexusLogSink?` | — | Receive every SDK log record. |
| `replayEnabled` | `bool` | `false` | Record session replay (needs `NexusScope`). |
| `replayInterval` | `Duration` | `1s` | Replay frame cadence. |
| `replayPixelRatio` | `double` | `1.0` | Replay capture resolution multiplier. |
| `replayMaskTextFields` | `bool` | `true` | Redact all text inputs from replay. |
| `replayCaptureConsole` | `bool` | `true` | Tee `debugPrint` into the replay console tab. |
| `replayCaptureNetwork` | `bool` | `true` | Auto‑capture HTTP for the replay network tab. |
| `surveysEnabled` | `bool` | `false` | Fetch eligible surveys at startup/foreground. |
| `surveyAutoShow` | `bool` | `true` | Auto‑present popover/banner + event‑triggered surveys. |
| `remoteConfigEnabled` | `bool` | `false` | Fetch Remote Config at startup/foreground. |
| `remoteConfigRealtime` | `bool` | `false` | Re‑fetch config live on publish (needs a realtime connection). |
| `remoteConfigDefaults` | `Map<String,Object?>` | `{}` | In‑app default config values. |
| `pushEnabled` | `bool` | `false` | Turn‑key push: auto permission + token registration + open tracking (needs Firebase config). |
| `pushAutoRequestPermission` | `bool` | `true` | Ask for notification permission at init when push is enabled. |
| `pushWebVapidKey` | `String?` | — | Web only — FCM VAPID public key for web push. |
| `appVersion` | `String?` | — | App version reported with telemetry. |
| `defaultProperties` | `Map<String,Object?>` | `{}` | Merged into every event/person context. |

---

## 4. Accessing the SDK

Two equivalent ways:

```dart
// 1. Global singleton (anywhere):
Nexus.instance.events.track('opened_cart');

// 2. From a BuildContext under NexusScope:
context.nexus.events.track('opened_cart');
```

Services exposed on the instance: `sessions`, `events`, `logs`, `errors`,
`flags`, `remoteConfig`, `links`, `realtime`, `replay`, `surveys`, `push`.

---

## 5. Identity

```dart
// Name the current end‑user (call after login). Attributes all telemetry to it.
await Nexus.instance.identify(
  'user_123',
  email: 'a@b.com',
  name: 'Ada',
  traits: {'plan': 'pro', 'governorate': 'Erbil'},
);

// On logout — forget the user and start a fresh session:
Nexus.instance.reset();

Nexus.instance.distinctId; // String? — current user id (null if anonymous)
Nexus.instance.sessionKey; // String  — current session key
```

`identify` is shorthand for `sessions.identify` and also refreshes the session.

---

## 6. Sessions

`nexus.sessions` — the journey spine every other product correlates into.

```dart
// Identify (same as Nexus.identify):
await nexus.sessions.identify('user_123', email: 'a@b.com', name: 'Ada',
    traits: {'plan': 'pro'});

// Start/refresh the active session; returns the server session id:
final String? sid = await nexus.sessions.track();

// Forget the user + rotate the session:
nexus.sessions.reset();
```

With `autoTrackSessions: true` (default) a session is started automatically at
init and refreshed on foreground — you rarely call `track()` yourself.

---

## 7. Events (analytics)

`nexus.events` — buffered, batched, durably queued, and session‑correlated.

```dart
nexus.events.track('order_placed', properties: {'total': 42.0, 'currency': 'USD'});
nexus.events.track('screen_view', properties: {'name': 'checkout'});

// Force an immediate flush of the batch:
await nexus.events.flush();

// Fire a callback for every tracked event (used internally for survey triggers):
nexus.events.onTracked = (name) => print('tracked $name');
```

`defaultProperties` from config are merged into every event.

---

## 8. Logs

`nexus.logs` — structured, batched, session‑correlated logging.

```dart
nexus.logs.trace('entering checkout');
nexus.logs.debug('cart snapshot', context: {'items': 3});
nexus.logs.info('payment started', source: 'checkout');
nexus.logs.warn('retatrying charge', context: {'attempt': 2});
nexus.logs.error('charge failed', source: 'stripe', context: {'code': 'card_declined'});

await nexus.logs.flush();
```

Each level accepts `{String? source, Map<String,Object?>? context}`.

---

## 9. Errors & crashes

`nexus.errors` — with `autoCaptureErrors: true` (default), **every uncaught
error is reported automatically**: Flutter framework errors, uncaught async Dart
errors, and native crashes (forwarded on the next launch). You can also report
handled errors manually:

```dart
try {
  await risky();
} catch (e, st) {
  await nexus.errors.capture(e, st, {
    'handled': true,          // false marks an uncaught crash
    'level': 'error',         // trace|debug|info|warn|error|fatal
    'feature': 'checkout',    // any extra context
  });
}
```

`capture(Object error, [StackTrace? stack, Map<String,Object?>? extra])`. The
`handled` and `level` keys in `extra` are special; the rest is attached as
context. Wrap your app body in `runZonedGuarded` for the broadest async capture
(the SDK also hooks `FlutterError.onError` and `PlatformDispatcher.onError`).

---

## 10. Feature flags

`nexus.flags` — evaluate once, then read synchronously.

```dart
await nexus.flags.load(properties: {'plan': 'pro'});

nexus.flags.isEnabled('new_checkout');      // bool
nexus.flags.variant('paywall');             // String? (multivariate)
nexus.flags.payload('paywall');             // Object? (attached JSON payload)
nexus.flags.all;                            // Map<String,Object?> of every flag
```

`load({Map<String,Object?>? properties})` evaluates all flags for the current
`distinctId` + person properties and caches them. Call it after `identify` and
whenever targeting properties change.

> For arbitrary typed configuration (not just on/off), prefer **Remote Config**.

---

## 11. Remote Config

`nexus.remoteConfig` — Firebase‑style typed parameters with server‑evaluated
conditions (platform, version, country, percentile rollout, **custom
attributes**…). Enable with `remoteConfigEnabled: true`.

### Defaults & fetch

```dart
// In‑app fallbacks (used until/unless the server has a value):
nexus.remoteConfig.setDefaults({'welcome': 'Hi', 'max_items': 10, 'phone_number': '+964...'});

// Fetch + activate the published template for this device:
await nexus.remoteConfig.fetch();
```

### Typed getters

```dart
nexus.remoteConfig.getString('welcome');            // String  ('' fallback)
nexus.remoteConfig.getBool('feature_enabled');      // bool    (false fallback)
nexus.remoteConfig.getInt('max_items');             // int     (0 fallback)
nexus.remoteConfig.getDouble('price');              // double  (0 fallback)
nexus.remoteConfig.getJson('theme');                // Object? (Map/List)
nexus.remoteConfig.getValue('welcome');             // Object? (raw)
nexus.remoteConfig.getAll();                         // Map<String,Object?>
nexus.remoteConfig.sourceOf('phone_number');        // String? condition name, or null (default)
nexus.remoteConfig.version;                          // int  active template version
nexus.remoteConfig.lastFetchTime;                    // DateTime?
```

Each typed getter takes an optional fallback: `getString('k', 'fallback')`.

### Custom targeting attributes (e.g. `governorate`)

Send arbitrary key/values the server matches with **Custom attribute**
conditions. Persistent attributes are sent on every fetch; per‑fetch attributes
apply to one call.

```dart
// Persistent (recommended for things like governorate / plan / segment):
nexus.remoteConfig.setAttribute('governorate', 'Erbil');
nexus.remoteConfig.setAttributes({'plan': 'pro', 'segment': 'beta'});
await nexus.remoteConfig.fetch();

// One‑off for a single fetch:
await nexus.remoteConfig.fetch(attributes: {'governorate': 'Duhok'});

nexus.remoteConfig.attributes;      // Map<String,Object?> (unmodifiable)
nexus.remoteConfig.setAttribute('governorate', null); // remove one
nexus.remoteConfig.clearAttributes();
```

Merge precedence (later wins): `defaultProperties` → identity traits →
`setAttributes` → per‑fetch `attributes`. Device fields (platform, appVersion,
country/language) are filled in automatically.

> **Values must be primitives** (string/number/bool) and match the condition
> value exactly (case‑sensitive). If you compare against a governorate name,
> `print` what the device sends and set the condition value to match (or
> lowercase on both sides).

### React to changes (realtime)

```dart
// Rebuild UI whenever config changes:
final sub = nexus.remoteConfig.onChange.listen((_) => setState(() {}));

// Push updates: with a realtime connection + remoteConfigRealtime: true, the SDK
// re‑fetches automatically when you publish a new template. Otherwise call
// subscribeRealtime once you have a connection:
await nexus.remoteConfig.subscribeRealtime(nexus.realtime);
await nexus.remoteConfig.unsubscribeRealtime();
```

### Example — dynamic support number by region

```dart
await Nexus.init(const NexusConfig(
  apiKey: 'nxs_...',
  remoteConfigEnabled: true,
  remoteConfigDefaults: {'phone_number': '+9640000000000'},
));
nexus.remoteConfig.setAttribute('governorate', 'Duhok');
await nexus.remoteConfig.fetch();
final phone = nexus.remoteConfig.getString('phone_number'); // region‑specific
```

---

## 12. Deep links & attribution

`nexus.links` — OneLink‑style deferred deep linking + install/open attribution.

```dart
// On first open, report the install/open and receive deferred deep‑link data:
final data = await nexus.links.attribute(
  type: 'install',              // install | open | reengagement | ...
  clickId: 'abc',               // from the link (deterministic match)
  name: 'summer_sale',
  platform: 'ios',
  properties: {'campaign': 'promo'},
);

// Convenience: parse an incoming deep link URI and attribute an open:
final deepLink = await nexus.links.handleDeepLink(incomingUri); // reads link_click_id
```

Both return the matched link's deep‑link data (`Map`) or `null` if unattributed.

---

## 13. Realtime

`nexus.realtime` — Socket.IO messaging authenticated with the API key + journey
identity. Connection‑minutes are billed, so it is opt‑in.

```dart
nexus.realtime.connect();                        // idempotent; rejoins rooms on reconnect
nexus.realtime.isConnected;                       // bool

await nexus.realtime.join('orders:42');           // {ok, room, related}
await nexus.realtime.leave('orders:42');          // {ok}

// Emit one or more events to a room:
await nexus.realtime.emit('orders:42', 'status', {'state': 'shipped'});

// Listen for server events:
nexus.realtime.on('status', (data) => print(data));
nexus.realtime.off('status');

nexus.realtime.disconnect();
```

With `autoConnectRealtime: true` the socket opens at startup; with
`manageRealtimeWithLifecycle: true` (default) it disconnects on background and
reconnects (rejoining rooms) on foreground.

---

## 14. Session replay

`nexus.replay` — rrweb‑compatible screenshot frames + pointer events, all
platforms. Enable with `replayEnabled: true` and wrap the app in `NexusScope`.

```dart
runApp(const NexusScope(child: MyApp()));   // installs the capture RepaintBoundary
```

Redact sensitive widgets:

```dart
NexusMask(child: CreditCardWidget());        // excluded from frames
```

Navigation, console, and network capture are automatic (see config). Manual
hooks:

```dart
nexus.replay.trackScreen('checkout');        // populate the Pages tab manually
nexus.replay.observeRouter(router, () => currentPath);  // GoRouter / nested routes
nexus.replay.recordNetwork(                  // feed from your HTTP interceptor
  url: 'https://api…', method: 'GET', status: 200, durationMs: 120, size: 2048,
);
```

Or attach the navigator observer directly:

```dart
MaterialApp(navigatorObservers: [NexusNavigatorObserver()]);
```

---

## 15. Surveys

`nexus.surveys` — PostHog/AppsFlyer‑style in‑product surveys. Enable with
`surveysEnabled: true` and mount the overlay in your `MaterialApp.builder`.

```dart
MaterialApp(
  builder: (context, child) =>
      NexusSurveyOverlay(child: child ?? const SizedBox.shrink()),
  home: const HomePage(),
);
```

### API

```dart
await nexus.surveys.fetch();                 // List<NexusSurvey> eligible for the user
nexus.surveys.active;                        // List<NexusSurvey> (cached)
nexus.surveys.byId('survey_1');              // NexusSurvey?

nexus.surveys.show(survey);                  // present a specific survey now
nexus.surveys.close();                       // remove the current survey

// Submit answers (partial, complete, or dismissed):
await nexus.surveys.respond(
  survey,
  {'q1': 9, 'q2': 'Great!'},
  completed: true,
  dismissed: false,
);

// The survey the overlay should render right now (ValueNotifier):
nexus.surveys.current; // ValueNotifier<NexusSurvey?>
```

### Custom UI

Replace the default rendering with your own widgets via builders:

```dart
NexusSurveyOverlay(
  child: child,
  // Fully custom survey chrome, driven by a controller:
  surveyBuilder: (context, controller) => MyCustomSurvey(controller),
  // Or keep the default chrome but customize each question:
  questionBuilder: (context, question, controller) => MyQuestion(question, controller),
);
```

`NexusSurveyController` (a `ChangeNotifier`) exposes the survey, current
answers, and `submit`/`close`. `NexusSurvey`/`NexusSurveyQuestion`/
`NexusSurveyChoice`/`NexusSurveyTrigger` are the data models (question `type`,
`choices`, `scaleMin/Max`, `display`, etc.).

---

## 16. Push notifications

Nexus Push delivers notifications via **FCM** (Android/iOS) and **Web Push**,
targeted by the same journey identity you already use — compose, segment,
schedule, A/B test and track opens from the console.

### Turn-key: just enable it

Set `pushEnabled: true` and the SDK does the rest — requests permission, gets the
device token, registers it (correlated to the current user), re-registers on
refresh, **shows notifications while the app is in the foreground**, and reports
notification opens for delivery/A-B outcomes. **No push code in your app.**

> **Why foreground matters.** FCM only draws a system notification when your app
> is backgrounded or closed; while it's open in the foreground, nothing shows
> unless the app renders it. The SDK handles that for you using its **own native
> code** (no third-party packages) — iOS presents the banner via the Firebase
> SDK, Android posts the notification from the Nexus plugin — so notifications
> appear whether the app is open or not, tap-attributed just like a background
> open. Turn it off with `pushForegroundDisplay: false` if you handle `onMessage`
> yourself; set the Android channel with `pushAndroidChannelId` /
> `pushAndroidChannelName` (match your server-side `android.notification.channel_id`).

```dart
await Nexus.init(const NexusConfig(
  apiKey: 'nxs_live_xxx',
  pushEnabled: true,
));
```

The only prerequisite is the standard Firebase config for your app (the same
setup any FCM/OneSignal integration needs):

- **Android** — add `google-services.json` **and apply** the Google Services
  Gradle plugin in `android/app/build.gradle(.kts)` (`id("com.google.gms.google-services")`),
  not just declare it. Nothing else — foreground notifications are rendered by the
  SDK's own native code, no extra packages or Gradle setup.
- **iOS** — add `GoogleService-Info.plist`, enable Push Notifications + Background
  Modes, and upload your APNs key to the Firebase console.
- **Web** — initialise Firebase yourself and pass `pushWebVapidKey:` in the config.

That's it. Provider credentials, segments, campaigns, automations and A/B tests
are managed in the **Push** section of the Nexus console.

> **Permission timing.** By default the OS prompt shows at init. To ask at a
> better moment, set `pushAutoRequestPermission: false`, request it yourself, then
> call `await Nexus.instance.push.start()` (or just wait for the next launch).

### Localized notifications

Tell Nexus the user's app language and campaigns are delivered localized to it —
no per-user work in the console:

```dart
// At startup with the app's current locale, and again when the user changes it.
await Nexus.instance.push.setLanguage('en'); // 'ar', 'fr', …
```

The language is attached to the device token. When you compose a campaign you add
translations per language (console → Push → **Localize**) and pick a default
language; each device receives the content for its language, falling back to the
default (and then to the base message). `en-US` falls back to `en` automatically.
Works before or after push is enabled — set it early and it's applied on the first
registration.

### Advanced: bring your own token

If you manage tokens yourself (a different messaging plugin, or raw APNs), skip
`pushEnabled` and call the API directly via `context.nexus.push`:

```dart
await Nexus.instance.push.registerToken(fcmToken, platform: PushPlatform.android);
// pass provider: PushProvider.apns for raw APNs tokens
Nexus.instance.push.reportOpen(message.data); // attributes the open
await Nexus.instance.push.unregister();        // on logout
```

| Method | Purpose |
|---|---|
| `start()` | Turn-key enable (runs automatically with `pushEnabled: true`). |
| `setLanguage(lang)` | Set the user's app language so campaigns are delivered localized to it. |
| `registerToken(token, {platform, provider?, lang?})` | Register/refresh a device token, correlated to the journey identity. |
| `reportOpen(Map<String,dynamic> data)` | Attribute an open (reads `nexus_campaign_id`). No-op otherwise. |
| `unregister([token])` | Stop delivering to a token (defaults to the last registered). |

`PushPlatform` is `ios` / `android` / `web`; `PushProvider` is `fcm` / `apns` /
`webpush`.

---

## 17. Lifecycle, flushing & disposal

```dart
await Nexus.instance.flush();   // flush all batched telemetry now
Nexus.instance.dispose();       // tear down (also disposes on re‑init)
```

The SDK installs lifecycle hooks automatically: on **background** it flushes
telemetry, pauses replay, and (if configured) disconnects realtime for accurate
metering; on **foreground** it refreshes the session, drains the durable outbox,
re‑fetches surveys/remote‑config, and reconnects realtime.
