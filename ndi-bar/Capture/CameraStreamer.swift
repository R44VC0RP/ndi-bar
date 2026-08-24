// CameraStreamer.swift
// Owns one AVCaptureSession + one NDISender for the camera + microphone
// NDI source (independent of the per-display screen streams).
//
// Pipeline:
//   AVCaptureSession ──┬─► AVCaptureVideoDataOutput (BGRA) ─► NDISender.sendVideo
//                      └─► AVCaptureAudioDataOutput        ─► NDISender.sendAudio
//
// Callbacks fire on dedicated serial queues so we never touch the main actor
// on the hot path. Lifecycle mutation is main-actor isolated; the blocking
// AVCaptureSession start/stop calls run on a dedicated session queue.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

struct CameraDevice: Identifiable, Equatable {
    static let systemDefaultID = "__ndi_bar_system_default_camera__"

    let id: String
    let name: String
}

/// Capture settings for the camera + microphone source.
struct CameraStreamSettings: Equatable, Sendable {
    /// `AVCaptureDevice.uniqueID` of the camera to capture.
    var cameraDeviceID: String
    /// `nil` uses the system default audio input device.
    var microphoneDeviceID: String?
}

enum CameraStreamerError: Error, LocalizedError {
    case senderCreationFailed
    case cameraUnavailable
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .senderCreationFailed:
            return "NDI sender creation failed."
        case .cameraUnavailable:
            return "The selected camera is not available."
        case .configurationFailed(let reason):
            return "Camera capture setup failed: \(reason)"
        }
    }
}

// Lifecycle mutation is main-actor isolated. Callback-facing state is either
// immutable or published before delivery starts, and teardown drains both
// delivery queues before releasing resources (same discipline as
// DisplayStreamer).
final class CameraStreamer: NSObject, @unchecked Sendable {

    let settings: CameraStreamSettings
    let ndiSourceName: String

    private let sessionQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.camera-session",
        qos: .userInitiated
    )
    private let videoQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.camera-video",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.camera-audio",
        qos: .userInitiated
    )

    // Main-actor lifecycle-confined. Publication happens before the session
    // starts delivering; clearing happens only after capture stops and both
    // callback queues drain. Callbacks therefore read this without hot-path
    // locking.
    private var sender: NDISender?
    private var session: AVCaptureSession?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var connectionTimer: DispatchSourceTimer?
    private let connectionCountLock = NSLock()
    private var cachedConnectionCount: Int32 = 0
    private let lifecycleLock = NSLock()
    private var isStopping = false

    // Written on sessionQueue during configuration, strictly before
    // startRunning; read on videoQueue only after delivery begins.
    private var frameRateN: Int32 = 30
    private var frameRateD: Int32 = 1

    // Written on their delivery queues; read at stop after the queues drain.
    private var videoSubmissions: UInt64 = 0
    private var audioSubmissions: UInt64 = 0
    private var firstDeliveredSize: PixelSize?

    /// Exposed so the UI can show "2 viewers" etc.
    var connectionCount: Int32 {
        connectionCountLock.withLock { cachedConnectionCount }
    }

    init(settings: CameraStreamSettings, ndiSourceName: String) {
        self.settings = settings
        self.ndiSourceName = ndiSourceName
    }

    // MARK: Lifecycle

    @MainActor
    func start() async throws {
        guard session == nil else { return }

        lifecycleLock.withLock { isStopping = false }

        guard let newSender = await NDISender.create(name: ndiSourceName) else {
            throw CameraStreamerError.senderCreationFailed
        }
        // No capture callback can run yet. Starting the session below
        // publishes the fully initialized sender to the delivery queues.
        sender = newSender

        do {
            let builtSession = try await buildSession()
            session = builtSession
            observeRuntimeErrors(of: builtSession)
            await startRunning(builtSession)
            startConnectionPolling()
            NSLog("[ndi-bar] started '\(ndiSourceName)' camera=\(settings.cameraDeviceID) microphone=\(settings.microphoneDeviceID ?? "system default") frameRate=\(frameRateN)/\(frameRateD)")
        } catch {
            await teardownSession()
            await destroyPublishedSender()
            throw error
        }
    }

    @MainActor
    func stop() async {
        lifecycleLock.withLock { isStopping = true }
        connectionTimer?.cancel()
        connectionTimer = nil
        await teardownSession()
        setCachedConnectionCount(0)
        await destroyPublishedSender()
        NSLog("[ndi-bar] stopped '\(ndiSourceName)' video=\(videoSubmissions) audio=\(audioSubmissions) firstDelivered=\(firstDeliveredSize?.description ?? "none")")
    }

    // MARK: Session construction

    /// Builds and configures the AVCaptureSession off-main. Also derives the
    /// NDI frame-rate metadata from the camera's active format, strictly
    /// before any delivery callback can run.
    private func buildSession() async throws -> AVCaptureSession {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    continuation.resume(returning: try makeConfiguredSession())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on sessionQueue.
    private func makeConfiguredSession() throws -> AVCaptureSession {
        guard let camera = AVCaptureDevice(uniqueID: settings.cameraDeviceID) else {
            throw CameraStreamerError.cameraUnavailable
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Camera input
        let cameraInput: AVCaptureDeviceInput
        do {
            cameraInput = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw CameraStreamerError.configurationFailed("camera input: \(error.localizedDescription)")
        }
        guard session.canAddInput(cameraInput) else {
            throw CameraStreamerError.configurationFailed("camera input was rejected by the session")
        }
        session.addInput(cameraInput)

        // Microphone input — best effort. A missing microphone degrades to a
        // video-only source rather than failing the whole stream.
        let microphone = settings.microphoneDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .audio)
        if let microphone {
            do {
                let micInput = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(micInput) {
                    session.addInput(micInput)
                } else {
                    NSLog("[ndi-bar] camera source: microphone input rejected; continuing video-only")
                }
            } catch {
                NSLog("[ndi-bar] camera source: microphone input failed (\(error.localizedDescription)); continuing video-only")
            }
        } else {
            NSLog("[ndi-bar] camera source: no microphone available; continuing video-only")
        }

        // Video output — BGRA keeps the NDI path identical to screen capture.
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CameraStreamerError.configurationFailed("video output was rejected by the session")
        }
        session.addOutput(videoOutput)

        // Audio output
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        } else {
            NSLog("[ndi-bar] camera source: audio output rejected; continuing video-only")
        }

        session.commitConfiguration()

        // NDI frame-rate metadata from the camera's active format. Delivery
        // has not started, so this publish is safe.
        let duration = camera.activeVideoMinFrameDuration
        if duration.isNumeric, duration.value > 0, duration.timescale > 0 {
            frameRateN = duration.timescale
            frameRateD = Int32(clamping: duration.value)
        }

        return session
    }

    private func startRunning(_ session: AVCaptureSession) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    @MainActor
    private func teardownSession() async {
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }
        if let session {
            await withCheckedContinuation { continuation in
                sessionQueue.async {
                    if session.isRunning { session.stopRunning() }
                    continuation.resume()
                }
            }
        }
        // stopRunning prevents new samples; these barriers wait for already
        // enqueued callbacks before the sender they reference is destroyed.
        await drain(videoQueue)
        await drain(audioQueue)
        session = nil
    }

    private func observeRuntimeErrors(of session: AVCaptureSession) {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let stopping = self.lifecycleLock.withLock { self.isStopping }
            guard !stopping else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            NSLog("[ndi-bar] camera session runtime error: \(error?.localizedDescription ?? "unknown")")
            var userInfo: [AnyHashable: Any] = [:]
            if let error { userInfo["error"] = error }
            NotificationCenter.default.post(
                name: .cameraStreamFailed,
                object: self,
                userInfo: userInfo
            )
        }
    }

    // MARK: Connection polling

    private func startConnectionPolling() {
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let sender = self.sender else { return }
            self.setCachedConnectionCount(sender.connectionCount)
        }
        connectionTimer = timer
        timer.resume()
    }

    private func setCachedConnectionCount(_ count: Int32) {
        connectionCountLock.withLock { cachedConnectionCount = count }
    }

    // MARK: Teardown helpers

    @MainActor
    private func destroyPublishedSender() async {
        guard let sender else { return }
        // Both callback queues have already drained, so clearing cannot race a
        // read and this strong local keeps the sender alive until destruction.
        self.sender = nil
        await sender.destroy()
    }

    @MainActor
    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

// MARK: - Sample delivery

// Both delegate protocols declare the same callback; one implementation
// satisfies video (videoQueue) and audio (audioQueue) delivery.
extension CameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        guard let sender = self.sender else { return }

        if output is AVCaptureVideoDataOutput {
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            if firstDeliveredSize == nil {
                let delivered = PixelSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                firstDeliveredSize = delivered
                NSLog("[ndi-bar] first video '\(ndiSourceName)' delivered=\(delivered)")
            }
            if sender.sendVideo(
                pixelBuffer: pixelBuffer,
                frameRateN: frameRateN,
                frameRateD: frameRateD
            ) {
                videoSubmissions += 1
            }
        } else {
            sender.sendAudio(sampleBuffer: sampleBuffer)
            audioSubmissions += 1
        }
    }
}

extension Notification.Name {
    static let cameraStreamFailed = Notification.Name("com.ryanvogel.ndi-bar.cameraStreamFailed")
}
