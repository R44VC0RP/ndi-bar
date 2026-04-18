// DisplayMenuItemView.swift
// Custom NSView used as `NSMenuItem.view` for each display row.
//
// Why custom? We need reliable hover tracking (NSMenuItem alone doesn't
// expose enter/exit events) so we can show the red screen-border overlay
// only while the mouse is actually over a given display row.
//
// The view draws its own background, checkmark, and title so it matches
// standard NSMenu look but keeps total control of the hover highlight.

import Foundation
import AppKit

@MainActor
final class DisplayMenuItemView: NSView {

    private let display: DisplayInfo
    private let isStreaming: Bool
    private let viewers: Int
    private let isEnabled: Bool
    private let onClick: () -> Void
    private let onHoverEnter: () -> Void
    private let onHoverExit: () -> Void

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    // Visual constants — roughly match NSMenu row metrics.
    private static let rowHeight: CGFloat = 22
    private static let leadingInset: CGFloat = 22   // space for checkmark
    private static let trailingInset: CGFloat = 16
    private static let horizontalPadding: CGFloat = 4

    init(display: DisplayInfo,
         isStreaming: Bool,
         viewers: Int,
         isEnabled: Bool,
         onClick: @escaping () -> Void,
         onHoverEnter: @escaping () -> Void,
         onHoverExit: @escaping () -> Void) {
        self.display = display
        self.isStreaming = isStreaming
        self.viewers = viewers
        self.isEnabled = isEnabled
        self.onClick = onClick
        self.onHoverEnter = onHoverEnter
        self.onHoverExit = onHoverExit

        let attrs = Self.titleAttributes(enabled: isEnabled, highlighted: false)
        let text = Self.titleString(
            display: display,
            isStreaming: isStreaming,
            viewers: viewers
        )
        let textSize = (text as NSString).size(withAttributes: attrs)
        let width = Self.leadingInset + textSize.width + Self.trailingInset

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        needsDisplay = true
        onHoverEnter()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        onHoverExit()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        // Dismiss the menu then perform the action, matching native click UX.
        self.enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Row background
        if isHovered {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }

        let highlighted = isHovered
        let textColor: NSColor = {
            if !isEnabled { return .disabledControlTextColor }
            return highlighted ? .selectedMenuItemTextColor : .labelColor
        }()

        // Checkmark for streaming rows.
        if isStreaming {
            let check = "✓"
            let font = NSFont.menuFont(ofSize: 0)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let size = (check as NSString).size(withAttributes: attrs)
            let x = (Self.leadingInset - size.width) / 2 + 2
            let y = (bounds.height - size.height) / 2 - 1
            (check as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }

        // Title
        let title = Self.titleString(
            display: display,
            isStreaming: isStreaming,
            viewers: viewers
        )
        let attrs = Self.titleAttributes(enabled: isEnabled, highlighted: highlighted)
        let size = (title as NSString).size(withAttributes: attrs)
        let textRect = NSRect(
            x: Self.leadingInset,
            y: (bounds.height - size.height) / 2 - 1,
            width: bounds.width - Self.leadingInset - Self.horizontalPadding,
            height: size.height
        )
        (title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Title

    private static func titleString(display: DisplayInfo,
                                    isStreaming: Bool,
                                    viewers: Int) -> String {
        let res = "\(display.width)×\(display.height)"
        var s = "Monitor \(display.ordinal) · \(display.localizedName) · \(res)"
        if isStreaming {
            switch viewers {
            case ..<0: break
            case 0:  s += "  ·  broadcasting"
            case 1:  s += "  ·  1 viewer"
            default: s += "  ·  \(viewers) viewers"
            }
        }
        return s
    }

    private static func titleAttributes(enabled: Bool, highlighted: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let color: NSColor = {
            if !enabled { return .disabledControlTextColor }
            return highlighted ? .selectedMenuItemTextColor : .labelColor
        }()

        return [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }
}
