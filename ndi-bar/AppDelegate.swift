// AppDelegate.swift
// Wires lifecycle, permissions, menubar, and the shared StreamingController.

import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let streamingController = StreamingController()

    private var menuController: StatusMenuController?
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only app; no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)

        menuController = StatusMenuController(
            controller: streamingController,
            openSettings: { [weak self] in self?.showSettings() }
        )

        Task { @MainActor in
            await streamingController.boot()
        }

        // If the user toggles our permission in Settings and we become
        // active again (e.g. after clicking us in the dock or Settings),
        // re-evaluate TCC so the menu reflects reality without a relaunch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.streamingController.refreshPermissionState()
                await self?.streamingController.refreshDisplays()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await streamingController.stopAll() }
        NDILibrary.shared.unload()
    }

    // MARK: Settings window

    private func showSettings() {
        if let wc = settingsWindowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(controller: streamingController))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ndi-bar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 420))
        window.isReleasedWhenClosed = false
        window.center()

        let wc = NSWindowController(window: window)
        self.settingsWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
