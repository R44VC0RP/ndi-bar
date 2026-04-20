// DisplayEnumerator.swift
// Lists the displays connected to this Mac, enriched with their human name
// (which ScreenCaptureKit does not provide directly).

import Foundation
import AppKit
import ScreenCaptureKit

struct DisplayInfo: Identifiable, Hashable {
    /// ScreenCaptureKit's SCDisplay reference. Equatable by its displayID.
    let scDisplay: SCDisplay
    /// Human-readable name: "Built-in Retina Display", "DELL U2723QE", etc.
    let localizedName: String
    /// Physical pixel resolution: logical size × NSScreen.backingScaleFactor.
    /// On Retina/HiDPI displays the scale is 2.0 (or higher), so this is
    /// larger than the logical point resolution reported by SCDisplay.
    /// CGDisplayPixelsWide/High return the logical size on Apple Silicon, so
    /// we derive physical pixels from the backing scale factor instead.
    let width: Int
    let height: Int
    /// Index in the display list (1-based) — stable for menubar labeling.
    let ordinal: Int

    var id: CGDirectDisplayID { scDisplay.displayID }

    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum DisplayEnumerator {
    /// Queries ScreenCaptureKit for available displays and resolves each one
    /// to a friendly name via NSScreen + CoreGraphics.
    static func currentDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Build lookups keyed by CGDirectDisplayID.
        var nameByID: [CGDirectDisplayID: String] = [:]
        var scaleByID: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            if let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nameByID[did] = screen.localizedName
                scaleByID[did] = screen.backingScaleFactor
            }
        }

        let ordered = content.displays.sorted { $0.displayID < $1.displayID }
        return ordered.enumerated().map { idx, d in
            // CGDisplayPixelsWide/High return the logical resolution on Apple Silicon,
            // not the physical pixel count. Derive physical pixels from backingScaleFactor
            // instead — this works correctly for any display size or scaled resolution.
            let scale = scaleByID[d.displayID] ?? 1.0
            let physW = Int((Double(d.width) * scale).rounded())
            let physH = Int((Double(d.height) * scale).rounded())
            return DisplayInfo(
                scDisplay: d,
                localizedName: nameByID[d.displayID] ?? "Display \(idx + 1)",
                width: physW,
                height: physH,
                ordinal: idx + 1
            )
        }
    }
}
