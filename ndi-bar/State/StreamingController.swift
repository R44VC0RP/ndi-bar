// StreamingController.swift
// Central coordinator: owns the list of displays and the set of active
// DisplayStreamers. Publishes state for SwiftUI / menubar observation.

import Foundation
import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

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
        static let showsCursor    = "showsCursor"
        static let captureAudio   = "captureAudio"
        static let captureMicrophone = "captureMicrophone"
        static let selectedMicrophoneDeviceID = "selectedMicrophoneDeviceID"
    }

    @Published var sourcePrefix: String {
        didSet {
            UserDefaults.standard.set(sourcePrefix, forKey: Keys.sourcePrefix)
            scheduleActiveStreamRestart()
        }
    }
    @Published var fps: Int {
        didSet {
            let normalized = CapturePreferences.normalizedFPS(fps)
            if fps != normalized {
                fps = normalized
                return
            }
            persistCapturePreferences()
            scheduleActiveStreamRestart()
        }
    }
    @Published var resolutionCap: OutputResolutionCap {
        didSet {
            persistCapturePreferences()
            scheduleActiveStreamRestart()
        }
    }
    @Published var customResolutionWidth: Int {
        didSet {
            let normalized = CapturePreferences.normalizedDimension(customResolutionWidth)
            if customResolutionWidth != normalized {
                customResolutionWidth = normalized
                return
            }
            persistCapturePreferences()
            if resolutionCap == .custom { scheduleActiveStreamRestart() }
        }
    }
    @Published var customResolutionHeight: Int {
        didSet {
            let normalized = CapturePreferences.normalizedDimension(customResolutionHeight)
            if customResolutionHeight != normalized {
                customResolutionHeight = normalized
                return
            }
            persistCapturePreferences()
            if resolutionCap == .custom { scheduleActiveStreamRestart() }
        }
    }
    @Published var showsCursor: Bool {
        didSet {
            UserDefaults.standard.set(showsCursor, forKey: Keys.showsCursor)
            scheduleActiveStreamRestart()
        }
    }
    @Published var captureAudio: Bool {
        didSet {
            UserDefaults.standard.set(captureAudio, forKey: Keys.captureAudio)
            scheduleActiveStreamRestart()
        }
    }
    @Published var captureMicrophone: Bool {
        didSet {
            UserDefaults.standard.set(captureMicrophone, forKey: Keys.captureMicrophone)
            scheduleActiveStreamRestart()
        }
    }
    @Published var selectedMicrophoneDeviceID: String {
        didSet {
            if selectedMicrophoneDeviceID == MicrophoneDevice.systemDefaultID {
                UserDefaults.standard.removeObject(forKey: Keys.selectedMicrophoneDeviceID)
            } else {
                UserDefaults.standard.set(selectedMicrophoneDeviceID, forKey: Keys.selectedMicrophoneDeviceID)
            }
            scheduleActiveStreamRestart()
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

    var captureConfigurationSummary: String {
        let resolution: String
        if resolutionCap == .custom {
            resolution = "fit within \(customResolutionWidth)×\(customResolutionHeight)"
        } else if let maximum = resolutionCap.maximumSize(
            customWidth: customResolutionWidth,
            customHeight: customResolutionHeight
        ) {
            resolution = "fit within \(maximum)"
        } else {
            resolution = "native SCK pixels"
        }
        return "\(fps) fps, \(resolution)"
    }

    // MARK: Internals

    private var streamers: [CGDirectDisplayID: DisplayStreamer] = [:]
    private var desiredActiveDisplayIDs: Set<CGDirectDisplayID> = []
    private var pendingRestartDisplayIDs: Set<CGDirectDisplayID> = []
    private var lifecycleTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var restartDebounceTask: Task<Void, Never>?
    private var refreshErrorMessage: String?
    private var stopAllDepth = 0
    private var isShuttingDown = false

    private var acceptsNewStreams: Bool {
        stopAllDepth == 0 && !isShuttingDown
    }

    init() {
        let d = UserDefaults.standard
        let capturePreferences = CapturePreferences(defaults: d)
        self.sourcePrefix = (d.string(forKey: Keys.sourcePrefix)?.nilIfEmpty) ?? Host.defaultSourcePrefix()
        self.fps = capturePreferences.fps
        self.resolutionCap = capturePreferences.resolutionCap
        self.customResolutionWidth = capturePreferences.customWidth
        self.customResolutionHeight = capturePreferences.customHeight

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
            let id = note.userInfo?["displayID"] as? CGDirectDisplayID
            let failedStreamer = note.object as? DisplayStreamer
            let errorDescription = (note.userInfo?["error"] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                guard let self,
                      let id,
                      let failedStreamer,
                      self.streamers[id] === failedStreamer else { return }
                self.desiredActiveDisplayIDs.remove(id)
                self.activeDisplayIDs.remove(id)
                if let errorDescription { self.lastError = errorDescription }
                self.ensureLifecycleTask(for: failedStreamer.display)
            }
        }
    }

    // MARK: Bootstrap

    func boot() async {
        do {
            try NDILibrary.shared.load()
            ndiReady = true
            lastError = nil
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
            if self.lastError == refreshErrorMessage { self.lastError = nil }
            refreshErrorMessage = nil

            // Drop any streamers whose display vanished.
            let knownIDs = Set(list.map(\.id))
            let vanished = streamers.values.filter { !knownIDs.contains($0.display.id) }
            for streamer in vanished {
                desiredActiveDisplayIDs.remove(streamer.display.id)
                ensureLifecycleTask(for: streamer.display)
            }
            for streamer in vanished {
                await lifecycleTasks[streamer.display.id]?.value
            }
        } catch {
            NSLog("[ndi-bar] refresh failed: \(error)")
            refreshErrorMessage = error.localizedDescription
            self.lastError = refreshErrorMessage
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
        if desiredActiveDisplayIDs.contains(display.id) {
            desiredActiveDisplayIDs.remove(display.id)
        } else {
            guard acceptsNewStreams else { return }
            desiredActiveDisplayIDs.insert(display.id)
        }
        ensureLifecycleTask(for: display)
    }

    func start(_ display: DisplayInfo) async {
        guard acceptsNewStreams else { return }
        guard ndiReady else {
            lastError = "NDI runtime not loaded — install the NDI SDK from https://ndi.video/sdk."
            return
        }
        desiredActiveDisplayIDs.insert(display.id)
        ensureLifecycleTask(for: display)
        await lifecycleTasks[display.id]?.value
    }

    func stop(_ display: DisplayInfo) async {
        desiredActiveDisplayIDs.remove(display.id)
        ensureLifecycleTask(for: display)
        await lifecycleTasks[display.id]?.value
    }

    func stopAll() async {
        stopAllDepth += 1
        defer { stopAllDepth -= 1 }

        restartDebounceTask?.cancel()
        restartDebounceTask = nil
        desiredActiveDisplayIDs.removeAll()
        pendingRestartDisplayIDs.removeAll()

        let affectedDisplays = Dictionary(
            uniqueKeysWithValues: streamers.values.map { ($0.display.id, $0.display) }
        )
        for display in affectedDisplays.values {
            ensureLifecycleTask(for: display)
        }

        while let task = lifecycleTasks.values.first {
            await task.value
        }
        // At this point no lifecycle task is transitional, so streamer
        // ownership is the authoritative final running-state snapshot.
        activeDisplayIDs = Set(streamers.keys)
    }

    /// Final shutdown barrier. Once this returns every SCStream has stopped
    /// and every NDI sender has been destroyed, so unloading libndi is safe.
    func shutdown() async {
        isShuttingDown = true
        await stopAll()
    }

    private func ensureLifecycleTask(for display: DisplayInfo) {
        guard lifecycleTasks[display.id] == nil else { return }
        lifecycleTasks[display.id] = Task { @MainActor [weak self] in
            await self?.reconcileLifecycle(for: display)
            self?.lifecycleTasks[display.id] = nil
        }
    }

    private func reconcileLifecycle(for display: DisplayInfo) async {
        while true {
            if !desiredActiveDisplayIDs.contains(display.id) {
                pendingRestartDisplayIDs.remove(display.id)
                guard let streamer = streamers[display.id] else { return }
                activeDisplayIDs.remove(display.id)
                await streamer.stop()
                if streamers[display.id] === streamer { streamers[display.id] = nil }
                continue
            }

            if let streamer = streamers[display.id] {
                guard pendingRestartDisplayIDs.remove(display.id) != nil else { return }
                activeDisplayIDs.remove(display.id)
                await streamer.stop()
                if streamers[display.id] === streamer { streamers[display.id] = nil }
                continue
            }

            // No active instance means the next start already receives the
            // latest settings; no second restart is needed.
            pendingRestartDisplayIDs.remove(display.id)
            guard ndiReady else {
                desiredActiveDisplayIDs.remove(display.id)
                lastError = "NDI runtime not loaded — install the NDI SDK from https://ndi.video/sdk."
                return
            }
            guard await ensureMicrophoneReadyIfNeeded() else {
                desiredActiveDisplayIDs.remove(display.id)
                return
            }
            // Main-actor awaits are reentrant. Stop All or a user toggle may
            // have withdrawn this request while permission UI was pending.
            guard acceptsNewStreams,
                  desiredActiveDisplayIDs.contains(display.id) else { return }

            let streamer = DisplayStreamer(
                display: display,
                ndiSourceName: ndiName(for: display),
                quality: currentStreamQuality
            )
            streamers[display.id] = streamer
            do {
                try await streamer.start()
                guard streamers[display.id] === streamer else { continue }
                if acceptsNewStreams,
                   desiredActiveDisplayIDs.contains(display.id) {
                    activeDisplayIDs.insert(display.id)
                    lastError = nil
                }
            } catch {
                NSLog("[ndi-bar] start failed: \(error)")
                if streamers[display.id] === streamer { streamers[display.id] = nil }
                desiredActiveDisplayIDs.remove(display.id)
                activeDisplayIDs.remove(display.id)
                lastError = error.localizedDescription
                return
            }
        }
    }

    private var currentStreamQuality: StreamQuality {
        StreamQuality(
            resolutionCap: resolutionCap,
            customWidth: customResolutionWidth,
            customHeight: customResolutionHeight,
            fps: fps,
            capturesAudio: captureAudio,
            capturesMicrophone: captureMicrophone,
            microphoneDeviceID: captureMicrophone ? activeMicrophoneCaptureDeviceID : nil,
            showsCursor: showsCursor
        )
    }

    private func scheduleActiveStreamRestart() {
        guard !desiredActiveDisplayIDs.isEmpty else { return }
        restartDebounceTask?.cancel()
        restartDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            for displayID in self.desiredActiveDisplayIDs {
                if let display = self.displays.first(where: { $0.id == displayID })
                    ?? self.streamers[displayID]?.display {
                    if let streamer = self.streamers[displayID],
                       streamer.quality != self.currentStreamQuality
                        || streamer.ndiSourceName != self.ndiName(for: display) {
                        self.pendingRestartDisplayIDs.insert(displayID)
                    }
                    self.ensureLifecycleTask(for: display)
                }
            }
            self.restartDebounceTask = nil
        }
    }

    private func persistCapturePreferences() {
        CapturePreferences(
            fps: fps,
            resolutionCap: resolutionCap,
            customWidth: customResolutionWidth,
            customHeight: customResolutionHeight
        ).persist(to: .standard)
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
