# ProxyBar

Launch selected Mac apps through an HTTP or SOCKS5 proxy from the menu bar. ProxyBar shows whether the proxy port is reachable, reads running apps’ proxy settings where macOS permits it, and checks which services answer through the proxy.

## Get started

Requires macOS 14 or later and the Command Line Tools with Swift 6. Install the tools with `xcode-select --install` if needed.

From the project directory, build and open the app:

```sh
./build.sh
open build/ProxyBar.app
```

To keep a copy in `~/Applications`, use `./build.sh --install`. Use `./build.sh --run` to install and open it. The build uses ad-hoc signing for local use.

On first launch, enter the host and port from your proxy app, choose the apps and services you use, and set your login and notification preferences. You can rerun setup from **Settings → Proxy → Run setup again…**.

## Use ProxyBar

- **Launch apps.** Add apps in **Settings → Apps**. Launch a stopped app from the menu or use **Relaunch** to restart a running app with your proxy settings. Right-click the stop button for **Force Quit**.
- **Clean up after quitting.** Use the trash button when an app row shows leftover processes. ProxyBar asks before including processes outside the app bundle that match a configured name pattern. Automatic cleanup in **Settings → Proxy** is limited to processes inside the bundle.
- **Check services.** Use the refresh button in the menu or open **Settings → Region** for per-service results. ProxyBar reports the exit IP and country when available. Choose which services to check, add custom endpoints, and set an automatic interval from 5 seconds to 1 hour. Each interval starts when the previous check finishes.
- **Open a proxied shell.** Use **Terminal with proxy** for your home folder, a chosen folder, or a recent folder. Choose Terminal, iTerm, Ghostty, or Kitty in **Settings → Proxy**. The picker lists installed terminals. Use **Copy shell exports** to configure an existing shell.
- **Automate startup and alerts.** Enable **Open ProxyBar at login** in the Proxy tab and **Start with ProxyBar** for individual apps. You can also enable alerts for proxy outages, recovery, and newly blocked services.

## How proxy settings apply

ProxyBar supplies `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` when it launches an app. SOCKS5 also sets `ALL_PROXY`. You can enable lowercase variants and set `NODE_USE_ENV_PROXY=1` for Node.js 24+ `fetch()`. For supported Chromium/Electron apps, ProxyBar can also pass proxy and bypass flags. Add per-app overrides under **Extra environment** in the Apps tab. Each app controls which network requests honor these settings.

Region checks send unauthenticated requests to the selected endpoints, plus Google for latency and Cloudflare for exit information. Opt in to direct comparison during setup or in **Settings → Region** to also contact the selected endpoints and Cloudflare outside the proxy. An expected authentication response such as HTTP 401 can mean the endpoint is available.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, development setup, and icon generator.
