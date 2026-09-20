# Deepseek Harness for macOS

A lightweight macOS shell around the [`dsh web`](https://www.npmjs.com/package/@deepseek-ai/dsh) interface.

The app starts a local `dsh web --no-open --port 49258` process, loads the printed authenticated URL in a `WKWebView`, and keeps the service available from the menu bar when the main window is closed.

## Features

- Native `WKWebView` host for the Deepseek Harness web UI.
- Uses the `dsh` executable found in common fnm, Volta, Bun, Homebrew, and local bin locations.
- Does not depend on a terminal `PATH`, so it also works when launched from Finder.
- Starts a fresh `dsh web` process with its own authentication token.
- Detects an existing `dsh web` listener on port `49258` and replaces it safely.
- Refuses to terminate an unrelated process occupying port `49258`.
- Keeps the service running after the main window is closed.
- Menu bar icon:
  - Left click: open the main window.
  - Right click: open the menu.
- Menu actions:
  - `Restart`: restart `dsh web` and reload the web view.
  - `Quit`: stop the service and quit the app.
- External HTTP(S) links opened by the web UI are handed to the default browser.

## Requirements

- macOS 26 or later.
- Xcode 26 or later.
- A working `dsh` installation. The app looks for it in:
  - `~/.local/share/fnm/aliases/default/bin`
  - active fnm multishell directories
  - `~/.volta/bin`
  - `~/.bun/bin`
  - `~/.local/bin`
  - `/opt/homebrew/bin`
  - `/usr/local/bin`
  - `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`

The current project targets macOS 26.0 and uses the macOS 26 icon and menu bar APIs.

## Build

Open `dsh-desktop.xcodeproj` in Xcode and run the `dsh-desktop` scheme, or build from Terminal:

```sh
xcodebuild \
  -project dsh-desktop.xcodeproj \
  -scheme dsh-desktop \
  -configuration Release \
  -derivedDataPath /tmp/dsh-desktop-release \
  build
```

The resulting app is:

```text
/tmp/dsh-desktop-release/Build/Products/Release/Deepseek Harness.app
```

To install it locally:

```sh
cp -R "/tmp/dsh-desktop-release/Build/Products/Release/Deepseek Harness.app" /Applications/
```

## How It Works

`DSHWebService` launches:

```sh
"$DSH_EXECUTABLE" web --no-open --port 49258
```

It parses the authenticated URL printed by `dsh`, then exposes that URL through `DSHWebState.running`. `ContentView` renders it in `WKWebView`.

When `Restart` is selected, the app stops the current process, waits for port `49258` to be released, starts a new process, increments `reloadID`, and recreates the web view so the new token URL is loaded.

## Project Layout

```text
dsh-desktop/
├── ContentView.swift          # SwiftUI screen and WKWebView integration
├── DSHWebService.swift        # dsh process, URL parsing, and lifecycle
├── dsh_desktopApp.swift       # App entry point and menu bar behavior
├── AppIcon.icon/              # macOS 26 Icon Composer app icon
└── Assets.xcassets/
    └── TrayIcon.imageset/     # Menu bar icon
```

## Notes

- The app uses port `49258` and passes it explicitly with `--port`.
- The token URL is process-specific. The app does not reuse a token from an older `dsh web` process.
- `TrayIcon` is intentionally separate from `AppIcon.icon`. Application icons use the full rounded-square composition, while menu bar icons have different sizing and rendering requirements.

## License

MIT. See [LICENSE](LICENSE).
