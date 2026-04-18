// SettingsView.swift
// Minimal preferences UI. Exposed via the Settings scene in NDIBarApp.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: StreamingController

    var body: some View {
        Form {
            Section("NDI source") {
                TextField("Source prefix", text: $controller.sourcePrefix)
                    .textFieldStyle(.roundedBorder)
                Text("NDI sources will appear as \"\(controller.sourcePrefix) – Display N …\" on the network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                Picker("Frame rate", selection: $controller.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)

                Toggle("Downscale to 1080p", isOn: $controller.limitTo1080p)
                    .help("Leave on for the lightest bandwidth. Turn off to send native (e.g. 4K) resolution.")

                Toggle("Show cursor", isOn: $controller.showsCursor)
                Toggle("Capture system audio", isOn: $controller.captureAudio)
                    .help("Uses ScreenCaptureKit's built-in system audio tap. No BlackHole needed.")
            }

            Section("NDI") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.ndiReady ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(controller.ndiReady ? "NDI runtime loaded" : "NDI runtime not found")
                    Spacer()
                    if !controller.ndiReady {
                        Link("Download SDK", destination: URL(string: "https://ndi.video/sdk")!)
                    }
                }
                Text("NDI® is a registered trademark of Vizrt NDI AB.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 440, minHeight: 380)
    }
}
