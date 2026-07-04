// AppDelegate.swift
// Wires lifecycle, permissions, menubar, and the shared StreamingController.

import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let shutdownTimeoutSeconds = 10

    let streamingController = StreamingController()

    private var menuController: StatusMenuController?
    private var settingsWindowController: NSWindowController?
    private var terminationReplyGate = TerminationReplyGate()
    private var shutdownTask: Task<Void, Never>?
    private var shutdownWatchdogTask: Task<Void, Never>?

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationReplyGate.begin() else { return .terminateLater }

        // AppKit termination is synchronous by default. Delay it until the
        // async SCK stop barrier has drained callbacks and released senders;
        // only then may NDIlib_destroy/dlclose invalidate function pointers.
        shutdownTask = Task { @MainActor in
            await streamingController.shutdown()
            guard terminationReplyGate.resolve(.graceful) else { return }

            shutdownWatchdogTask?.cancel()
            shutdownWatchdogTask = nil
            NDILibrary.shared.unload()
            sender.reply(toApplicationShouldTerminate: true)
            shutdownTask = nil
        }

        // stopCapture is an OS callback and can theoretically never resume.
        // Bound quit latency, but on timeout deliberately leave NDI loaded:
        // callbacks/senders may still exist and process teardown is the only
        // safe cleanup mechanism available at that point.
        shutdownWatchdogTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.shutdownTimeoutSeconds))
            } catch {
                return
            }
            guard terminationReplyGate.resolve(.timedOut) else { return }

            NSLog("[ndi-bar] shutdown timed out after \(Self.shutdownTimeoutSeconds)s; terminating without destroying or unloading NDI")
            sender.reply(toApplicationShouldTerminate: true)
            shutdownWatchdogTask = nil
        }
        return .terminateLater
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
        window.setContentSize(NSSize(width: 500, height: 500))
        window.isReleasedWhenClosed = false
        window.center()

        let wc = NSWindowController(window: window)
        self.settingsWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
