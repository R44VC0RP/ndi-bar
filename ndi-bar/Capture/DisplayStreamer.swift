// DisplayStreamer.swift
// Owns one SCStream + one NDISender for a single display.
//
// Pipeline:
//   SCStream (BGRA, 60 fps) ─┬─► SCStreamOutput .screen  ─► NDISender.sendVideo
//                            └─► SCStreamOutput .audio   ─► NDISender.sendAudio
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
struct StreamQuality: Equatable {
    /// Target pixel dimensions. `nil` means "native display resolution".
    var targetWidth: Int?
    var targetHeight: Int?
    /// Frames per second.
    var fps: Int
    /// Whether to capture system audio alongside video.
    var capturesAudio: Bool
    /// Whether the hardware cursor is drawn into the frame.
    var showsCursor: Bool

    static let default1080p60 = StreamQuality(
        targetWidth: 1920, targetHeight: 1080, fps: 60,
        capturesAudio: true, showsCursor: true
    )

    static let nativeResolution60 = StreamQuality(
        targetWidth: nil, targetHeight: nil, fps: 60,
        capturesAudio: true, showsCursor: true
    )
}

final class DisplayStreamer: NSObject, SCStreamDelegate, SCStreamOutput {
    let display: DisplayInfo
    let ndiSourceName: String
    private(set) var quality: StreamQuality

    private let captureQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.capture",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "com.ryanvogel.ndi-bar.audio",
        qos: .userInitiated
    )

    private var stream: SCStream?
    private var sender: NDISender?

    /// Exposed so the UI can show "2 viewers" etc.
    private(set) var connectionCount: Int32 = 0

    init(display: DisplayInfo, ndiSourceName: String, quality: StreamQuality = .default1080p60) {
        self.display = display
        self.ndiSourceName = ndiSourceName
        self.quality = quality
    }

    // MARK: Lifecycle

    func start() async throws {
        guard sender == nil else { return }

        guard let newSender = NDISender(name: ndiSourceName) else {
            throw StreamerError.senderCreationFailed
        }
        sender = newSender

        let filter = SCContentFilter(
            display: display.scDisplay,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = makeStreamConfiguration()
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = s

        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if quality.capturesAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        try await s.startCapture()
        NSLog("[ndi-bar] started streaming '\(ndiSourceName)'")
    }

    func stop() async {
        if let s = stream {
            do {
                try await s.stopCapture()
            } catch {
                NSLog("[ndi-bar] stopCapture error: \(error)")
            }
        }
        stream = nil
        sender = nil
        connectionCount = 0
        NSLog("[ndi-bar] stopped streaming '\(ndiSourceName)'")
    }

    // MARK: Config

    private func makeStreamConfiguration() -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()

        // Dimensions
        let nativeW = display.pixelWidth
        let nativeH = display.pixelHeight
        let (outW, outH) = targetSize(forNativeWidth: nativeW, nativeHeight: nativeH)
        cfg.width  = outW
        cfg.height = outH
        cfg.scalesToFit = true

        // BGRA keeps the NDI path simple (SDK does BGRA→YUV internally)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = quality.showsCursor

        // Framerate
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(quality.fps, 1)))
        cfg.queueDepth = 6

        // Audio
        if quality.capturesAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }

        return cfg
    }

    /// Computes output dimensions that keep aspect ratio but cap to the
    /// quality target height if set. Never upscales.
    private func targetSize(forNativeWidth w: Int, nativeHeight h: Int) -> (Int, Int) {
        guard let targetH = quality.targetHeight, targetH > 0, targetH < h else {
            return (w, h)
        }
        let ratio = Double(w) / Double(max(h, 1))
        let outH = targetH
        let outW = Int((Double(outH) * ratio).rounded())
        // Keep width even (some receivers prefer it for YUV).
        return (outW - (outW % 2), outH - (outH % 2))
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        guard let sender = self.sender else { return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first,
                  let statusRaw = info[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else {
                return
            }
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            sender.sendVideo(
                pixelBuffer: pixelBuffer,
                frameRateN: Int32(quality.fps) * 1000,
                frameRateD: 1000
            )
            // Cheap update of connection count (polls NDI, not the display).
            connectionCount = sender.connectionCount

        case .audio:
            sender.sendAudio(sampleBuffer: sampleBuffer)

        case .microphone:
            break

        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        NSLog("[ndi-bar] stream stopped with error: \(error)")
        // Surface via notification so the controller can flip UI state.
        NotificationCenter.default.post(
            name: .displayStreamFailed,
            object: nil,
            userInfo: [
                "displayID": display.id,
                "error": error
            ]
        )
    }
}

extension Notification.Name {
    static let displayStreamFailed = Notification.Name("com.ryanvogel.ndi-bar.displayStreamFailed")
}
