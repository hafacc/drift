# Drift for macOS and iOS

Native SwiftUI apps for local control of the air conditioner: a Mac window app with a
Notification Center widget, and an iPhone app with Home Screen and Lock Screen widgets
and a Control Center power control. All depend on the **MideaKit** Swift package
([`hafacc/MideaKit`](https://github.com/hafacc/MideaKit))
and share the set-up device (credentials + nickname) through a shared **Keychain**
group; the widgets read it and fetch live state themselves.

```
App/           The macOS window app's views
iOSApp/        The iPhone app's views
AppCore/       Both apps' state and first-run setup (DeviceStore, SetupFlow)
Widget/        The macOS widget's views
iOSWidget/     The iOS widgets and Control Center control
WidgetCore/    Both widget extensions' timeline, buttons and intents
Shared/        Code compiled into every target (Keychain, Snapshot, DeviceService)
project.yml    xcodegen spec → Drift.xcodeproj (points at the MideaKit package)
```

The two apps share the bundle ID `cc.hafa.Drift`, for a universal purchase.

## First-time setup

1. One-time Xcode component install (only if `xcodebuild` complains about plugins):
   ```
   sudo xcodebuild -runFirstLaunch
   ```
2. Open the project:
   ```
   open apple/Drift.xcodeproj
   ```
3. For each app and widget target (`Drift`, `DriftWidget`, `DriftiOS`,
   `DriftWidgetiOS`) → *Signing & Capabilities*, confirm the **Keychain Sharing**
   group `cc.hafa.Drift.shared` is present. (Keychain sharing works within your
   team — no paid account needed.) The iOS targets also share the App Group
   `group.cc.hafa.Drift`; the macOS ones use the Team-ID-prefixed form.
4. Select the `Drift` (macOS) or `DriftiOS` scheme and Run.

On first run the app shows a **Set Up** screen: it discovers the AC on the LAN
and fetches its key once from Midea's cloud, signing in with the Midea account
the AC was added to. The password is kept only in memory for setup.
The device (credentials + nickname) is stored in the shared Keychain. The widget
reads that and fetches live state itself. Allow the **Local Network** prompt when it appears.

While the iPhone app is in the foreground it holds the AC's only connection, and the
widgets and the power control hand their taps to it; in the background it lets go, and
they connect themselves.

### Multicast on iOS

iOS blocks broadcast sends without the `com.apple.developer.networking.multicast`
entitlement, which has been requested from Apple. Until it's granted, the discovery
broadcast fails and the probes sent to each host on the subnet find the AC. Once Apple
grants it, add `com.apple.developer.networking.multicast: true` to the `DriftiOS` and
`DriftWidgetiOS` entitlements in `project.yml`.

## Regenerating the project

`project.yml` is the source of truth. After editing it:
```
cd apple && xcodegen generate
```

## Releases (Xcode Cloud)

`Config/Versions.xcconfig` is the project's base configuration and holds
`MARKETING_VERSION` per platform, each shared by that platform's app and widget; keep it
out of `project.yml`'s settings, which would override it.
`.github/workflows/macos-cut.yml` and `ios-cut.yml` (run by hand with patch/minor/major,
or `cut.yml` for every app) run the Apple job of `build.yml` on main's tip, bump that
platform's lines, commit and tag `macos-v<version>` or `ios-v<version>`. Xcode Cloud
builds the archive from the tag, so it uses the committed `Drift.xcodeproj`: regenerate and commit it after
every `project.yml` change (`build.yml` fails when the two differ).

## MideaKit on its own

The protocol library is the standalone
[`hafacc/MideaKit`](https://github.com/hafacc/MideaKit) package; clone it to run
its tests or the CLI:

```
cd MideaKit         # a checkout of hafacc/MideaKit
swift test          # protocol unit tests
swift run mideacli  # read/control the AC from the command line
```
