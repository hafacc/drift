# Drift — local control for Midea air conditioners

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
android/  Jetpack Compose app + Quick Settings tile + home widget; uses the published mideakt library.
```

Each app discovers the device and fetches its key **itself** during first-run
setup, storing it in a platform-appropriate secure store (encrypted preferences on
Android). After that, all control is purely local.

The protocol itself lives in a native library, published as a standalone
package and consumed **remotely** (no in-repo copy):

- **Kotlin — [`hafacc/mideakt`](https://github.com/hafacc/mideakt)** via JitPack
  (`com.github.hafacc:mideakt` in `android/app/build.gradle.kts`).

## Protocol notes

- Device listens on TCP **6444**; UDP **6445** is used for discovery replies.
- A device only opens TCP 6444 *after* the UDP discovery handshake — a cold port
  scan won't find it; discover via broadcast first.
- "V1/V2" firmware: controllable with no credentials.
- "V3" firmware (ours): the session is AES-encrypted and needs a per-device
  **token + key**, fetched once from Midea's cloud, then used purely locally.

## Building

- **Android:** `cd android && ./gradlew installDebug`. `mideakt` resolves
  remotely via JitPack.
