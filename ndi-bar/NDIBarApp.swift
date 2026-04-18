// NDIBarApp.swift
// Entry point. Menubar apps still use an AppDelegate for the NSStatusItem;
// we keep a SwiftUI Settings scene for the preferences UI.

import SwiftUI

@main
struct NDIBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(controller: appDelegate.streamingController)
        }
    }
}
