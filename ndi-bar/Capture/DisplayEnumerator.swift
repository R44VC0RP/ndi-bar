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
    /// Logical resolution, in points. This matches what the user sees in
    /// System Settings → Displays → "Use as …" and is what we configure
    /// the SCStream output with: `SCStreamConfiguration.width/height` takes
    /// pixels, but giving it the logical point count means macOS does the
    /// HiDPI downsample for us and we ship a reasonable-size NDI frame
    /// instead of the 2× framebuffer.
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

        // Build a lookup of NSScreen-based names keyed by CGDirectDisplayID.
        var nameByID: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nameByID[did] = screen.localizedName
            }
        }

        let ordered = content.displays.sorted { $0.displayID < $1.displayID }
        return ordered.enumerated().map { idx, d in
            return DisplayInfo(
                scDisplay: d,
                localizedName: nameByID[d.displayID] ?? "Display \(idx + 1)",
                width: d.width,
                height: d.height,
                ordinal: idx + 1
            )
        }
    }
}
