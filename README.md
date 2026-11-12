# ProxyBar

A macOS menu bar app that launches apps (T3 Code, Claude, VS Code, …) through an HTTP or SOCKS5 proxy, shows whether each one is running through it, and checks which online services work through your proxy.

Progress, backlog and design notes are in [docs/PROGRESS.md](docs/PROGRESS.md).

## Features

**Proxy and apps**
- **Proxy status:** the menu bar icon gets a slash when nothing is listening on the proxy port. The menu shows the connect time.
- **Per-app status:** not running, running through the proxy, running directly, or running through a different proxy. ProxyBar reads the running app's environment.
- **Launch / Relaunch / Quit / Force Quit** (right-click the stop button for Force Quit).
- **Leftover cleanup:** after an app quits, finds processes that were re-parented to launchd and either live inside the app bundle or match per-app name patterns (e.g. T3 Code's `agy_acp_server`). Kills them with SIGTERM, then SIGKILL. Can run automatically after every quit.
- **Start with ProxyBar** per app, plus **Open ProxyBar at login**. ProxyBar waits up to 60 s for the proxy to come up.

**Region check** (v0.2)
- Checks each service with an unauthenticated request, through the proxy and directly: Gemini, Antigravity, Google developer sites, Claude, OpenAI, xAI, OpenRouter, Groq and Docker Hub. You can add your own.
- Each check has a block signature (HTTP statuses + optional text markers). A normal "401 missing API key" counts as available.
- Shows the exit IP and country through the proxy and directly, plus Google latency.
- Apps list the services they need, and the menu warns on an app's row when one is blocked through the proxy.
- Runs at start, when the proxy reconnects, every 15/30/60 minutes, or with **Check**.

**Notifications** (v0.2)
- Proxy down (after two failed checks in a row), proxy back, and a service newly blocked through the proxy.

**Terminal with proxy** (v0.2)
- Opens Terminal or iTerm in your home folder, a chosen folder, or a recent folder, with the proxy variables set. **Copy shell exports** is in the same menu.

**First-run setup and icon** (v0.2)
- A setup window on first launch: proxy and a live check, an app picker, then login, notifications and terminal choices. Rerun it from Settings.

## What a launched app gets

- `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (plus lowercase copies, and `ALL_PROXY` for SOCKS5)
- `NODE_USE_ENV_PROXY=1`: Node.js 24+ `fetch()` honors the variables
- For Electron apps: `--proxy-server=… --proxy-bypass-list=…`. Chromium ignores the environment variables for its own traffic.
- Any extra `KEY=value` lines set for that app in Settings

## Build

Needs only the Command Line Tools (Swift 6.x); Xcode isn't required.

```sh
./build.sh            # → build/ProxyBar.app
./build.sh --install  # also copy to ~/Applications (quits a running copy first)
./build.sh --run      # install and open
```

To redraw the icon, delete `Resources/AppIcon.icns` and build, or run `scripts/make-icon.swift` yourself.

## Layout

| File | What it does |
|---|---|
| `ProxyBarApp.swift` | `@main`: the `MenuBarExtra` and the `Settings` scene |
| `AppStore.swift` | All state and actions: refresh loop, launch/stop/relaunch/cleanup, region check scheduling, notifications, terminal, persistence |
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

## Notes

- **No `@State`:** in this SDK, SwiftUI's `@State` is a macro whose plugin only ships with Xcode, so UI state lives in `@Observable` classes. With Xcode installed you can use `@State` normally.
- **Saved settings:** stored in the `dev.local.ProxyBar` defaults domain (`defaults read dev.local.ProxyBar`). Decoding uses `decodeIfPresent`, so new fields never wipe saved settings. To see the setup window again: `defaults delete dev.local.ProxyBar onboardingDone.v1`.
- **Signing:** the app is ad-hoc signed (`codesign -s -`). macOS may ask you to approve the login item, and asks for notification permission once.
