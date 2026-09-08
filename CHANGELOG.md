## 1.5.0

- **Nexus Voice (CPaaS calling) — turnkey.** Set `voiceEnabled: true` and call;
  the SDK bundles everything (WebRTC media, native CallKit/ConnectionService UI,
  VoIP/FCM incoming-call push registration). No adapters to write.
  - `nexus.voice`: `placeCall(to:, type:)` (app-to-app, PSTN or SIP), plus
    `setMuted`/`setSpeakerphone`/`setHold`/`sendDtmf`/`hangup`; `answer`/`decline`.
  - **Built-in call screen** — a default full-screen call UI auto-shows on any
    active call (outbound + incoming) with mute/speaker/hold/hangup and
    accept/decline. Nothing to build; opt out with `autoShowOverlay: false`.
  - Live call state via `nexus.voice.current` (`ValueListenable<NexusCall?>`) —
    mirrors the server state machine (ringing/connected/onHold/…) with live MOS.
  - **Incoming calls ring the native screen even when the app is closed** — the
    SDK registers the device's VoIP/FCM token and the Nexus backend pushes the
    ring; Accept/Decline/mute/hold from the system UI are wired automatically.
  - Bundles `livekit_client` + `flutter_callkit_incoming` internally. One-time
    OS setup only (iOS VoIP background mode + APNs key in console); see README.
  - Never-crash rule: all media/native/push failures surface as a failed/ended
    call state, never a thrown exception.

## 1.4.1

- Hardening: the SDK can never crash the host app.
  - The telemetry outbox is now memory-capped (512 KB total) and drops the
    oldest items under sustained pressure, so a burst of telemetry can no longer
    grow the queue into an out-of-memory / main-thread-stall hazard.
  - Bulky, best-effort payloads (session-replay batches) are held in memory and
    delivered best-effort, but never persisted — keeping the durable store tiny
    so it can't bloat local storage or its re-serialization stall the app.
  - The global error handlers now swallow any failure inside our own reporting,
    so error capture can never disrupt the app's error handling.

## 1.4.0

- Live Activities. One cross-platform API for a live, updating view of an
  in-progress event. Enable with `liveActivityEnabled: true`.
  - **iOS** — ActivityKit on the Lock Screen / Dynamic Island. A turn-key default
    attributes type (`NexusLiveActivityAttributes`) + a copy-paste Widget
    Extension template (`ios/NexusLiveActivityWidget/`); the SDK manages the
    lifecycle and registers push-to-start (17.2+) + update tokens. Or manage your
    own typed `ActivityAttributes` and register tokens via `nexus.liveActivity`.
  - **Android** — a live ongoing notification (progress / status) the SDK renders
    natively from the server's data message or via `nexus.liveActivity`.
  - Drive it server-side from the dashboard / Live Activity API (start / update /
    end), or locally with `nexus.liveActivity.start/update/end`.

## 1.3.0

- In-app messages (OneSignal-style). Set `inAppEnabled: true`; the SDK fetches
  active messages, evaluates triggers (session start / custom event) + frequency
  caps locally, and shows modals / banners / center / fullscreen with buttons.
  Impressions and clicks are reported automatically; `nexus.inApp.onAction`
  surfaces button taps (dismiss / open URL / track event). Compose them in the
  console (In-app messages).
- Overlays auto-mount. Surveys and in-app messages no longer require a
  `MaterialApp.builder` — the SDK inserts the overlay into the app's root overlay
  itself (`autoShowOverlay`, default `true`; set `false` to mount
  `NexusSurveyOverlay` / `NexusInAppOverlay` yourself).

## 1.2.0

- Push: rich notifications. Campaigns composed with action buttons, Android large/
  big/small icon + lockscreen visibility + accent colour, iOS badge/relevance/
  interruption level/subtitle, and web icon/image/badge are honoured on delivery.
  - **Android** renders every notification natively (no third-party packages) in
    **all app states** — foreground, background and killed — so action buttons
    and rich media are consistent everywhere. Campaigns are delivered as
    high-priority data messages and a background handler draws them.
  - **iOS** ships a ready-to-use Notification Service Extension
    (`ios/NexusNotificationServiceExtension/`) that turns the payload into action
    buttons + attached images in every state (one-time app setup, see README).
  - New `push.onOpened` callback surfaces the open — including which action button
    was tapped and its URL.

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