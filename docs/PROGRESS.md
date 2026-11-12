# ProxyBar progress

Status of the project, what's next, and why things are built the way they are.
Each feature is its own commit, so `git log` and `git show <commit>` give a reviewable history.

## How to review

```sh
cd ~/Projects/ProxyBar
git log --oneline main..feature/v0.2      # commits in this round
git show <commit>                          # one feature's full diff
git diff main..feature/v0.2 --stat         # files touched this round
```

When you're happy with a round: `git checkout main && git merge feature/v0.2`.

## Changelog

### v0.2.0: branch `feature/v0.2`

| Commit | Feature |
|---|---|
| Add region check for AI and developer services | Per-service availability through the proxy and directly; exit IP and country; per-app warnings; Region settings tab |
| Add notifications for proxy down/up and newly blocked services | Debounced proxy-down alert, "back" alert, newly-blocked-service alert |
| Add "Terminal with proxy" | Terminal/iTerm in any folder with the proxy variables set; recent folders |
| Add app icon and first-run setup | Generated icon; 4-step setup window |
| Tidy the menu: collapsed region summary, one-line rows | Region check is one clickable summary line (collapsed by default); one-line proxy header; icon-only footer; self-clearing messages |
| Ask which services the user uses in setup | New setup step; pre-ticked from the chosen apps; only ticked services are checked |
| Menu: remove focus ring, tighten layout | No blue focus ring on the first button; 290 pt panel |
| Show the region check as a single summary line | Expandable details removed (panel resizing after collapse was unreliable); per-service results on hover and in Settings → Region; status message moved into the footer so the panel height never changes |

### v0.1.0: `main`

Menu bar launcher: per-app proxy status, launch, relaunch, quit and force quit, leftover-process cleanup, launch at start, open at login, copy shell exports.

## Backlog

Ideas from the 2026-11-12 brainstorm that aren't built yet, in rough priority order:

- [ ] **Proxy profiles:** several saved proxies, switch from the menu, optional per-app profile
- [ ] **Automatic failover** to the next working profile
- [ ] **Keep apps on the proxy:** notice when a listed app was started some other way and offer a relaunch
- [ ] **Global hotkey** for the menu, plus "relaunch all through the proxy"
- [ ] **Proxy for terminal tools:** write proxy settings into `git` and `npm` config, with a matching remove
- [ ] **Latency / stability sparkline** for the proxy and Google
- [ ] **Per-app connection view:** what each app's processes connect to (proxy, direct, localhost)
- [ ] **Exit IP / country change alerts**
- [ ] **Settings import / export** (JSON)
- [ ] **Updates via GitHub releases**

Smaller follow-ups noticed while building v0.2:

- [ ] Region check: a per-service "Test" button in Settings, so you can iterate on a custom signature quickly
- [ ] Terminal: support Ghostty / WezTerm / Warp (they don't run `.command` files the same way)
- [ ] Notifications: click a "proxy is down" notification to open the menu
- [ ] Unit tests for `ServiceCheck` judging, `ProcessInspector.environment(of:)` parsing and `shellQuote`

## Design decisions

- **Builds with Command Line Tools only.** SwiftUI's `@State` is a macro in this SDK and its plugin ships only with Xcode, so view state lives in the `@Observable` `AppStore` (the Observation macros *are* in CLT). The onboarding window holds its own `OnboardingModel` for the same reason.
- **Launching:** `NSWorkspace.openApplication` with `configuration.environment` *adds* to the normal environment (verified: `PATH` and `HOME` survive). Electron apps also get `--proxy-server`, because Chromium ignores the proxy variables.
- **Proxy status per app:** read from the running process's environment via `sysctl(KERN_PROCARGS2)`. That works for your own apps but not for Apple system apps, which show "unknown".
- **Region check signatures** come from real responses, a direct connection from a blocked region (IR) vs. the proxy (US exit), on 2026-11-12:

  | Service | Blocked | Allowed |
  |---|---|---|
  | Google (Gemini API, Antigravity, Firebase) | 403 HTML "Error 403 (Forbidden)" | 200/404, or JSON 403 "unregistered callers" (hence the marker) |
  | Anthropic API | 403 "Request not allowed" | 401 |
  | OpenAI API | 403 `unsupported_country_region_territory` | 401 |
  | xAI | 403 "not available in your region" | 401 |
  | OpenRouter | 403 "Access denied by security policy" | 401 |
  | Groq | 403, *also through the US proxy* ("Access denied. Please check your network settings": blocks VPN/datacenter IPs) | 401 |
  | Docker Hub | 403 "RBAC: access denied" | 401 |

  Not included because they weren't blocked either way: ChatGPT web, Mistral, DeepSeek, Cursor, GitHub, Copilot, npm. `claude.ai` (web) shows a Cloudflare challenge through proxies, so the API endpoint is used instead.
- **Notifications:** "down" fires after **two** failed checks in a row (about 9–18 s), so restarting the proxy app stays quiet. "Newly blocked" only fires for automatic checks and only on an available → blocked change, so Groq being blocked doesn't nag you every launch.
- **Menu panel has a fixed height.** MenuBarExtra panels grow with their content but don't shrink back. A collapsible section, and later resizing the window by hand, both proved unreliable, so every row now has a fixed height: the region check is one line, and status messages sit in the footer row.
- **Terminal:** a self-deleting `.command` script + `exec $SHELL -l` needs no Apple Events permission and works with Terminal and iTerm. Your login shell still reads `~/.zshrc` normally.

## Testing log

| Date | What | Result |
|---|---|---|
| 2026-11-12 | v0.1: harness for env reading, TCP probe, connection test, env merge on launch | ✅ |
| 2026-11-12 | v0.2: region check from harness, proxy vs. direct, 9 services | ✅ all classified correctly (8 OK + Groq blocked via proxy; 9 blocked direct) |
| 2026-11-12 | v0.2: terminal script with a `it's a test dir` path, run with a fake shell | ✅ right folder, variables exported, script deleted itself |
| 2026-11-12 | Menu panel height stays fixed: message shown/cleared, region check running/done (invisible panel) | ✅ 167 pt throughout |
| — | Notifications, onboarding and menu UI clicked through by hand | ⏳ needs a manual pass |
