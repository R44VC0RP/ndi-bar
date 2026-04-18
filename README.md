# ndi-bar

Native macOS menubar app that broadcasts any of your connected displays as an
NDI® source on the LAN — no OBS, no Loopback, no BlackHole, no custom kernel
extension.

One menubar icon. One click to start streaming Monitor 1, 2, 3, or 4.

```
● ndi-bar
─────
  Displays
    Monitor 1 · Built-in Retina · 3456×2234
  ✓ Monitor 2 · DELL U2723QE    · 3840×2160  ·  2 viewers
    Monitor 3 · LG UltraFine    · 2560×1440
─────
  Stop All Streams            ⌘.
─────
  Settings…                   ⌘,
─────
  Quit ndi-bar                ⌘Q
```

## Status

v0.1.0 scaffold. Compiles, runs, and should light up an NDI source per
selected display. Audio capture uses ScreenCaptureKit's built-in system-audio
tap (no virtual audio device required).

## Requirements

- macOS 14.0 or later
- Xcode 16+ (Swift 5.10)
- [NDI SDK for Apple](https://ndi.video/sdk) installed at
  `/Library/NDI SDK for Apple/` — free from ndi.video
- Screen Recording permission (macOS will prompt on first launch)

## Build & install

```sh
brew install xcodegen
make gen        # generates ndi-bar.xcodeproj from project.yml
make install    # Release-builds and copies ndi-bar.app into ~/Applications
# or, for iterating:
make run        # builds Debug and launches from DerivedData
make kill       # stop the running menubar app
```

## Cutting a signed + notarized release

For public GitHub releases (so other people get a silent-launch .app on any
Mac without Gatekeeper warnings), you need a one-time Apple setup:

1. Enroll in the Apple Developer Program ($99/yr).
2. In Xcode → Settings → Accounts, sign in and create a **Developer ID
   Application** certificate. Note your Team ID.
3. Generate an app-specific password at <https://appleid.apple.com> →
   Sign-In and Security → App-Specific Passwords.
4. Store the notarytool credentials in the login keychain:
   ```sh
   TEAM_ID=ABCDE12345 make notary-login
   ```

Then each release:

```sh
# bump MARKETING_VERSION in project.yml first, then:
make gen
TEAM_ID=ABCDE12345 make dist
# produces dist/ndi-bar-vX.Y.Z.zip (signed, notarized, stapled) + .sha256

git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 \
  dist/ndi-bar-v1.0.0.zip \
  dist/ndi-bar-v1.0.0.zip.sha256 \
  --title "ndi-bar 1.0.0"
```

`make dist` won't touch your `make install` / `make run` flows — those stay
fast and ad-hoc signed for local development.

## Screen Recording permission quirk

ndi-bar is ad-hoc signed during local development (`CODE_SIGN_IDENTITY: "-"`).
Every rebuild changes the binary's `cdhash`, and macOS 14+ TCC binds the
Screen Recording grant to that hash. After a `make install`:

- The toggle in **System Settings → Privacy & Security → Screen & System
  Audio Recording** will still show *on* for ndi-bar.
- But `CGPreflightScreenCaptureAccess()` reports *false* because the hash
  stored in TCC no longer matches the fresh binary.

The menubar icon switches to a warning triangle when this happens and the
menu shows a "Grant Screen Recording…" action. Easiest fixes:

```sh
# Clear the stale record, then relaunch and approve the macOS prompt:
make reset-tcc
open ~/Applications/ndi-bar.app
```

Or manually: toggle ndi-bar *off* then *on* in the Settings pane and
relaunch the app. A proper Developer ID signature would avoid this (TCC
binds to Team ID instead of cdhash) — worth setting up before distributing.

## Architecture

```
SCShareableContent ─► [SCDisplay] ─► [DisplayInfo]
                                           │
                      toggle on per-display│
                                           ▼
                               DisplayStreamer
                                │           │
                        SCStream (BGRA, 60) │
                                │           ▼
              SCStreamOutput .screen  ─► NDISender.sendVideo
              SCStreamOutput .audio   ─► NDISender.sendAudio
                                           │
                                 dlopen'd libndi.dylib
                                           │
                                    NDI on the LAN
```

- `NDILibrary` (Swift): `dlopen`/`dlsym` the NDI SDK at runtime — no bridging
  header, no static linking (NDI's license forbids static linking anyway).
- `NDISender`: RAII wrapper around one `NDIlib_send_instance_t`. One per
  captured display.
- `DisplayStreamer`: owns an `SCStream` + an `NDISender`. Pumps BGRA frames
  and planar-float audio into NDI.
- `StreamingController`: `@MainActor` orchestrator published to SwiftUI and
  the status-bar menu.

## NDI® attribution

NDI® is a registered trademark of Vizrt NDI AB. This project is an
independent implementation and is not affiliated with or endorsed by Vizrt
NDI AB. If you distribute this app, include a visible link to
<https://ndi.video> near any NDI-related UI as required by the NDI SDK
License Agreement.

## License

MIT (see LICENSE).
