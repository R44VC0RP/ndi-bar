// StreamingController.swift
// Central coordinator: owns the list of displays and the set of active
// DisplayStreamers. Publishes state for SwiftUI / menubar observation.

import Foundation
import AppKit
import Combine
import ScreenCaptureKit

/// Max height the NDI output frame is scaled down to. Aspect ratio is
/// preserved; a display already under the cap is passed through untouched.
enum OutputResolutionCap: String, CaseIterable, Identifiable {
    case native
    case p1440
    case p1080
    case p720

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: return "Native"
        case .p1440:  return "1440p"
        case .p1080:  return "1080p"
        case .p720:   return "720p"
        }
    }

    /// Maximum output height in pixels, or nil for no downscale.
    var maxHeight: Int? {
        switch self {
        case .native: return nil
        case .p1440:  return 1440
        case .p1080:  return 1080
        case .p720:   return 720
        }
    }
}

@MainActor
final class StreamingController: ObservableObject {

    // MARK: Persisted preferences

    private enum Keys {
        static let sourcePrefix   = "sourcePrefix"
        static let fps            = "fps"
        static let resolutionCap  = "resolutionCap"
        static let legacy1080pBool = "limitTo1080p"
        static let showsCursor    = "showsCursor"
        static let captureAudio   = "captureAudio"
    }

    @Published var sourcePrefix: String {
        didSet { UserDefaults.standard.set(sourcePrefix, forKey: Keys.sourcePrefix) }
    }
    @Published var fps: Int {
        didSet { UserDefaults.standard.set(fps, forKey: Keys.fps) }
    }
    @Published var resolutionCap: OutputResolutionCap {
        didSet { UserDefaults.standard.set(resolutionCap.rawValue, forKey: Keys.resolutionCap) }
    }
    @Published var showsCursor: Bool {
        didSet { UserDefaults.standard.set(showsCursor, forKey: Keys.showsCursor) }
    }
    @Published var captureAudio: Bool {
        didSet { UserDefaults.standard.set(captureAudio, forKey: Keys.captureAudio) }
    }

    // MARK: Observable state

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var activeDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var ndiReady: Bool = false
    @Published private(set) var lastError: String?
    /// Whether screen recording is granted for this exact build (cdhash).
    /// This is the source of truth; the System Settings toggle can look "on"
    /// while still being denied if the app was ad-hoc signed and rebuilt.
    @Published private(set) var screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()

    // MARK: Internals

    private var streamers: [CGDirectDisplayID: DisplayStreamer] = [:]
    private var refreshTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        self.sourcePrefix = (d.string(forKey: Keys.sourcePrefix)?.nilIfEmpty) ?? Host.defaultSourcePrefix()
        self.fps = {
            let raw = d.integer(forKey: Keys.fps)
            return raw == 0 ? 60 : raw
        }()

        // Preference migration: v0.1 stored a single bool, v0.2 stores an enum.
        // If the old key exists, translate it once and remove it so we never
        // fall back to the legacy path again.
        if let raw = d.string(forKey: Keys.resolutionCap),
           let cap = OutputResolutionCap(rawValue: raw) {
            self.resolutionCap = cap
        } else if let legacy = d.object(forKey: Keys.legacy1080pBool) as? Bool {
            let migrated: OutputResolutionCap = legacy ? .p1080 : .native
            self.resolutionCap = migrated
            d.set(migrated.rawValue, forKey: Keys.resolutionCap)
            d.removeObject(forKey: Keys.legacy1080pBool)
        } else {
            self.resolutionCap = .p1080
        }

        self.showsCursor  = d.object(forKey: Keys.showsCursor)  as? Bool ?? true
        self.captureAudio = d.object(forKey: Keys.captureAudio) as? Bool ?? true

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshDisplays() }
        }

        NotificationCenter.default.addObserver(
            forName: .displayStreamFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let id = note.userInfo?["displayID"] as? CGDirectDisplayID else { return }
                self.activeDisplayIDs.remove(id)
                self.streamers[id] = nil
                if let err = note.userInfo?["error"] as? Error {
                    self.lastError = err.localizedDescription
                }
            }
        }
    }

    // MARK: Bootstrap

    func boot() async {
        do {
            try NDILibrary.shared.load()
            ndiReady = true
        } catch {
            ndiReady = false
            lastError = error.localizedDescription
            NSLog("[ndi-bar] NDI load failed: \(error.localizedDescription)")
        }
        refreshPermissionState()
        await refreshDisplays()
    }

    /// Re-query TCC for the current cdhash. Call after the permissions menu
    /// item is invoked or when the app becomes active, since grant state
    /// normally doesn't change mid-session.
    func refreshPermissionState() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: Display enumeration

    func refreshDisplays() async {
        // Don't invoke SCShareableContent until TCC is definitely granted —
        // calling it unprompted is what triggers macOS's screen-recording
        // prompt on every launch.
        guard screenRecordingGranted else {
            self.displays = []
            return
        }
        do {
            let list = try await DisplayEnumerator.currentDisplays()
            self.displays = list

            // Drop any streamers whose display vanished.
            let knownIDs = Set(list.map(\.id))
            for (id, s) in streamers where !knownIDs.contains(id) {
                await s.stop()
                streamers[id] = nil
                activeDisplayIDs.remove(id)
            }
        } catch {
            NSLog("[ndi-bar] refresh failed: \(error)")
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Start / stop

    func isStreaming(_ display: DisplayInfo) -> Bool {
        activeDisplayIDs.contains(display.id)
    }

    /// Number of NDI receivers currently connected to this display's stream.
    /// Returns -1 if the display isn't currently streaming.
    func viewerCount(for display: DisplayInfo) -> Int {
        guard let streamer = streamers[display.id] else { return -1 }
        return Int(streamer.connectionCount)
    }

    func toggle(_ display: DisplayInfo) {
        if isStreaming(display) {
            Task { await stop(display) }
        } else {
            Task { await start(display) }
        }
    }

    func start(_ display: DisplayInfo) async {
        guard ndiReady else {
            lastError = "NDI runtime not loaded — install the NDI SDK from https://ndi.video/sdk."
            return
        }
        if streamers[display.id] != nil { return }

        let sourceName = ndiName(for: display)
        let quality = StreamQuality(
            targetWidth:  nil,
            targetHeight: resolutionCap.maxHeight,
            fps: fps,
            capturesAudio: captureAudio,
            showsCursor: showsCursor
        )
        let streamer = DisplayStreamer(
            display: display,
            ndiSourceName: sourceName,
            quality: quality
        )
        do {
            try await streamer.start()
            streamers[display.id] = streamer
            activeDisplayIDs.insert(display.id)
        } catch {
            NSLog("[ndi-bar] start failed: \(error)")
            lastError = error.localizedDescription
        }
    }

    func stop(_ display: DisplayInfo) async {
        guard let streamer = streamers[display.id] else { return }
        await streamer.stop()
        streamers[display.id] = nil
        activeDisplayIDs.remove(display.id)
    }

    func stopAll() async {
        for (id, streamer) in streamers {
            await streamer.stop()
            streamers[id] = nil
        }
        activeDisplayIDs.removeAll()
    }

    // MARK: Permissions

    /// Triggers macOS's own screen-recording prompt via CGRequestScreenCaptureAccess.
    /// Pairs with `openScreenRecordingSettings()` for the fallback path.
    ///
    /// On ad-hoc signed builds, newly granted permission frequently won't
    /// take effect until the process is relaunched (TCC evaluates at startup).
    /// Callers should expect this and surface a restart hint if needed.
    func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissionState()
    }

    /// Deep-links to System Settings → Privacy & Security → Screen & System
    /// Audio Recording. Useful when the user has a stale TCC record that
    /// shows the toggle on but still denies access.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: NDI naming

    private func ndiName(for display: DisplayInfo) -> String {
        let resStr = "\(display.width)×\(display.height)"
        return "\(sourcePrefix) – Display \(display.ordinal) (\(display.localizedName) \(resStr))"
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum Host {
    static func defaultSourcePrefix() -> String {
        if let name = Host.computerName() { return name }
        return "Mac"
    }

    private static func computerName() -> String? {
        // `Host.current().localizedName` is a common source; we strip ".local"
        // and trailing punctuation. Falls back to nil on failure.
        if let name = ProcessInfo.processInfo.hostName
            .split(separator: ".")
            .first
            .map(String.init) {
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
