# Drift — local control for Midea air conditioners

[drift.hafa.cc](https://drift.hafa.cc)

Privacy-respecting, fully-local control of a Midea WiFi air conditioner — a
better alternative to the flaky stock "smart home" app. Talks to the AC's WiFi
module directly over the LAN; the Midea cloud is contacted exactly once (to fetch
the device's key), and never again.

## Why

The stock app routes commands through Midea's cloud, has poor timeout/state
handling, and is a privacy liability. The Midea LAN protocol is fully
reverse-engineered, so we can control the unit ourselves.

## Apps

```
apple/    SwiftUI apps for macOS and iPhone, with widgets and a Control Center control; uses the published MideaKit Swift package.
android/  Jetpack Compose app + Quick Settings tile + home widget; uses the published mideakt library.
site/     drift.hafa.cc: the apps' page and privacy policy (SvelteKit, static, on GitHub Pages).
```

Each app discovers the device and fetches its key **itself** during first-run
setup, storing it in a platform-appropriate secure store (Keychain on macOS and iOS,
encrypted preferences on Android). After that, all control is purely local.

The protocol itself lives in two native libraries, published as standalone
packages and consumed **remotely** (no in-repo copies):

- **Swift — [`hafacc/MideaKit`](https://github.com/hafacc/MideaKit)** via SwiftPM
  (pinned in `apple/project.yml`).
- **Kotlin — [`hafacc/mideakt`](https://github.com/hafacc/mideakt)** via JitPack
  (`com.github.hafacc:mideakt` in `android/app/build.gradle.kts`).

Both are ports of the same reference implementation, verified against a shared
set of test vectors so the two apps behave identically.

## Protocol notes

- Device listens on TCP **6444**; UDP **6445** is used for discovery replies.
- A device only opens TCP 6444 *after* the UDP discovery handshake — a cold port
  scan won't find it; discover via broadcast first.
- "V1/V2" firmware: controllable with no credentials.
- "V3" firmware (ours): the session is AES-encrypted and needs a per-device
  **token + key**, fetched once from Midea's cloud, then used purely locally.
- macOS gotcha: the host app needs **Local Network** permission (System Settings
  → Privacy & Security → Local Network), and the discovery socket must set
  `SO_BROADCAST` even for a subnet-directed broadcast or macOS returns EACCES.

## Building

- **macOS and iOS:** `cd apple && xcodegen generate && open Drift.xcodeproj`, then
  run the `Drift` scheme on a Mac or an iPhone destination. `MideaKit` resolves
  remotely via SwiftPM.
- **Android:** `cd android && ./gradlew installDebug`. `mideakt` resolves
  remotely via JitPack.
- **Site:** `cd site && bun install && bun dev`.
