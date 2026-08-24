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
    private let updates: UpdateController
    private let openSettings: () -> Void

    private let statusItem: NSStatusItem
    private let overlay = DisplayHighlightOverlay()
    private var cancellables = Set<AnyCancellable>()

    init(controller: StreamingController,
         updates: UpdateController,
         openSettings: @escaping () -> Void) {
        self.controller = controller
        self.updates = updates
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
        controller.$isCameraStreaming
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
            return controller.activeDisplayIDs.isEmpty && !controller.isCameraStreaming
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
        controller.refreshMicrophones()
        controller.refreshCameras()
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

        addCameraSection(to: menu)
        menu.addItem(.separator())

        if controller.microphoneCaptureSupported {
            addMicrophoneSection(to: menu)
            menu.addItem(.separator())
        }

        let stopAll = NSMenuItem(
            title: "Stop All Streams",
            action: #selector(stopAllAction),
            keyEquivalent: "."
        )
        stopAll.target = self
        stopAll.isEnabled = !controller.activeDisplayIDs.isEmpty || controller.isCameraStreaming
        menu.addItem(stopAll)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        addUpdateItem(to: menu)

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

    private func addCameraSection(to menu: NSMenu) {
        let header = NSMenuItem(title: "Camera Source", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        guard !controller.cameraDevices.isEmpty else {
            let empty = NSMenuItem(title: "No cameras detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for device in controller.cameraDevices {
            let isActive = controller.isCameraStreaming
                && controller.activeCameraDeviceID == device.id
            var title = device.name
            if isActive {
                switch controller.cameraViewerCount {
                case ..<0: break
                case 0:  title += "  ·  broadcasting"
                case 1:  title += "  ·  1 viewer"
                default: title += "  ·  \(controller.cameraViewerCount) viewers"
                }
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(toggleCameraAction),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device
            item.state = isActive ? .on : .off
            item.isEnabled = controller.ndiReady
            menu.addItem(item)
        }
    }

    private func addMicrophoneSection(to menu: NSMenu) {
        let header = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let capture = NSMenuItem(
            title: "Capture Microphone",
            action: #selector(toggleCaptureMicrophoneAction),
            keyEquivalent: ""
        )
        capture.target = self
        capture.state = controller.captureMicrophone ? .on : .off
        menu.addItem(capture)

        let systemDefault = makeMicrophoneItem(
            title: "System Default",
            id: MicrophoneDevice.systemDefaultID
        )
        menu.addItem(systemDefault)

        if controller.selectedMicrophoneDeviceUnavailable {
            let unavailable = makeMicrophoneItem(
                title: "Unavailable selected microphone",
                id: controller.selectedMicrophoneDeviceID
            )
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }

        if controller.microphoneDevices.isEmpty {
            let empty = NSMenuItem(title: "No microphones detected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for device in controller.microphoneDevices {
                menu.addItem(makeMicrophoneItem(title: device.name, id: device.id))
            }
        }
    }

    private func makeMicrophoneItem(title: String, id: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(selectMicrophoneAction),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = id
        item.state = controller.selectedMicrophoneDeviceID == id ? .on : .off
        return item
    }

    private func addUpdateItem(to menu: NSMenu) {
        switch updates.phase {
        case .available(let update):
            let item = NSMenuItem(
                title: "Install Update \(update.tagName)…",
                action: #selector(installUpdateAction),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        case .installing(let status):
            let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .checking:
            let item = NSMenuItem(title: "Checking for Updates…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .idle, .upToDate, .failed:
            let item = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdatesAction),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: Actions

    @objc private func checkForUpdatesAction() {
        Task { await updates.checkForUpdates(userInitiated: true) }
    }

    @objc private func installUpdateAction() {
        updates.installAvailableUpdate()
    }

    @objc private func stopAllAction() {
        Task { await controller.stopAll() }
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func toggleCameraAction(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CameraDevice else { return }
        controller.toggleCamera(device)
    }

    @objc private func toggleCaptureMicrophoneAction() {
        controller.captureMicrophone.toggle()
        controller.refreshMicrophones()
    }

    @objc private func selectMicrophoneAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.selectMicrophoneDevice(id)
    }

    @objc private func openNDIDownload() {
        if let url = URL(string: "https://ndi.video/sdk") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func grantPermissionAction() {
        // Fire-and-forget: the controller handles probing TCC and requesting
        // access. We intentionally do NOT open System Settings from here —
        // that would steal focus from macOS's native prompt. The menu offers
        // a separate "Open Privacy Settings…" item for the manual path.
        Task { @MainActor in
            await controller.requestScreenRecordingPermission()
        }
    }

    @objc private func openPrivacySettingsAction() {
        controller.openScreenRecordingSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
