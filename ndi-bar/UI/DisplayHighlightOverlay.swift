// DisplayHighlightOverlay.swift
// Click-through, top-most, one-per-display red border that shows up while
// the user is hovering a display row in the menubar menu. Lets the user
// visually match "Monitor 2" in the menu to the physical screen.
//
// Implemented as a transparent borderless NSWindow covering the target
// display's full frame; its content view draws just a thick red stroke.

import Foundation
import AppKit

@MainActor
final class DisplayHighlightOverlay {
    private var window: NSWindow?
    private var currentID: CGDirectDisplayID?

    /// Shows the border on the display with the given CGDirectDisplayID.
    /// Safe to call repeatedly; redundant calls for the same display are a no-op.
    func show(on displayID: CGDirectDisplayID) {
        if currentID == displayID, window?.isVisible == true { return }
        hide()

        guard let screen = NSScreen.screens.first(where: { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
        }) else {
            return
        }

        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.animationBehavior = .none

        let view = BorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        w.contentView = view

        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()

        window = w
        currentID = displayID
    }

    /// Hides the overlay unconditionally.
    func hide() {
        window?.orderOut(nil)
        window = nil
        currentID = nil
    }

    /// Hides the overlay only if it is currently showing for the given display.
    /// Prevents enter/exit ordering races between sibling menu rows from
    /// incorrectly dismissing a freshly shown overlay.
    func hide(ifOn displayID: CGDirectDisplayID) {
        if currentID == displayID { hide() }
    }

    // MARK: - Border rendering

    private final class BorderView: NSView {
        override var isFlipped: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            let borderWidth: CGFloat = 14
            let inset = borderWidth / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.setLineJoin(.miter)
            ctx.stroke(rect)
            ctx.restoreGState()
        }
    }
}
