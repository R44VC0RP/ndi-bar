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
        static let selectedCameraDeviceID = "selectedCameraDeviceID"
        static let cameraMicrophoneDeviceID = "cameraMicrophoneDeviceID"
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
    @Published var selectedCameraDeviceID: String {
        didSet {
            if selectedCameraDeviceID == CameraDevice.systemDefaultID {
                UserDefaults.standard.removeObject(forKey: Keys.selectedCameraDeviceID)
            } else {
                UserDefaults.standard.set(selectedCameraDeviceID, forKey: Keys.selectedCameraDeviceID)
            }
            scheduleActiveStreamRestart()
        }
    }
    @Published var cameraMicrophoneDeviceID: String {
        didSet {
            if cameraMicrophoneDeviceID == MicrophoneDevice.systemDefaultID {
                UserDefaults.standard.removeObject(forKey: Keys.cameraMicrophoneDeviceID)
            } else {
                UserDefaults.standard.set(cameraMicrophoneDeviceID, forKey: Keys.cameraMicrophoneDeviceID)
            }
            scheduleActiveStreamRestart()
        }
    }

    // MARK: Observable state

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var microphoneDevices: [MicrophoneDevice] = []
    @Published private(set) var cameraDevices: [CameraDevice] = []
    @Published private(set) var isCameraStreaming: Bool = false
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
    @Published private(set) var cameraPermissionGranted: Bool = {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }()

    var microphoneCaptureSupported: Bool {
        DisplayStreamer.supportsMicrophoneCapture
    }

    var selectedMicrophoneDeviceUnavailable: Bool {
        selectedMicrophoneDeviceID != MicrophoneDevice.systemDefaultID &&
            !microphoneDevices.contains { $0.id == selectedMicrophoneDeviceID }
    }

    var selectedCameraDeviceUnavailable: Bool {
        selectedCameraDeviceID != CameraDevice.systemDefaultID &&
            !cameraDevices.contains { $0.id == selectedCameraDeviceID }
    }

    var cameraMicrophoneDeviceUnavailable: Bool {
        cameraMicrophoneDeviceID != MicrophoneDevice.systemDefaultID &&
            !microphoneDevices.contains { $0.id == cameraMicrophoneDeviceID }
    }

    /// uniqueID of the camera the running camera source actually captures
    /// (System Default is resolved to a concrete device at start).
    var activeCameraDeviceID: String? {
        cameraStreamer?.settings.cameraDeviceID
    }

    /// Number of NDI receivers connected to the camera source.
    /// Returns -1 if the camera source isn't currently streaming.
    var cameraViewerCount: Int {
        guard let streamer = cameraStreamer else { return -1 }
        return Int(streamer.connectionCount)
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
    private var cameraStreamer: CameraStreamer?
    private var desiredCameraActive = false
    private var pendingCameraRestart = false
    private var cameraLifecycleTask: Task<Void, Never>?
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
        self.selectedCameraDeviceID = d.string(forKey: Keys.selectedCameraDeviceID) ?? CameraDevice.systemDefaultID
        self.cameraMicrophoneDeviceID = d.string(forKey: Keys.cameraMicrophoneDeviceID) ?? MicrophoneDevice.systemDefaultID

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

        NotificationCenter.default.addObserver(
            forName: .cameraStreamFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let failedStreamer = note.object as? CameraStreamer
            let errorDescription = (note.userInfo?["error"] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                guard let self,
                      let failedStreamer,
                      self.cameraStreamer === failedStreamer else { return }
                self.desiredCameraActive = false
                self.isCameraStreaming = false
                if let errorDescription { self.lastError = errorDescription }
                self.ensureCameraLifecycleTask()
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
        refreshCameras()
        await refreshDisplays()
    }

    /// Re-query TCC for the current cdhash. Call after the permissions menu
    /// item is invoked or when the app becomes active, since grant state
    /// normally doesn't change mid-session.
    func refreshPermissionState() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphonePermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        cameraPermissionGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func refreshMicrophones() {
        // Microphones are useful even when SCK's per-display mic mixing is
        // unsupported (macOS 14): the camera source captures them directly
        // via AVFoundation.
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

    func refreshCameras() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        cameraDevices = session.devices.map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    func selectCameraDevice(_ id: String) {
        selectedCameraDeviceID = id
        refreshCameras()
    }

    func selectCameraMicrophoneDevice(_ id: String) {
        cameraMicrophoneDeviceID = id
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
        desiredCameraActive = false
        pendingCameraRestart = false

        let affectedDisplays = Dictionary(
            uniqueKeysWithValues: streamers.values.map { ($0.display.id, $0.display) }
        )
        for display in affectedDisplays.values {
            ensureLifecycleTask(for: display)
        }
        if cameraStreamer != nil {
            ensureCameraLifecycleTask()
        }

        while let task = lifecycleTasks.values.first {
            await task.value
        }
        while let task = cameraLifecycleTask {
            await task.value
        }
        // At this point no lifecycle task is transitional, so streamer
        // ownership is the authoritative final running-state snapshot.
        activeDisplayIDs = Set(streamers.keys)
        isCameraStreaming = cameraStreamer != nil
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

    // MARK: Camera source start / stop

    /// Starts, stops, or switches the camera + microphone NDI source.
    /// Clicking the active camera stops the source; clicking another camera
    /// selects it (an active source restarts onto it after the debounce).
    func toggleCamera(_ device: CameraDevice) {
        if desiredCameraActive,
           activeCameraDeviceID == device.id || selectedCameraDeviceID == device.id {
            desiredCameraActive = false
            ensureCameraLifecycleTask()
            return
        }
        guard acceptsNewStreams else { return }
        if selectedCameraDeviceID != device.id {
            selectedCameraDeviceID = device.id
        }
        desiredCameraActive = true
        ensureCameraLifecycleTask()
    }

    func stopCameraSource() async {
        desiredCameraActive = false
        ensureCameraLifecycleTask()
        await cameraLifecycleTask?.value
    }

    private func ensureCameraLifecycleTask() {
        guard cameraLifecycleTask == nil else { return }
        cameraLifecycleTask = Task { @MainActor [weak self] in
            await self?.reconcileCameraLifecycle()
            self?.cameraLifecycleTask = nil
        }
    }

    private func reconcileCameraLifecycle() async {
        while true {
            if !desiredCameraActive {
                pendingCameraRestart = false
                guard let streamer = cameraStreamer else { return }
                isCameraStreaming = false
                await streamer.stop()
                if cameraStreamer === streamer { cameraStreamer = nil }
                continue
            }

            if let streamer = cameraStreamer {
                guard pendingCameraRestart else { return }
                pendingCameraRestart = false
                isCameraStreaming = false
                await streamer.stop()
                if cameraStreamer === streamer { cameraStreamer = nil }
                continue
            }

            // No active instance means the next start already receives the
            // latest settings; no second restart is needed.
            pendingCameraRestart = false
            guard ndiReady else {
                desiredCameraActive = false
                lastError = "NDI runtime not loaded — install the NDI SDK from https://ndi.video/sdk."
                return
            }
            guard await ensureCameraSourceReady() else {
                desiredCameraActive = false
                return
            }
            // Main-actor awaits are reentrant. Stop All or a user toggle may
            // have withdrawn this request while permission UI was pending.
            guard acceptsNewStreams, desiredCameraActive else { return }
            guard let settings = currentCameraStreamSettings else {
                desiredCameraActive = false
                lastError = "No camera available. Connect a camera and try again."
                return
            }

            let streamer = CameraStreamer(
                settings: settings,
                ndiSourceName: cameraNDIName(for: settings)
            )
            cameraStreamer = streamer
            do {
                try await streamer.start()
                guard cameraStreamer === streamer else { continue }
                if acceptsNewStreams, desiredCameraActive {
                    isCameraStreaming = true
                    lastError = nil
                }
            } catch {
                NSLog("[ndi-bar] camera start failed: \(error)")
                if cameraStreamer === streamer { cameraStreamer = nil }
                desiredCameraActive = false
                isCameraStreaming = false
                lastError = error.localizedDescription
                return
            }
        }
    }

    private var currentCameraStreamSettings: CameraStreamSettings? {
        let cameraID: String
        if selectedCameraDeviceID == CameraDevice.systemDefaultID {
            guard let device = AVCaptureDevice.default(for: .video) else { return nil }
            cameraID = device.uniqueID
        } else if cameraDevices.contains(where: { $0.id == selectedCameraDeviceID }) {
            cameraID = selectedCameraDeviceID
        } else {
            return nil
        }

        let microphoneID: String?
        if cameraMicrophoneDeviceID != MicrophoneDevice.systemDefaultID,
           microphoneDevices.contains(where: { $0.id == cameraMicrophoneDeviceID }) {
            microphoneID = cameraMicrophoneDeviceID
        } else {
            microphoneID = nil
        }

        return CameraStreamSettings(cameraDeviceID: cameraID, microphoneDeviceID: microphoneID)
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
        guard !desiredActiveDisplayIDs.isEmpty || desiredCameraActive else { return }
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
            if self.desiredCameraActive, let streamer = self.cameraStreamer {
                if let settings = self.currentCameraStreamSettings,
                   streamer.settings != settings
                    || streamer.ndiSourceName != self.cameraNDIName(for: settings) {
                    self.pendingCameraRestart = true
                }
                self.ensureCameraLifecycleTask()
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

    /// Ensures camera + microphone permissions and device availability before
    /// the camera source starts. Mirrors ensureMicrophoneReadyIfNeeded, but the
    /// camera source always wants its microphone.
    private func ensureCameraSourceReady() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionGranted = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestVideoAccess()
            cameraPermissionGranted = granted
            if !granted {
                lastError = "Camera permission was not granted."
                return false
            }
        case .denied, .restricted:
            cameraPermissionGranted = false
            lastError = "Camera permission is denied. Enable it in System Settings → Privacy & Security → Camera."
            return false
        @unknown default:
            cameraPermissionGranted = false
            lastError = "Camera permission state is unknown."
            return false
        }

        refreshCameras()
        guard ensureSelectedCameraAvailable() else { return false }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionGranted = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAudioAccess()
            microphonePermissionGranted = granted
            if !granted {
                lastError = "Microphone permission was not granted."
                return false
            }
        case .denied, .restricted:
            microphonePermissionGranted = false
            lastError = "Microphone permission is denied. Enable it in System Settings → Privacy & Security → Microphone."
            return false
        @unknown default:
            microphonePermissionGranted = false
            lastError = "Microphone permission state is unknown."
            return false
        }

        refreshMicrophones()
        return ensureCameraMicrophoneAvailable()
    }

    private func ensureSelectedCameraAvailable() -> Bool {
        if selectedCameraDeviceID == CameraDevice.systemDefaultID {
            guard AVCaptureDevice.default(for: .video) != nil else {
                lastError = "No camera detected. Connect a camera and try again."
                return false
            }
            return true
        }
        if cameraDevices.contains(where: { $0.id == selectedCameraDeviceID }) {
            return true
        }
        lastError = "Selected camera is not available. Choose another camera or use System Default."
        return false
    }

    private func ensureCameraMicrophoneAvailable() -> Bool {
        guard cameraMicrophoneDeviceID != MicrophoneDevice.systemDefaultID else { return true }
        if microphoneDevices.contains(where: { $0.id == cameraMicrophoneDeviceID }) {
            return true
        }
        lastError = "Selected camera microphone is not available. Choose another microphone or use System Default."
        return false
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
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

    private func cameraNDIName(for settings: CameraStreamSettings) -> String {
        let cameraName = cameraDevices.first(where: { $0.id == settings.cameraDeviceID })?.name
            ?? AVCaptureDevice(uniqueID: settings.cameraDeviceID)?.localizedName
            ?? "Camera"
        return "\(sourcePrefix) – Camera (\(cameraName))"
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

    static func requestVideoAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
