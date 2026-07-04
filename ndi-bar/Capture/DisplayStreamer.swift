// DisplayStreamer.swift
// Owns one SCStream + one NDISender for a single display.
//
// Pipeline:
//   SCStream (BGRA) ─────────┬─► SCStreamOutput .screen      ─► NDISender.sendVideo
//                            ├─► SCStreamOutput .audio       ┐
//                            └─► SCStreamOutput .microphone  ┴─► NDISender.sendAudio
//
// Callbacks fire on a dedicated serial queue so we never touch the main actor
// from the hot path.

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

enum StreamerError: Error, LocalizedError {
    case senderCreationFailed
    var errorDescription: String? {
        switch self {
        case .senderCreationFailed: return "NDI sender creation failed."
        }
    }
}

/// Per-display capture quality.
struct StreamQuality: Equatable, Sendable {
    var resolutionCap: OutputResolutionCap
    var customWidth: Int
    var customHeight: Int
    /// Frames per second.
    var fps: Int
    /// Whether to capture system audio alongside video.
    var capturesAudio: Bool
    /// Whether to capture microphone audio alongside video.
    var capturesMicrophone: Bool
    /// `nil` uses the system default input device.
    var microphoneDeviceID: String?
    /// Whether the hardware cursor is drawn into the frame.
    var showsCursor: Bool

    static let default1080p60 = StreamQuality(
        resolutionCap: .p1080, customWidth: 1920, customHeight: 1080, fps: 60,
        capturesAudio: true, capturesMicrophone: false, microphoneDeviceID: nil,
        showsCursor: true
    )

    static let nativeResolution60 = StreamQuality(
        resolutionCap: .native, customWidth: 1920, customHeight: 1080, fps: 60,
        capturesAudio: true, capturesMicrophone: false, microphoneDeviceID: nil,
        showsCursor: true
    )
}

// Lifecycle mutation is main-actor isolated. Callback-facing state is either
// immutable, lock-protected, or confined to its delivery queue, and teardown
// drains both delivery queues before releasing resources.
final class DisplayStreamer: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private static let streamQueueDepth = 3

    let display: DisplayInfo
    let ndiSourceName: String
    let quality: StreamQuality

    private let captureQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.capture",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.audio",
        qos: .userInitiated
    )

    private var stream: SCStream?
    // Main-actor lifecycle-confined. Publication happens before outputs are
    // registered; clearing happens only after capture stops and both callback
    // queues drain. Callbacks therefore read this without hot-path locking.
    private var sender: NDISender?
    private let audioMixer = AudioFrameMixer()
    private var connectionTimer: DispatchSourceTimer?
    private let connectionCountLock = NSLock()
    private var cachedConnectionCount: Int32 = 0
    private let lifecycleLock = NSLock()
    private var isStopping = false
    private var diagnostics = Diagnostics()

    /// Exposed so the UI can show "2 viewers" etc.
    var connectionCount: Int32 {
        connectionCountLock.withLock { cachedConnectionCount }
    }

    init(display: DisplayInfo, ndiSourceName: String, quality: StreamQuality = .default1080p60) {
        self.display = display
        self.ndiSourceName = ndiSourceName
        self.quality = quality
    }

    // MARK: Lifecycle

    @MainActor
    func start() async throws {
        guard stream == nil else { return }

        lifecycleLock.withLock { isStopping = false }

        guard let newSender = await NDISender.create(name: ndiSourceName) else {
            throw StreamerError.senderCreationFailed
        }
        // No SCK callback can run yet. Registering outputs below publishes the
        // fully initialized sender to the delivery queues.
        sender = newSender

        let filter = SCContentFilter(
            display: display.scDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )

        let configuredCapture = makeStreamConfiguration(filter: filter)
        let s = SCStream(
            filter: filter,
            configuration: configuredCapture.configuration,
            delegate: self
        )
        self.stream = s

        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            if quality.capturesAudio {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if quality.capturesMicrophone {
                if #available(macOS 15.0, *) {
                    try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
                }
            }

            try await s.startCapture()
            startConnectionPolling()
            NSLog(
                "[ndi-bar] started '\(ndiSourceName)' config=\(effectiveConfigurationDescription(nativeSourceSize: configuredCapture.nativeSourceSize, requestedOutputSize: configuredCapture.outputSize))"
            )
        } catch {
            connectionTimer?.cancel()
            connectionTimer = nil
            try? await s.stopCapture()
            await drainCallbackQueues()
            stream = nil
            await destroyPublishedSender()
            throw error
        }
    }

    @MainActor
    func stop() async {
        lifecycleLock.withLock { isStopping = true }
        connectionTimer?.cancel()
        connectionTimer = nil
        if let s = stream {
            do {
                try await s.stopCapture()
            } catch {
                NSLog("[ndi-bar] stopCapture error: \(error)")
            }
        }
        // stopCapture prevents new samples; these barriers wait for already
        // enqueued callbacks before destroying the sender they reference.
        await drainCallbackQueues()
        stream = nil
        audioMixer.reset()
        setCachedConnectionCount(0)
        await destroyPublishedSender()
        NSLog("[ndi-bar] stopped '\(ndiSourceName)' \(diagnostics.stopSummary)")
    }

    // MARK: Config

    private func makeStreamConfiguration(filter: SCContentFilter) -> ConfiguredCapture {
        let cfg = SCStreamConfiguration()
        let frameRate = CaptureFrameRate(quality.fps)

        // On macOS 14+, SCK's authoritative native pixels are the filter's
        // point-based content rect multiplied by its point-to-pixel scale.
        let native = CaptureGeometry.nativeResolution(
            contentWidth: Double(filter.contentRect.width),
            contentHeight: Double(filter.contentRect.height),
            pointPixelScale: Double(filter.pointPixelScale),
            fallback: PixelSize(width: display.width, height: display.height)
        )
        if native.usedFallback {
            NSLog("[ndi-bar] invalid contentRect/pointPixelScale for '\(ndiSourceName)'; conservatively using SCDisplay \(native.size)")
        }
        let maximum = quality.resolutionCap.maximumSize(
            customWidth: quality.customWidth,
            customHeight: quality.customHeight
        )
        let output = CaptureGeometry.outputSize(source: native.size, maximum: maximum)
        cfg.width = output.width
        cfg.height = output.height
        cfg.scalesToFit = true

        // BGRA keeps the NDI path simple (SDK does BGRA→YUV internally)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = quality.showsCursor

        // Framerate
        cfg.minimumFrameInterval = CMTime(
            value: 1,
            timescale: frameRate.minimumFrameTimescale
        )
        // SCK documents 3 as both the default and minimum (maximum 8). Pin it
        // explicitly to bound IOSurface memory and favor frame freshness.
        cfg.queueDepth = Self.streamQueueDepth

        // Audio
        if quality.capturesAudio || quality.capturesMicrophone {
            cfg.sampleRate = 48000
            cfg.channelCount = 2
        }
        if quality.capturesAudio {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
        }
        if quality.capturesMicrophone, Self.supportsMicrophoneCapture {
            if #available(macOS 15.0, *) {
                cfg.captureMicrophone = true
                cfg.microphoneCaptureDeviceID = quality.microphoneDeviceID
            }
        }

        return ConfiguredCapture(
            configuration: cfg,
            nativeSourceSize: native.size,
            outputSize: output
        )
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .screen { diagnostics.frameCallbacks += 1 }
        guard sampleBuffer.isValid else {
            if type == .screen { diagnostics.invalidBuffers += 1 }
            return
        }
        guard let sender = self.sender else { return }

        switch type {
        case .screen:
            let frameRate = CaptureFrameRate(quality.fps)
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first,
                  let statusRaw = info[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else {
                diagnostics.nonCompleteFrames += 1
                return
            }
            guard let pixelBuffer = sampleBuffer.imageBuffer else {
                diagnostics.missingImages += 1
                return
            }
            if diagnostics.firstDeliveredSize == nil {
                let delivered = PixelSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
                diagnostics.firstDeliveredSize = delivered
                NSLog("[ndi-bar] first video '\(ndiSourceName)' delivered=\(delivered)")
            }
            if sender.sendVideo(
                pixelBuffer: pixelBuffer,
                frameRateN: frameRate.ndiNumerator,
                frameRateD: frameRate.ndiDenominator
            ) {
                diagnostics.videoSubmissions += 1
            }

        case .audio:
            if capturesBothAudioInputs {
                audioMixer.appendSystemAudio(sampleBuffer, sender: sender)
            } else {
                sender.sendAudio(sampleBuffer: sampleBuffer)
            }

        case .microphone:
            if capturesBothAudioInputs {
                audioMixer.appendMicrophoneAudio(sampleBuffer, sender: sender)
            } else {
                sender.sendAudio(sampleBuffer: sampleBuffer)
            }

        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stopping = lifecycleLock.withLock { isStopping }
        guard !stopping else { return }
        NSLog("[ndi-bar] stream stopped with error: \(error)")
        // Surface via notification so the controller can flip UI state.
        NotificationCenter.default.post(
            name: .displayStreamFailed,
            object: self,
            userInfo: [
                "displayID": display.id,
                "error": error
            ]
        )
    }

    private var capturesBothAudioInputs: Bool {
        quality.capturesAudio && quality.capturesMicrophone && Self.supportsMicrophoneCapture
    }

    static var supportsMicrophoneCapture: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private func effectiveConfigurationDescription(
        nativeSourceSize: PixelSize,
        requestedOutputSize: PixelSize
    ) -> String {
        let cap = quality.resolutionCap == .custom
            ? "custom \(quality.customWidth)×\(quality.customHeight) max"
            : quality.resolutionCap.displayName
        return "fps=\(quality.fps) resolution=\(cap) source=\(nativeSourceSize) requested=\(requestedOutputSize) cursor=\(quality.showsCursor) systemAudio=\(quality.capturesAudio) microphone=\(quality.capturesMicrophone) queueDepth=\(Self.streamQueueDepth)"
    }

    private func startConnectionPolling() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
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

    @MainActor
    private func drainCallbackQueues() async {
        await drain(captureQueue)
        await drain(audioQueue)
    }

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

private struct ConfiguredCapture {
    let configuration: SCStreamConfiguration
    let nativeSourceSize: PixelSize
    let outputSize: PixelSize
}

private struct Diagnostics {
    var frameCallbacks: UInt64 = 0
    var invalidBuffers: UInt64 = 0
    var nonCompleteFrames: UInt64 = 0
    var missingImages: UInt64 = 0
    var videoSubmissions: UInt64 = 0
    var firstDeliveredSize: PixelSize?

    var stopSummary: String {
        "frames=\(frameCallbacks) submitted=\(videoSubmissions) statusDrops=\(nonCompleteFrames) invalid=\(invalidBuffers) missingImage=\(missingImages) firstDelivered=\(firstDeliveredSize?.description ?? "none")"
    }
}

private final class AudioFrameMixer {
    private var systemQueue: [NDIAudioFrame] = []
    private var microphoneQueue: [NDIAudioFrame] = []

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer, sender: NDISender) {
        guard let frame = NDIAudioFrame(sampleBuffer: sampleBuffer) else { return }
        systemQueue.append(frame)
        drain(sender: sender)
    }

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer, sender: NDISender) {
        guard let frame = NDIAudioFrame(sampleBuffer: sampleBuffer) else { return }
        microphoneQueue.append(frame)
        drain(sender: sender)
    }

    func reset() {
        systemQueue.removeAll(keepingCapacity: true)
        microphoneQueue.removeAll(keepingCapacity: true)
    }

    private func drain(sender: NDISender) {
        while !systemQueue.isEmpty && !microphoneQueue.isEmpty {
            let system = systemQueue.removeFirst()
            let microphone = microphoneQueue.removeFirst()

            if let mixed = system.mixed(with: microphone) {
                sender.sendAudio(mixed)
            } else {
                sender.sendAudio(system)
                sender.sendAudio(microphone)
            }
        }

        // Keep one unmatched frame as a short alignment buffer. If the other
        // input is absent or delayed, older frames are still sent live.
        while systemQueue.count > 1 {
            sender.sendAudio(systemQueue.removeFirst())
        }
        while microphoneQueue.count > 1 {
            sender.sendAudio(microphoneQueue.removeFirst())
        }
    }
}

extension Notification.Name {
    static let displayStreamFailed = Notification.Name("com.ryanvogel.ndi-bar.displayStreamFailed")
}
