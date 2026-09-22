# AGENTS.md

## Project Overview

This repository contains a native macOS SwiftUI wrapper around the `dsh web`
interface. The app:

- Starts `dsh web --no-open --port 49258` as a child process.
- Parses the authenticated URL printed by `dsh`.
- Renders that URL in a `WKWebView`.
- Keeps running as a menu bar application after the main window is closed.

The project has no package manager or third-party dependencies. It is built
directly with Xcode and targets macOS 26 or later.

The application is intentionally built without Apple Development or Developer
ID signing and is not notarized. It is a personal-use build only, not a
distribution-ready application. Do not add signing or notarization steps.

## Project Layout

- `dsh-desktop/dsh_desktopApp.swift`: App entry point, window scene, status bar
  item, and app lifecycle.
- `dsh-desktop/ContentView.swift`: SwiftUI states and the `WKWebView`
  integration.
- `dsh-desktop/DSHWebService.swift`: `dsh` process discovery, startup,
  restart, port cleanup, URL parsing, and process state.
- `dsh-desktop/AppIcon.icon/`: macOS 26 Icon Composer application icon.
- `dsh-desktop/Assets.xcassets/`: application assets, including the separate
  menu bar icon.

## Build And Verification

Use the project and scheme names exactly:

```sh
xcodebuild \
  -project dsh-desktop.xcodeproj \
  -scheme dsh-desktop \
  -configuration Debug \
  -derivedDataPath /tmp/dsh-desktop-derived \
  build
```

Unsigned Debug build:

```sh
xcodebuild \
  -project dsh-desktop.xcodeproj \
  -scheme dsh-desktop \
  -configuration Debug \
  -derivedDataPath /tmp/dsh-desktop-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Unsigned Release build:

```sh
xcodebuild \
  -project dsh-desktop.xcodeproj \
  -scheme dsh-desktop \
  -configuration Release \
  -derivedDataPath /tmp/dsh-desktop-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

There is currently no test target. After changing process lifecycle, web
loading, or menu bar behavior, verify manually with a working `dsh`
installation:

1. Start the app and confirm the authenticated web UI loads.
2. Select `Restart` and confirm a new process and token URL are loaded.
3. Close the main window and reopen it from the menu bar icon.
4. Select `Quit` and confirm the `dsh` child process exits.
5. If startup behavior changes, check port `49258` with
   `lsof -nP -iTCP:49258 -sTCP:LISTEN`.

Do not commit generated build products, `DerivedData`, or Xcode user state.

## Implementation Constraints

- Keep `DSHWebService` on the main actor. Pipe and termination callbacks may run
  off the main actor and must hop back safely before changing observable state.
- Preserve the process identity checks in output callbacks. Data from an old
  process must never update the state of a newly started process.
- Port `49258` is intentional. Before terminating a listener, verify that its
  command is the expected `dsh web --no-open --port 49258` process. Never kill
  an unrelated process.
- A fresh `dsh web` process produces a process-specific authenticated URL.
  Do not cache or reuse URLs or tokens after restart.
- Keep AppKit and WebKit behavior explicit and localized. Use SwiftUI for view
  composition and AppKit only where the platform APIs require it.
- Treat injected web styles and scripts as compatibility code for the external
  `dsh` UI. Keep selectors narrow and limited to the intended page.
- Preserve external-link behavior: same-host popup navigations stay in the
  web view, while external HTTP(S) links open in the default browser.
- `TrayIcon` and the application icon are intentionally separate assets. Do
  not reuse the full application icon as the menu bar image.

## Change Discipline

- Read the full process lifecycle in `DSHWebService.swift` before modifying
  startup, restart, or shutdown behavior.
- Keep changes scoped to the existing Swift files and project configuration.
  Avoid introducing an abstraction unless it removes meaningful duplication or
  matches an established platform pattern.
- After any code or project configuration change, compile the project before
  deployment. Required builds and relevant manual checks must all pass; do not
  install a failed or unverified build.
- After all required checks pass, overwrite-replace the successful unsigned
  Release build at the system-level `/Applications/Deepseek Harness.app`
  location:

  ```sh
  rm -rf "/Applications/Deepseek Harness.app"
  ditto \
    "/tmp/dsh-desktop-derived/Build/Products/Release/Deepseek Harness.app" \
    "/Applications/Deepseek Harness.app"
  ```

  The deletion is limited to `/Applications/Deepseek Harness.app`; remove the
  old app bundle before moving the new build into place so stale files cannot
  survive. If the write requires elevated permissions and they are unavailable,
  report the failure clearly; do not silently fall back to another directory.
- When project settings or lifecycle behavior changes, run both the Debug
  build and the relevant manual checks above before installing the Release
  build.
