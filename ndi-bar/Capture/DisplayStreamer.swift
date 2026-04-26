// DisplayStreamer.swift
// Owns one SCStream + one NDISender for a single display.
//
// Pipeline:
//   SCStream (BGRA, 60 fps) ─┬─► SCStreamOutput .screen      ─► NDISender.sendVideo
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
struct StreamQuality: Equatable {
    /// Target pixel dimensions. `nil` means "native display resolution".
    var targetWidth: Int?
    var targetHeight: Int?
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
        targetWidth: 1920, targetHeight: 1080, fps: 60,
        capturesAudio: true, capturesMicrophone: false, microphoneDeviceID: nil,
        showsCursor: true
    )

    static let nativeResolution60 = StreamQuality(
        targetWidth: nil, targetHeight: nil, fps: 60,
        capturesAudio: true, capturesMicrophone: false, microphoneDeviceID: nil,
        showsCursor: true
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
    private let audioMixer = AudioFrameMixer()

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
        if quality.capturesMicrophone {
            if #available(macOS 15.0, *) {
                try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            }
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
        audioMixer.reset()
        connectionCount = 0
        NSLog("[ndi-bar] stopped streaming '\(ndiSourceName)'")
    }

    // MARK: Config

    private func makeStreamConfiguration() -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()

        // Dimensions
        let nativeW = display.width
        let nativeH = display.height
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

    private var capturesBothAudioInputs: Bool {
        quality.capturesAudio && quality.capturesMicrophone && Self.supportsMicrophoneCapture
    }

    static var supportsMicrophoneCapture: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
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
