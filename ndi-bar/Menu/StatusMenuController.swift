// StatusMenuController.swift
// Builds and updates the menubar popup. Re-renders on every open so we
// always show fresh display and connection state.

import Foundation
import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: StreamingController
    private let openSettings: () -> Void

    private let statusItem: NSStatusItem
    private let overlay = DisplayHighlightOverlay()
    private var cancellables = Set<AnyCancellable>()

    init(controller: StreamingController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // React to state changes so the menubar icon updates even while open.
        controller.$activeDisplayIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonIcon() }
            .store(in: &cancellables)
        controller.$screenRecordingGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonIcon() }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeft
        button.toolTip = "ndi-bar"
        updateButtonIcon()
    }

    private func updateButtonIcon() {
        guard let button = statusItem.button else { return }
        let name: String = {
            if !controller.screenRecordingGranted {
                return "exclamationmark.triangle"
            }
            return controller.activeDisplayIDs.isEmpty
                ? "rectangle.on.rectangle"
                : "dot.radiowaves.left.and.right"
        }()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ndi-bar")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
    }

    // MARK: Menu build

    func menuWillOpen(_ menu: NSMenu) {
        Task { await controller.refreshDisplays() }
        rebuild(menu: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Always clear the display-border overlay when the menu closes,
        // regardless of how it was dismissed (click, ESC, click-away).
        overlay.hide()
    }

    private func rebuild(menu: NSMenu) {
        menu.removeAllItems()

        if !controller.ndiReady {
            let item = NSMenuItem(title: "NDI runtime not loaded", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            let install = NSMenuItem(
                title: "Download NDI SDK…",
                action: #selector(openNDIDownload),
                keyEquivalent: ""
            )
            install.target = self
            menu.addItem(install)

            menu.addItem(.separator())
        }

        if let err = controller.lastError, controller.screenRecordingGranted {
            // Don't double up with the permission block below.
            let item = NSMenuItem(title: "⚠︎ \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if !controller.screenRecordingGranted {
            let header = NSMenuItem(title: "Screen recording permission needed", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let request = NSMenuItem(
                title: "Grant Screen Recording…",
                action: #selector(grantPermissionAction),
                keyEquivalent: ""
            )
            request.target = self
            menu.addItem(request)

            let openSys = NSMenuItem(
                title: "Open Privacy Settings…",
                action: #selector(openPrivacySettingsAction),
                keyEquivalent: ""
            )
            openSys.target = self
            menu.addItem(openSys)

            let hint = NSMenuItem(
                title: "If the toggle is already on, turn it off and back on, then relaunch.",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)

            menu.addItem(.separator())

            let quit = NSMenuItem(
                title: "Quit ndi-bar",
                action: #selector(quitApp),
                keyEquivalent: "q"
            )
            quit.target = self
            menu.addItem(quit)
            return
        }

        // Header
        let header = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if controller.displays.isEmpty {
            let empty = NSMenuItem(title: "No displays detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in controller.displays {
                menu.addItem(makeDisplayItem(display))
            }
        }

        menu.addItem(.separator())

        let stopAll = NSMenuItem(
            title: "Stop All Streams",
            action: #selector(stopAllAction),
            keyEquivalent: "."
        )
        stopAll.target = self
        stopAll.isEnabled = !controller.activeDisplayIDs.isEmpty
        menu.addItem(stopAll)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ndi-bar",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func makeDisplayItem(_ display: DisplayInfo) -> NSMenuItem {
        let isOn = controller.isStreaming(display)
        let viewers = isOn ? controller.viewerCount(for: display) : -1
        let enabled = controller.ndiReady

        let item = NSMenuItem()
        item.representedObject = display
        item.isEnabled = enabled

        let view = DisplayMenuItemView(
            display: display,
            isStreaming: isOn,
            viewers: viewers,
            isEnabled: enabled,
            onClick: { [weak self] in
                guard let self else { return }
                self.controller.toggle(display)
            },
            onHoverEnter: { [weak self, id = display.id] in
                self?.overlay.show(on: id)
            },
            onHoverExit: { [weak self, id = display.id] in
                self?.overlay.hide(ifOn: id)
            }
        )
        item.view = view
        return item
    }

    // MARK: Actions

    @objc private func stopAllAction() {
        Task { await controller.stopAll() }
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func openNDIDownload() {
        if let url = URL(string: "https://ndi.video/sdk") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func grantPermissionAction() {
        controller.requestScreenRecordingPermission()
        // Ask macOS to open the Settings pane too — if the user already
        // has a stale "granted" record, the prompt won't appear and they
        // need to toggle it off/on in Settings to rebind TCC.
        controller.openScreenRecordingSettings()
    }

    @objc private func openPrivacySettingsAction() {
        controller.openScreenRecordingSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
