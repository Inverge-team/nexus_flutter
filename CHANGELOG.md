## 1.2.0

- Push: rich notifications. Campaigns composed with action buttons, Android large/
  big/small icon + lockscreen visibility + accent colour, iOS badge/relevance/
  interruption level/subtitle, and web icon/image/badge are honoured on delivery.
  The Android foreground renderer draws them natively (downloads large-icon /
  big-picture images, renders action buttons). New `push.onOpened` callback
  surfaces the open — including which action button was tapped and its URL.

## 1.1.0

Push notifications, matured — foreground display, localization, and subscriber tags.

- **Foreground notifications.** FCM never draws a notification while the app is
  open — the SDK now renders it using its **own native code** (no third-party
  packages): iOS presents the banner via the Firebase SDK
  (`setForegroundNotificationPresentationOptions`), Android posts the notification
  from the Nexus plugin and forwards taps back for open attribution. Configurable
  with `pushForegroundDisplay` (default `true`), `pushAndroidChannelId` and
  `pushAndroidChannelName`.
- **Localized notifications.** `push.setLanguage('en')` attaches the user's app
  language to the device token; campaigns composed with per-language translations
  (console → Push → Localize) are delivered in each device's language, falling back
  to the campaign default then the base message (`en-US` → `en`). Works before or
  after push is enabled.
- **Subscriber tags.** `push.setTag('role', 'client')` / `setTags({...})` /
  `removeTag(key)` / `clearTags()` attach OneSignal-style key/value tags to the
  device token. Build tag-condition segments in the console (Tag is / is not /
  contains / exists / does not exist) to target campaigns and automations. Tags
  sync immediately when a token exists, otherwise on the next registration.

## 1.0.4

- Add Nexus Push (`context.nexus.push` / `Nexus.instance.push`).
  - **Turn-key**: set `pushEnabled: true` and the SDK handles everything —
    permission, FCM token acquisition + registration (correlated to the journey
    identity), token refresh, and open tracking. No push code in your app; only
    the standard Firebase config is required. Bundles `firebase_core` +
    `firebase_messaging`.
  - **Advanced/BYO**: `registerToken` / `reportOpen` / `unregister` for apps that
    manage their own tokens (e.g. raw APNs). `reportOpen` reads `nexus_campaign_id`
    for delivery + A/B outcomes.

## 1.0.3

- `identify()` now accepts an optional `phone` number (alongside `email`/`name`/
  `traits`) — sent to the backend and persisted with the identity.
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