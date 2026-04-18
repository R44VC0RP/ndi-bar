# AGENTS.md

## Purpose
- Repository guidance for agentic coding tools working in ndi-bar.
- Project is a macOS menu bar NDI screen sender (SwiftUI + AppKit).
- Primary target: `ndi-bar` (no test target yet).

## Repository Layout
- `project.yml` — xcodegen manifest. Single source of truth for the Xcode project.
- `ndi-bar/` — Swift sources, entitlements, Info.plist, Assets.xcassets.
  - `NDI/` — Runtime loader and C-struct mirrors for libndi.dylib.
  - `Capture/` — ScreenCaptureKit enumeration and per-display streaming.
  - `State/` — `StreamingController` (the @MainActor ObservableObject).
  - `Menu/` — NSStatusItem/NSMenu controller.
  - `UI/` — SwiftUI Settings view.
- `Makefile` — `make gen | open | build | release | run | clean`.

## Tooling / Environment
- Xcode 16+ required (Swift 5.10, macOS 14+ deployment target).
- `xcodegen` required to materialize `ndi-bar.xcodeproj`. Install with
  `brew install xcodegen`; then `make gen`.
- `libndi.dylib` is loaded at runtime via `dlopen`. The build does NOT link
  against the NDI SDK, so the project compiles even without the SDK
  installed, but will refuse to stream until `/Library/NDI SDK for Apple/`
  exists. Do not add the NDI SDK to the Xcode project file.

## Build Commands
- Generate project:      `make gen`
- Open in Xcode:         `make open`
- Debug build (CLI):     `make build`
- Release build (CLI):   `make release`
- Launch .app:           `make run`
- Clean:                 `make clean`

Raw xcodebuild equivalents:
```sh
xcodebuild -project ndi-bar.xcodeproj -scheme ndi-bar \
  -configuration Debug -destination 'platform=macOS' build
```

## Release / Distribution
- Default local builds are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"` in
  `project.yml`). `make install` and `make run` use this. Good for dev,
  not good for handing to anyone else.
- For a signed+notarized release go through `make dist`. Required env:
  ```sh
  TEAM_ID=ABCDE12345 make dist
  ```
  Signing identity defaults to `Developer ID Application`. Notary
  credentials are loaded from the keychain profile in `NOTARY_PROFILE`
  (default: `NDIBAR_NOTARY`). Store them once via `make notary-login`.
- `make dist` does: sign Release build → verify codesign → zip → notarize
  via `xcrun notarytool submit --wait` → staple ticket → re-zip → sha256.
- Do NOT commit a Team ID to `project.yml`. Keep it in env.
- Do NOT bundle `libndi.dylib` inside the .app. Users install the NDI SDK
  themselves — required by the NDI license and keeps the app small.

## Test Commands
- No test target yet. When added, follow the Dictate pattern:
  ```sh
  xcodebuild -project ndi-bar.xcodeproj -scheme ndi-bar \
    -destination 'platform=macOS' test
  ```

## Lint / Static Checks
- No dedicated linter configured. Treat `xcodebuild` warnings as the primary
  static-check signal. Do not add linters unless explicitly requested.

## Architecture Notes (Important)
- `NDIBarApp.swift` is the `@main` entry point; it uses
  `@NSApplicationDelegateAdaptor` because menubar apps still need
  `NSStatusItem` wiring via AppKit.
- `AppDelegate` is `@MainActor` and owns the `StreamingController` plus the
  `StatusMenuController`.
- `StreamingController` (`@MainActor`, `ObservableObject`) coordinates:
  - NDI runtime loading
  - display enumeration (`SCShareableContent` + `NSScreen.localizedName`)
  - start/stop lifecycle per-display
  - persisted preferences (`UserDefaults`: sourcePrefix, fps, limitTo1080p,
    showsCursor, captureAudio)
  - screen-recording permission gate
- `DisplayStreamer` is NOT @MainActor — SCStream delivery callbacks must
  never touch the main actor on the hot path. It uses two dedicated serial
  queues (`captureQueue`, `audioQueue`).
- `NDILibrary` is a singleton that dlopen's libndi.dylib. All NDI C entry
  points are resolved via `dlsym` and stored as `@convention(c)` function
  pointers in `NDITypes.swift`. Do not introduce a bridging header.
- `NDISender` is RAII — destroying it calls `NDIlib_send_destroy`. One
  sender instance per captured display; sender lifetime is tied to the
  `DisplayStreamer` that owns it.

## Code Style Guidelines

### Imports
- Apple frameworks first, then third-party modules (none right now).
- One import per line.
- Avoid unused imports.

### Formatting
- 4-space indentation, no tabs.
- Match existing brace style in Swift files (`if`, `switch`, `Task`, closures).
- Prefer line breaks for long initializers over horizontal compression.
- Group related logic with `// MARK:` sections in larger files.

### Types and Declarations
- `struct` for SwiftUI views, value types, and mirrors of NDI C structs.
- `class` (usually `final`) for `ObservableObject`, `NS*` subclasses,
  `DisplayStreamer`, and `NDISender`.
- `enum` for modes, state, and preference keys.
- Use `private`/`fileprivate` aggressively.
- Maintain `@MainActor` isolation for UI/app orchestration types.
- When crossing async/background work back to UI, hop to the main actor
  explicitly (`Task { @MainActor in ... }` or `MainActor.run { ... }`).

### Naming Conventions
- Types: `UpperCamelCase` (`DisplayStreamer`, `StreamingController`).
- Properties/functions/locals: `lowerCamelCase`.
- Boolean names as predicates (`isStreaming`, `ndiReady`).
- Keep NDI C struct/function names exactly as in the NDI SDK headers
  (`NDIlib_video_frame_v2_t`) to make grepping against docs easy.

### Concurrency and Async Work
- Use `Task { ... }` for async work triggered from sync callbacks.
- Never block the main thread with capture I/O or NDI calls.
- SCStream delivery callbacks run on `captureQueue` / `audioQueue` — do not
  `Task.detached` out of them unless absolutely required; just do the NDI
  call inline.
- NDI async sending (`NDIlib_send_send_video_async_v2`) requires the pixel
  buffer to remain valid until the NEXT async send completes. Current code
  uses the synchronous v2 API to avoid that hazard. If you switch to async,
  implement the double-buffered retain discipline or wire up the async
  completion handler.

### Error Handling
- Prefer graceful fallback over hard failure.
- NDI SDK missing → surface a menubar error and link to ndi.video/sdk; do
  not crash.
- Screen recording permission missing → show one alert on boot, then just
  leave the menu showing the error state.
- Use `NSLog` for diagnostic output in capture/NDI paths; avoid `print`.

### State Management and Side Effects
- `LSUIElement` must stay true. Do not introduce a Dock icon or main window.
- Do not add app sandbox entitlements — screen capture and system audio
  capture both break under the sandbox without per-feature setup we haven't
  done.
- Preserve the menubar-only activation policy: `NSApp.setActivationPolicy(.accessory)`.

### NDI trademark / licensing
- Keep the "About NDI®" menu item and Settings footer referring to NDI as a
  registered trademark of Vizrt NDI AB.
- Do NOT change the NDI source naming scheme to drop the attribution.
- Do not distribute `libndi.dylib` inside the .app bundle; the app expects
  the user to install the SDK from ndi.video/sdk.

## Change Safety Checklist (for agents)
- Run `make gen && make build` after code changes.
- If you modify any file under `ndi-bar/` you usually don't need to re-run
  `make gen`; xcodegen picks up files by path. Re-run it when adding a new
  file AND you don't see it in Xcode, or when editing `project.yml`.
- If you change `UserDefaults` keys, add migration logic in
  `StreamingController.init` — users will already have values stored.
- If you change entitlements, re-verify that screen capture + system audio
  still work in a fresh `.app` (SwiftPM-built binaries have historically
  stripped entitlements silently; here we use xcodebuild so it should be
  fine, but sanity-check).
- Never introduce a bridging header for NDI. If you need a new NDI symbol,
  add the typealias to `NDITypes.swift` and `dlsym` it in `NDILibrary.swift`.

## Commit / PR Notes (If Requested)
- Summarize user-visible behavior changes.
- Mention any new NDI symbols resolved or macOS APIs relied on.
- Note whether `make build` succeeds; there are no automated tests yet.
