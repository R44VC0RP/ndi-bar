// StreamingController.swift
// Central coordinator: owns the list of displays and the set of active
// DisplayStreamers. Publishes state for SwiftUI / menubar observation.

import Foundation
import AppKit
import AVFoundation
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

struct MicrophoneDevice: Identifiable, Equatable {
    static let systemDefaultID = "__ndi_bar_system_default_microphone__"

    let id: String
    let name: String
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
        static let captureMicrophone = "captureMicrophone"
        static let selectedMicrophoneDeviceID = "selectedMicrophoneDeviceID"
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
    @Published var captureMicrophone: Bool {
        didSet { UserDefaults.standard.set(captureMicrophone, forKey: Keys.captureMicrophone) }
    }
    @Published var selectedMicrophoneDeviceID: String {
        didSet {
            if selectedMicrophoneDeviceID == MicrophoneDevice.systemDefaultID {
                UserDefaults.standard.removeObject(forKey: Keys.selectedMicrophoneDeviceID)
            } else {
                UserDefaults.standard.set(selectedMicrophoneDeviceID, forKey: Keys.selectedMicrophoneDeviceID)
            }
        }
    }

    // MARK: Observable state

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var microphoneDevices: [MicrophoneDevice] = []
    @Published private(set) var activeDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var ndiReady: Bool = false
    @Published private(set) var lastError: String?
    /// Whether screen recording is granted for this exact build (cdhash).
    /// This is the source of truth; the System Settings toggle can look "on"
    /// while still being denied if the app was ad-hoc signed and rebuilt.
    @Published private(set) var screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()
    @Published private(set) var microphonePermissionGranted: Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }()

    var microphoneCaptureSupported: Bool {
        DisplayStreamer.supportsMicrophoneCapture
    }

    var selectedMicrophoneDeviceUnavailable: Bool {
        selectedMicrophoneDeviceID != MicrophoneDevice.systemDefaultID &&
            !microphoneDevices.contains { $0.id == selectedMicrophoneDeviceID }
    }

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
        self.captureMicrophone = d.object(forKey: Keys.captureMicrophone) as? Bool ?? false
        self.selectedMicrophoneDeviceID = d.string(forKey: Keys.selectedMicrophoneDeviceID) ?? MicrophoneDevice.systemDefaultID

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
        refreshMicrophones()
        await refreshDisplays()
    }

    /// Re-query TCC for the current cdhash. Call after the permissions menu
    /// item is invoked or when the app becomes active, since grant state
    /// normally doesn't change mid-session.
    func refreshPermissionState() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphonePermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func refreshMicrophones() {
        guard microphoneCaptureSupported else {
            microphoneDevices = []
            return
        }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        microphoneDevices = session.devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    func selectMicrophoneDevice(_ id: String) {
        selectedMicrophoneDeviceID = id
        refreshMicrophones()
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
        guard await ensureMicrophoneReadyIfNeeded() else { return }

        let sourceName = ndiName(for: display)
        let quality = StreamQuality(
            targetWidth:  nil,
            targetHeight: resolutionCap.maxHeight,
            fps: fps,
            capturesAudio: captureAudio,
            capturesMicrophone: captureMicrophone,
            microphoneDeviceID: activeMicrophoneCaptureDeviceID,
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

    /// Kicks macOS into actually adding us to the Screen Recording TCC list
    /// and (when in the "not determined" state) showing its native prompt.
    ///
    /// Two APIs are involved for a reason:
    ///   1. `CGRequestScreenCaptureAccess` — the documented hook. Shows the
    ///      native prompt only when TCC has no record yet.
    ///   2. `SCShareableContent.excludingDesktopWindows` — the API that
    ///      actually forces TCC to register the app. Without an explicit
    ///      capture attempt, `CGRequestScreenCaptureAccess` alone can be
    ///      a no-op and the app never appears in the Settings list.
    ///
    /// We do NOT open System Settings automatically — doing so steals focus
    /// from the native prompt if one is about to appear. The menu provides a
    /// separate "Open Privacy Settings…" item for manual recovery.
    ///
    /// On ad-hoc signed builds, newly granted permission usually won't take
    /// effect until the process is relaunched (TCC evaluates at startup).
    func requestScreenRecordingPermission() async {
        _ = CGRequestScreenCaptureAccess()
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Expected to throw the first time — the thrown error is the
            // side effect that registers us in TCC so we appear in Settings.
            NSLog("[ndi-bar] permission probe: \(error.localizedDescription)")
        }
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

    func requestMicrophonePermission() async {
        _ = await AVCaptureDevice.requestAudioAccess()
        refreshPermissionState()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureMicrophoneReadyIfNeeded() async -> Bool {
        guard captureMicrophone else { return true }
        guard microphoneCaptureSupported else {
            lastError = "Microphone capture requires macOS 15 or later."
            return false
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionGranted = true
            refreshMicrophones()
            return ensureSelectedMicrophoneAvailable()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAudioAccess()
            microphonePermissionGranted = granted
            if !granted {
                lastError = "Microphone permission was not granted."
            }
            refreshMicrophones()
            return granted && ensureSelectedMicrophoneAvailable()
        case .denied, .restricted:
            microphonePermissionGranted = false
            lastError = "Microphone permission is denied. Enable it in System Settings → Privacy & Security → Microphone."
            return false
        @unknown default:
            microphonePermissionGranted = false
            lastError = "Microphone permission state is unknown."
            return false
        }
    }

    private var activeMicrophoneCaptureDeviceID: String? {
        guard selectedMicrophoneDeviceID != MicrophoneDevice.systemDefaultID else { return nil }
        guard microphoneDevices.contains(where: { $0.id == selectedMicrophoneDeviceID }) else { return nil }
        return selectedMicrophoneDeviceID
    }

    private func ensureSelectedMicrophoneAvailable() -> Bool {
        guard selectedMicrophoneDeviceID != MicrophoneDevice.systemDefaultID else { return true }
        if microphoneDevices.contains(where: { $0.id == selectedMicrophoneDeviceID }) {
            return true
        }
        lastError = "Selected microphone is not available. Choose another microphone or use System Default."
        return false
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

private extension AVCaptureDevice {
    static func requestAudioAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
