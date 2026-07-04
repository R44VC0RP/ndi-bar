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
  Microphone
  ✓ Capture Microphone
    System Default
  ✓ MacBook Pro Microphone
    Elgato Wave:3
─────
  Stop All Streams            ⌘.
─────
  Settings…                   ⌘,
─────
  Quit ndi-bar                ⌘Q
```

## Status

v0.2.0 (build 2) release candidate. It adds bounded custom capture resolution
and frame-rate controls, automatic active-stream reconfiguration, safer
capture/sender teardown, lifecycle tests, and a reproducible signed-release
workflow. Audio capture uses ScreenCaptureKit's built-in system-audio tap (no
virtual audio device required), with optional selectable microphone capture on
macOS 15 or later.

Automated builds and unit tests cover configuration and lifecycle logic, but
this release has not yet been validated end-to-end with a live NDI receiver or
OBS/DistroAV. No performance or latency benchmarks are claimed.

## Requirements

- macOS 14.0 or later
- Xcode 16+ (Swift 5.10)
- [NDI SDK for Apple](https://ndi.video/sdk) installed at
  `/Library/NDI SDK for Apple/` — free from ndi.video
- Screen Recording permission (macOS will prompt on first launch)
- Microphone permission if microphone capture is enabled (macOS 15+)

## Build & install

```sh
brew install xcodegen
make gen        # generates ndi-bar.xcodeproj from project.yml
make install    # Release-builds and copies ndi-bar.app into ~/Applications
# or, for iterating:
make run        # builds Debug and launches from DerivedData
make kill       # stop the running menubar app
```

## Microphone capture

Microphone capture is available on macOS 15 or later. Enable it from either
**Settings → Capture → Capture microphone** or the menubar's **Microphone**
section.

The microphone picker lists `System Default` plus detected input devices such
as the built-in MacBook mic, USB microphones, AirPods, and iPhone microphones.
The selected input is remembered. If that device is later disconnected,
ndi-bar keeps the selection visible as unavailable so you can switch back to
`System Default` or choose another input.

Microphone and other capture-setting changes automatically restart active
display streams after a short debounce.

## Frame rate and resolution

Settings accepts any whole-number frame rate from **1 through 120 fps**. This
sets both ScreenCaptureKit's requested minimum frame interval and the NDI frame
rate metadata. Actual frame delivery can still be limited by the display's
refresh rate and ScreenCaptureKit's capture cadence.

Resolution can be **Native**, a preset, or a custom maximum width × height.
Presets and custom values are bounding boxes, not forced canvases: ndi-bar fits
the ScreenCaptureKit source pixels within both limits, preserves aspect ratio,
never intentionally upscales, and emits positive even NDI dimensions. Native
uses ScreenCaptureKit's macOS 14+ `contentRect × pointPixelScale` semantics.
Active streams briefly restart after capture changes settle so the effective
configuration remains consistent.

## Receiving the stream

Once a monitor is toggled on in ndi-bar, any NDI-compatible software on the
same LAN can pick it up.

### Quick sanity check — NDI Video Monitor

Fastest way to confirm the stream is live before touching OBS:

1. Download [NDI Tools](https://ndi.video/tools) (free).
2. Run **NDI Video Monitor**.
3. Right-click anywhere in the window → your Mac's hostname → the ndi-bar
   source name. It looks like `Ryan-MacStudio – Display 1 (LG HDR 4K 2560×1440)`.

If you can see live video here, the sender half is working and any issues
from here on are on the receiver side.

### Receiving in OBS Studio with DistroAV

OBS doesn't include NDI support out of the box. Install both the current
**DistroAV** plugin (formerly obs-ndi) and the separately distributed **NDI
Runtime** required by the plugin on the receiver machine.

1. **Install OBS** — `brew install --cask obs`, or grab the installer from
   <https://obsproject.com/download>.
2. **Install DistroAV and its required NDI Runtime** — use the current release
   and installation notes at <https://github.com/DistroAV/DistroAV/releases>.
   Quit and relaunch OBS afterwards.
3. **Add an NDI source:**
   - In the OBS **Sources** panel, click **+** → **NDI™ Source**.
   - Name it whatever you want ("Monitor 1", etc.) → **OK**.
   - In the properties dialog:
     - **Source name** — the dropdown lists every NDI source on the LAN.
       Pick the ndi-bar entry for the monitor you want. One entry per
       display you've toggled on.
      - **Bandwidth** — start with `Highest` as the correctness baseline.
      - **Sync / Timing** — test both `Source Timing` and `Network`; receiver,
        network, and audio-clock behavior determines which is better.
     - **Latency Mode** — `Low` for general use, `Lowest` if you need
       sub-frame latency and can tolerate the occasional audio glitch.
     - Leave the rest at defaults. Audio comes in on the same source.
4. Resize the source in the preview canvas to fit.

Matching resolutions helps avoid needless rescaling: if ndi-bar is set to
1440p (in Settings) and your OBS canvas is 1080p, OBS will downscale
every frame. Set **Settings → Video → Base (Canvas) Resolution** to match
what you're sending, or go the other way and bump ndi-bar's output
resolution in its Settings window.

### Troubleshooting discovery

If OBS's source dropdown is empty or missing ndi-bar:

- Confirm ndi-bar is actually streaming — the menubar icon should be the
  radio-waves glyph and the display row should have a checkmark.
- Confirm the DistroAV plugin and its separately installed NDI Runtime are both
  present on the receiver.
- Start with sender and receiver on the same wired or Wi-Fi LAN/subnet. NDI
  discovery generally doesn't cross VLANs without an [NDI Discovery
  Server](https://docs.ndi.video/tools/discovery-and-registration/ndi-discovery-service).
- Check firewalls on both machines: allow OBS/DistroAV and ndi-bar local-network
  discovery and media traffic.
- Restart the NDI plugin's discovery: in OBS, Tools → NDI™ Plugin Settings
  → Main Output: off, then on again.

### Other NDI-compatible receivers

Same discovery story applies to all of these — the ndi-bar source just
shows up in whatever NDI picker they use:

- **vMix**, **Wirecast**, **TriCaster** — broadcast/studio switchers
- **Resolume Arena**, **TouchDesigner**, **Notch** — live visuals
- **Zoom** with NDI plugin enabled
- Any other app that lists NDI Tools' SDK as a supported input

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
# Set MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml first.
make gen
TEAM_ID=ABCDE12345 make dist
# produces the signed, notarized, and stapled v0.2.0 artifacts:
#   dist/ndi-bar-v0.2.0.zip
#   dist/ndi-bar-v0.2.0.zip.sha256

# The checksum uses only the archive basename, so it verifies from a download
# directory containing both files:
(cd dist && shasum -a 256 -c ndi-bar-v0.2.0.zip.sha256)
```

`make sign` stops after a clean universal Developer-ID build and strict
signature verification. `make dist` additionally checks the notary keychain
profile, submits a temporary archive, requires an `Accepted` result, staples
and validates the app, and creates the final archive and checksum. It does not
install the app, reset TCC, bundle the NDI runtime, tag or push git, or publish
a GitHub release. Review the artifacts before doing those repository-hosting
steps separately. Set `DEVELOPER_DIR` in the invoking environment when a
specific stable Xcode installation is required.

The ordinary `make build`, `make release`, `make run`, and `make install`
flows do not require release credentials and remain ad-hoc signed for local
development.

## Screen Recording permission quirk

ndi-bar is ad-hoc signed during local development (`CODE_SIGN_IDENTITY: "-"`).
Every rebuild changes the binary's `cdhash`, and macOS 14+ TCC binds the
Screen Recording grant to that hash. Without intervention, the
System Settings toggle stays *on* while `CGPreflightScreenCaptureAccess()`
quietly returns *false*, and the menubar icon becomes a warning triangle.

`make install` handles this automatically: it runs TCC resets right before
launching the new build so macOS treats it as a first-time request. Click the
menubar icon → **Grant Screen Recording** → Allow → relaunch. If microphone
capture is enabled, macOS will also ask for Microphone access the first time
you start a stream.

If things ever get stuck (stale grants from an older path, etc.), reset
manually:

```sh
make reset-tcc
open ~/Applications/ndi-bar.app
```

A proper Developer ID signature would avoid this entirely (TCC binds to
Team ID instead of cdhash) — done via `make dist` when you're ready to
distribute.

## Known limitations

- Live NDI discovery, playback, and OBS/DistroAV interoperability still need
  release-candidate validation on representative sender/receiver systems.
- ScreenCaptureKit's asynchronous `stopCapture` can fail or fail to return.
  The shutdown watchdog bounds quit time but deliberately avoids unsafe NDI
  destruction/unloading when teardown has not completed.
- Global NDI library initialization and unloading remain coordinated from the
  main actor; sender creation and destruction use a dedicated background queue.
- Concurrent audio/video delivery is supported by the implementation, but its
  runtime behavior has not yet been guaranteed by end-to-end stress testing.
- The dynamic loader trusts NDI libraries found in the documented local SDK
  installation paths. `libndi.dylib` is never bundled with ndi-bar.

## Architecture

```
SCShareableContent ─► [SCDisplay] ─► [DisplayInfo]
                                           │
                      toggle on per-display│
                                           ▼
                               DisplayStreamer
                                │           │
                         SCStream (BGRA)    │
                                │           ▼
              SCStreamOutput .screen      ─► NDISender.sendVideo
              SCStreamOutput .audio       ┐
              SCStreamOutput .microphone  ┴─► NDISender.sendAudio
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
