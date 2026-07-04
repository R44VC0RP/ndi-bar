// CaptureConfiguration.swift
// Pure capture preference validation and aspect-preserving pixel sizing.

import Foundation

struct PixelSize: Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)×\(height)" }
}

enum OutputResolutionCap: String, CaseIterable, Identifiable, Sendable {
    case native
    case p1440
    case p1080
    case p720
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .native: return "Native"
        case .p1440:  return "1440p"
        case .p1080:  return "1080p"
        case .p720:   return "720p"
        case .custom: return "Custom"
        }
    }

    func maximumSize(customWidth: Int, customHeight: Int) -> PixelSize? {
        switch self {
        case .native: return nil
        case .p1440: return PixelSize(width: 2560, height: 1440)
        case .p1080: return PixelSize(width: 1920, height: 1080)
        case .p720: return PixelSize(width: 1280, height: 720)
        case .custom:
            return PixelSize(
                width: CapturePreferences.normalizedDimension(customWidth),
                height: CapturePreferences.normalizedDimension(customHeight)
            )
        }
    }
}

struct CapturePreferences: Equatable {
    static let validFPS = 1...120
    static let validDimension = 2...16_384

    static let defaultFPS = 60
    static let defaultResolutionCap: OutputResolutionCap = .p1080
    static let defaultCustomWidth = 1920
    static let defaultCustomHeight = 1080

    private enum Keys {
        static let fps = "fps"
        static let resolutionCap = "resolutionCap"
        static let legacy1080pBool = "limitTo1080p"
        static let customWidth = "customResolutionWidth"
        static let customHeight = "customResolutionHeight"
    }

    let fps: Int
    let resolutionCap: OutputResolutionCap
    let customWidth: Int
    let customHeight: Int

    init(fps: Int, resolutionCap: OutputResolutionCap, customWidth: Int, customHeight: Int) {
        self.fps = Self.normalizedFPS(fps)
        self.resolutionCap = resolutionCap
        self.customWidth = Self.normalizedDimension(customWidth)
        self.customHeight = Self.normalizedDimension(customHeight)
    }

    init(defaults: UserDefaults) {
        let storedFPS = defaults.object(forKey: Keys.fps).map { _ in
            defaults.integer(forKey: Keys.fps)
        }
        // Older releases treated a missing or zero value as the 60 fps
        // default. Preserve that migration while clamping every other value.
        let persistedFPS: Int
        if let storedFPS, storedFPS != 0 {
            persistedFPS = storedFPS
        } else {
            persistedFPS = Self.defaultFPS
        }

        let cap: OutputResolutionCap
        if let raw = defaults.string(forKey: Keys.resolutionCap),
           let storedCap = OutputResolutionCap(rawValue: raw) {
            cap = storedCap
        } else if let legacy = defaults.object(forKey: Keys.legacy1080pBool) as? Bool {
            cap = legacy ? .p1080 : .native
        } else {
            cap = Self.defaultResolutionCap
        }

        let persistedWidth = defaults.object(forKey: Keys.customWidth) == nil
            ? Self.defaultCustomWidth
            : defaults.integer(forKey: Keys.customWidth)
        let persistedHeight = defaults.object(forKey: Keys.customHeight) == nil
            ? Self.defaultCustomHeight
            : defaults.integer(forKey: Keys.customHeight)

        self.init(
            fps: persistedFPS,
            resolutionCap: cap,
            customWidth: persistedWidth,
            customHeight: persistedHeight
        )

        // Canonicalize invalid/legacy values once so subsequent launches see
        // the same deterministic settings.
        persist(to: defaults)
        defaults.removeObject(forKey: Keys.legacy1080pBool)
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(fps, forKey: Keys.fps)
        defaults.set(resolutionCap.rawValue, forKey: Keys.resolutionCap)
        defaults.set(customWidth, forKey: Keys.customWidth)
        defaults.set(customHeight, forKey: Keys.customHeight)
    }

    static func normalizedFPS(_ fps: Int) -> Int {
        min(max(fps, validFPS.lowerBound), validFPS.upperBound)
    }

    static func normalizedDimension(_ value: Int) -> Int {
        min(max(value, validDimension.lowerBound), validDimension.upperBound)
    }
}

struct CaptureFrameRate: Equatable {
    let framesPerSecond: Int

    init(_ requestedFPS: Int) {
        framesPerSecond = CapturePreferences.normalizedFPS(requestedFPS)
    }

    /// SCK receives CMTime(value: 1, timescale: minimumFrameTimescale).
    var minimumFrameTimescale: Int32 { Int32(framesPerSecond) }
    var ndiNumerator: Int32 { Int32(framesPerSecond) }
    var ndiDenominator: Int32 { 1 }
}

enum CaptureGeometry {
    struct NativeResolution: Equatable {
        let size: PixelSize
        let usedFallback: Bool
    }

    /// ScreenCaptureKit defines a filter's native pixel dimensions as its
    /// point-based contentRect multiplied by pointPixelScale on macOS 14+.
    static func nativeResolution(
        contentWidth: Double,
        contentHeight: Double,
        pointPixelScale: Double,
        fallback: PixelSize
    ) -> NativeResolution {
        let width = (contentWidth * pointPixelScale).rounded()
        let height = (contentHeight * pointPixelScale).rounded()
        if width.isFinite, height.isFinite,
           let exactWidth = Int(exactly: width),
           let exactHeight = Int(exactly: height),
           exactWidth >= 1, exactHeight >= 1 {
            return NativeResolution(
                size: PixelSize(
                    width: exactWidth,
                    height: exactHeight
                ),
                usedFallback: false
            )
        }

        return NativeResolution(
            size: PixelSize(
                width: max(fallback.width, 1),
                height: max(fallback.height, 1)
            ),
            usedFallback: true
        )
    }

    /// Uniformly fits the source inside a bounding cap, never intentionally
    /// upscales, and rounds down to positive even dimensions for NDI.
    static func outputSize(source: PixelSize, maximum: PixelSize?) -> PixelSize {
        let sourceWidth = max(source.width, 1)
        let sourceHeight = max(source.height, 1)

        var scale = 1.0
        if let maximum {
            let maxWidth = max(maximum.width, 2)
            let maxHeight = max(maximum.height, 2)
            scale = min(
                1.0,
                Double(maxWidth) / Double(sourceWidth),
                Double(maxHeight) / Double(sourceHeight)
            )
        }

        return PixelSize(
            width: positiveEvenFloor(
                Double(sourceWidth) * scale,
                noGreaterThan: sourceWidth
            ),
            height: positiveEvenFloor(
                Double(sourceHeight) * scale,
                noGreaterThan: sourceHeight
            )
        )
    }

    private static func positiveEvenFloor(_ value: Double, noGreaterThan upperBound: Int) -> Int {
        let rounded = value.rounded(.down)
        // `Double(Int.max)` rounds up to a value Int cannot represent. Exact
        // conversion avoids that trap; the known-safe integer source bound is
        // the conservative fallback at the floating-point boundary.
        let floored = Int(exactly: rounded).map { min($0, upperBound) }
            ?? upperBound
        let even = floored - (floored % 2)
        // Real displays are at least 2×2. This defensive minimum keeps an
        // invalid synthetic/fallback input acceptable to SCK and NDI.
        return max(even, 2)
    }
}
