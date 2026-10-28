# Nexus Flutter SDK

`nexus_flutter` is the umbrella client for the **Inverge Nexus** platform. One
initialization gives a Flutter app every Nexus product, all correlated to a
single user journey. Pure-Dart products run on every platform; the native
layers shipped with the plugin add device context, native crash capture,
session-replay capture, foreground push display, Live Activities and the native
call stack.

- Package: `nexus_flutter`
- Platforms: Android, iOS, Web, macOS, Windows, Linux
- Dart SDK: `^3.13.0`

## Documentation

Installation, initialization, configuration, per-platform setup and the full API
reference live on the documentation site:

- **Guide** — <https://docs.inverge.net/sdks/flutter>
- **API reference** — <https://docs.inverge.net/sdks/flutter/reference>

## What it covers

- **[Identity](https://docs.inverge.net/sdks/flutter#identity)** — identify the signed-in user once; every product picks it up.
- **[Sessions](https://docs.inverge.net/sdks/flutter/reference/sessions)** — automatic journey sessions that tie everything below together.
- **[Events](https://docs.inverge.net/sdks/flutter/reference/events)** — product analytics: track what users do, with properties.
- **[Logs](https://docs.inverge.net/sdks/flutter/reference/logs)** — structured, leveled logs from the app, batched and searchable in the console.
- **[Errors & crashes](https://docs.inverge.net/sdks/flutter/reference/errors)** — Dart errors, native crashes (including NDK) and symbolication-ready stack traces.
- **[Feature flags](https://docs.inverge.net/sdks/flutter/reference/flags)** — evaluate flags per user and roll features out gradually.
- **[Remote Config](https://docs.inverge.net/sdks/flutter/reference/remote-config)** — change app values remotely, with targeting and live updates.
- **[Deep links & attribution](https://docs.inverge.net/sdks/flutter/reference/links)** — resolve Nexus links and attribute installs and opens.
- **[Realtime](https://docs.inverge.net/sdks/flutter/reference/realtime)** — join rooms and exchange messages live.
- **[Session replay](https://docs.inverge.net/sdks/flutter/reference/replay)** — opt-in visual replay of user sessions, with redaction.
- **[Surveys](https://docs.inverge.net/sdks/flutter/reference/surveys)** — in-product surveys, with the built-in UI or your own.
- **[Push notifications](https://docs.inverge.net/sdks/flutter/reference/push)** — turn-key push with localization, tags, rich media and action buttons.
- **[In-app messages](https://docs.inverge.net/sdks/flutter/reference/inapp)** — banners, modals and cards designed in the console.
- **[Live Activities](https://docs.inverge.net/sdks/flutter/reference/live-activities)** — iOS Live Activities and Android live notifications driven from templates.
- **[Shield](https://docs.inverge.net/products/shield/flutter)** — app and device integrity: prove requests come from your genuine app on a real device.
- **[Voice](https://docs.inverge.net/sdks/flutter/reference/voice)** — in-app and PSTN calling, with CallKit and full-screen incoming calls when the app is closed.
- **[DocStore](https://docs.inverge.net/sdks/flutter/reference/docstore)** — the document database: queries, live streams and offline-first sync with field-level merge.

## Links

- Console — <https://nexus.inverge.net>
- Site — <https://inverge.net>
- Source — <https://github.com/Inverge-team/nexus_flutter>

MIT licensed. © Inverge.
