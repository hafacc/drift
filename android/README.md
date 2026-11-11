# Drift Android app

Native Android (Jetpack Compose) app for local control of the air conditioner,
on top of the published **mideakt** Kotlin protocol library
([`hafacc/mideakt`](https://github.com/hafacc/mideakt), resolved via JitPack —
declared in `app/build.gradle.kts`).

```
app/   Compose app: setup + control UI, DeviceViewModel, DeviceManager (the single
       owner of the AC's one connection), encrypted credential store, Quick Settings
       tile, and Glance home widget.
```

## Build & run
Open `android/` in **Android Studio** and Run, or from the CLI:

```bash
cd android
./gradlew :app:assembleDebug          # build the APK
./gradlew :app:installDebug           # install to a connected device
```

Run on a **physical device on the same Wi-Fi** as the AC (an emulator's NATed
network can't reach the LAN / broadcast). On first launch tap **Set Up** — it
discovers the AC, fetches its key from the cloud once, and stores it encrypted
(`EncryptedSharedPreferences`). After that, all control is local.

Requires the Android SDK (set `sdk.dir` in `local.properties`, gitignored).

## Validating the protocol
The protocol lives in the standalone, pure-JVM
[`hafacc/mideakt`](https://github.com/hafacc/mideakt) library (no Android deps), so
its tests and CLI run there without the Android toolchain — clone that repo to
exercise the protocol headlessly against a real device.

## Status
The Quick Settings tile (`DriftTileService`) and Glance home widget (`DriftWidget`)
both ship. Credentials are stored with `EncryptedSharedPreferences`.

## Releases (Google Play)
`.github/workflows/android-cut.yml` (run by hand with patch/minor/major, or `cut.yml` for
every app) runs the Android job of `build.yml` on main's tip, bumps `versionName` and
`versionCode` in `app/build.gradle.kts`, commits and tags `android-v<version>`, then starts
`android-publish.yml` on that tag. Its `bundle` job builds the signed bundle, keeps it as the
run's artifact (`drift-android-v<version>`) and makes the GitHub release; its `play` job
uploads that bundle to Play's `internal` track (Gradle Play Publisher), or a draft when Play
refuses a rolled-out release, as it does until the app has passed its first review.
Promote it in the Play Console.

Signing: `storeFile`, `storePassword`, `keyAlias` and `keyPassword` come from
`keystore.properties` (git-ignored) or `-Pdrift.<name>`. Without them a release build is
debug-signed: it installs locally, but Play won't accept it. Never commit a keystore.

Secrets (repository secrets): `ANDROID_KEYSTORE` (the upload keystore, base64),
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`,
`PLAY_SERVICE_ACCOUNT_JSON` (a service account with release access to the app). The
publisher can't create the app, so the first bundle is uploaded by hand in the Play Console:
the first cut's `play` job fails, and the bundle to upload is that run's artifact.
