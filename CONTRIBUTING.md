# Contributing to ProxyBar

## Build and run

Install the macOS Command Line Tools with `xcode-select --install`. Use Swift 6 and target macOS 14 or later.

```sh
./build.sh
open build/ProxyBar.app
```

Use the bundled app when checking login items, notifications, and first-run setup. The build script signs the bundle ad hoc for local use.

## Architecture

SwiftUI's `MenuBarExtra` and Settings scene share a main-actor `AppStore`. The store owns user preferences and coordinates background checks and app actions. Network probes and process inspection live outside the views. View state that would otherwise use SwiftUI's `@State` lives in `@Observable` classes to support the Command Line Tools build.

| File | What it does |
|---|---|
| `ProxyBarApp.swift` | `@main`: the `MenuBarExtra` and the `Settings` scene |
| `AppStore.swift` | All state and actions: refresh loop, launch/stop/relaunch/cleanup, region check scheduling, notifications, terminal, persistence |
| `AppOperations.swift` | Serializes app actions by bundle identifier and exposes in-progress state |
| `Models.swift` | `ProxySettings` (env vars, Chromium args, proxied/direct URLSession configs) and `ManagedApp` |
| `Services.swift` | `ServiceCheck` (block signatures and built-in presets), verdicts, `KnownApps` catalog |
| `Network.swift` | TCP probe of the proxy port; `RegionChecker` (exit info, per-service judging) |
| `ProcessInspector.swift` | sysctl/libproc: user processes, executable paths, another process's environment |
| `Notifier.swift` | UserNotifications with an AppleScript fallback |
| `TerminalLauncher.swift` | Self-deleting `.command` script for Terminal/iTerm |
| `Onboarding.swift` | First-run setup window |
| `MenuView.swift` | The menu bar panel |
| `SettingsView.swift` | Settings: Proxy, Apps and Region tabs |
| `scripts/make-icon.swift` | Draws the app icon |
| `Resources/Info.plist` | Bundle info; `LSUIElement` hides the Dock icon |

Preferences are stored in the `dev.local.ProxyBar` UserDefaults domain. Settings and managed apps use `decodeIfPresent` defaults for fields introduced after the first release. Preserve that compatibility when adding fields.

To reset the first-run flag, quit ProxyBar, run `defaults delete dev.local.ProxyBar onboardingDone.v1`, then reopen the app. This keeps saved settings.

See [the progress log](docs/PROGRESS.md) for design decisions, prior testing, and the backlog.

## Run regression checks

`bash scripts/test.sh` checks cleanup boundaries, process identity validation, saved direct-check preferences, and overlapping app operations using the Command Line Tools.

## Regenerate the app icon

```sh
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
./build.sh
```

Commit both the generator and the updated ICNS when changing the artwork.
