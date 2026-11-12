# ProxyBar

A macOS menu bar app that launches apps (T3 Code, Claude, VS Code, …) through an HTTP or SOCKS5 proxy, and shows whether each one is running through it.

## Features

- **Proxy status:** the menu bar icon turns into `network.slash` when nothing is listening on the proxy port. The menu shows the connect time.
- **Test button:** fetches `google.com/generate_204` and Cloudflare's `/cdn-cgi/trace` through the proxy, then shows Google latency and the exit IP and country.
- **Per-app status:** shows whether an app is not running, running through the proxy, running directly, or running through a different proxy. It reads the running app's environment.
- **Launch / Relaunch / Quit / Force Quit** (right-click the stop button for Force Quit).
- **Leftover cleanup:** after an app quits, finds processes that were re-parented to launchd and either live inside the app bundle or match per-app name patterns (e.g. T3 Code's `agy_acp_server`). Kills them with SIGTERM, then SIGKILL. Can run automatically after every quit.
- **Launch when ProxyBar starts:** per app, with "Open ProxyBar at login" for a fully automatic setup. Waits up to 60 s for the proxy to come up.
- **Copy shell exports:** puts `export HTTPS_PROXY=…` on the clipboard for terminals.
- **Per-app extra environment variables.**

## What a launched app gets

- `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (plus lowercase copies, and `ALL_PROXY` for SOCKS5)
- `NODE_USE_ENV_PROXY=1`: Node.js 24+ `fetch()` honors the variables
- For Electron apps: `--proxy-server=… --proxy-bypass-list=…`. Chromium ignores the environment variables for its own traffic.

Apps are launched with `NSWorkspace.openApplication(at:configuration:)`. Its `environment` is added to the normal environment rather than replacing it. A running app can't pick up new variables, so ProxyBar quits it and relaunches it.

## Build

Needs only the Command Line Tools (Swift 6.x); Xcode isn't required.

```sh
./build.sh            # → build/ProxyBar.app
./build.sh --install  # also copy to ~/Applications (quits a running copy first)
./build.sh --run      # install and open
```

For quick iteration, `swift run` works too, but "Open at login" needs the real `.app` bundle.

## Layout

| File | What it does |
|---|---|
| `ProxyBarApp.swift` | `@main`: the `MenuBarExtra` and the `Settings` scene |
| `AppStore.swift` | All state and actions: refresh loop, launch/stop/relaunch/cleanup, persistence (UserDefaults JSON), login item |
| `Models.swift` | `ProxySettings` (env vars, Chromium args, URLSession proxy config) and `ManagedApp` |
| `ProcessInspector.swift` | sysctl/libproc: user process list, executable paths, another process's environment (`KERN_PROCARGS2`) |
| `Network.swift` | TCP probe of the proxy port; connection test through the proxy |
| `MenuView.swift` | The menu bar panel |
| `SettingsView.swift` | Settings window: Proxy tab and Apps tab |
| `Resources/Info.plist` | Bundle info; `LSUIElement` hides the Dock icon |

## Notes and gotchas

- **No `@State`:** in this SDK, SwiftUI's `@State` is a macro whose plugin only ships with Xcode. UI state therefore lives in the `@Observable` `AppStore`, which uses the Observation macros that Command Line Tools does include. If you install Xcode, you can use `@State` normally.
- **Saved settings:** stored under the `dev.local.ProxyBar` defaults domain (`defaults read dev.local.ProxyBar`). Model decoding uses `decodeIfPresent` everywhere, so adding new fields won't wipe saved settings.
- **Unknown status:** reading another app's environment works for your own, non-system apps. For Apple system apps it fails, and the status shows "proxy status unknown".
- **Signing:** the app is ad-hoc signed (`codesign -s -`). macOS may ask for approval of the login item in System Settings → Login Items.

## Ideas

- An app icon (`Resources/AppIcon.icns` is copied if present)
- Several proxy profiles with quick switching
- A global hotkey to open the menu
- Notifications when the proxy goes down while proxied apps are running
- "Open Terminal with proxy" (Terminal/iTerm with the exports pre-set)
