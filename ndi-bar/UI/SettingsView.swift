// SettingsView.swift
// Minimal preferences UI. Exposed via the Settings scene in NDIBarApp.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: StreamingController
    @ObservedObject var updates: UpdateController

    var body: some View {
        let microphoneSelection = Binding<String>(
            get: { controller.selectedMicrophoneDeviceID },
            set: { controller.selectMicrophoneDevice($0) }
        )
        let cameraSelection = Binding<String>(
            get: { controller.selectedCameraDeviceID },
            set: { controller.selectCameraDevice($0) }
        )
        let cameraMicrophoneSelection = Binding<String>(
            get: { controller.cameraMicrophoneDeviceID },
            set: { controller.selectCameraMicrophoneDevice($0) }
        )

        Form {
            Section("NDI source") {
                TextField("Source prefix", text: $controller.sourcePrefix)
                    .textFieldStyle(.roundedBorder)
                Text("NDI sources will appear as \"\(controller.sourcePrefix) – Display N …\" on the network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                HStack {
                    Text("Frame rate")
                    Spacer()
                    TextField("FPS", value: $controller.fps, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .accessibilityLabel("Frame rate in frames per second")
                        .accessibilityHint("Enter a whole number from 1 through 120. Values outside that range are clamped.")
                    Stepper("Frame rate", value: $controller.fps, in: CapturePreferences.validFPS)
                        .labelsHidden()
                        .accessibilityHint("Adjusts frame rate from 1 through 120 frames per second.")
                }
                .help("Any whole-number FPS from 1 through 120. Actual delivery can be limited by display and capture cadence.")

                Picker("Output resolution", selection: $controller.resolutionCap) {
                    ForEach(OutputResolutionCap.allCases) { cap in
                        Text(cap.displayName).tag(cap)
                    }
                }
                .pickerStyle(.menu)
                .help("Presets and custom dimensions are maximum bounds. Output preserves source aspect ratio and is never upscaled.")

                if controller.resolutionCap == .custom {
                    HStack {
                        Text("Custom maximum")
                        Spacer()
                        TextField("Width", value: $controller.customResolutionWidth, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .accessibilityLabel("Custom maximum width in pixels")
                            .accessibilityHint("Enter a whole number from 2 through 16384. Values outside that range are clamped.")
                        Text("×")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Height", value: $controller.customResolutionHeight, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .accessibilityLabel("Custom maximum height in pixels")
                            .accessibilityHint("Enter a whole number from 2 through 16384. Values outside that range are clamped.")
                    }
                    .help("Maximum width and height in pixels (2–16384). Changes settle for half a second before active streams restart.")
                }

                Text("Effective request: \(controller.captureConfigurationSummary). Active streams restart after changes settle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Out-of-range FPS and custom dimensions are clamped to the limits shown above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Show cursor", isOn: $controller.showsCursor)
                Toggle("Capture system audio", isOn: $controller.captureAudio)
                    .help("Uses ScreenCaptureKit's built-in system audio tap. No BlackHole needed.")
                Toggle("Capture microphone", isOn: $controller.captureMicrophone)
                    .disabled(!controller.microphoneCaptureSupported)
                    .help("Mixes the selected microphone with system audio when both are enabled.")

                Picker("Microphone", selection: microphoneSelection) {
                    Text("System Default").tag(MicrophoneDevice.systemDefaultID)
                    if controller.selectedMicrophoneDeviceUnavailable {
                        Text("Unavailable selected microphone").tag(controller.selectedMicrophoneDeviceID)
                    }
                    ForEach(controller.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .disabled(!controller.microphoneCaptureSupported || !controller.captureMicrophone)
                .help("Selects which audio input ScreenCaptureKit uses for microphone capture.")

                if !controller.microphoneCaptureSupported {
                    Text("Microphone capture requires macOS 15 or later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if controller.captureMicrophone && controller.selectedMicrophoneDeviceUnavailable {
                    Text("The selected microphone is not connected. Choose another input or System Default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if controller.captureMicrophone && !controller.microphonePermissionGranted {
                    HStack(spacing: 8) {
                        Text("Microphone access is required before streaming.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Privacy Settings") {
                            controller.openMicrophoneSettings()
                        }
                    }
                }
            }

            Section("Camera source") {
                Picker("Camera", selection: cameraSelection) {
                    Text("System Default").tag(CameraDevice.systemDefaultID)
                    if controller.selectedCameraDeviceUnavailable {
                        Text("Unavailable selected camera").tag(controller.selectedCameraDeviceID)
                    }
                    ForEach(controller.cameraDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .help("Camera captured as a second, independent NDI source.")

                Picker("Microphone", selection: cameraMicrophoneSelection) {
                    Text("System Default").tag(MicrophoneDevice.systemDefaultID)
                    if controller.cameraMicrophoneDeviceUnavailable {
                        Text("Unavailable selected microphone").tag(controller.cameraMicrophoneDeviceID)
                    }
                    ForEach(controller.microphoneDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .help("Microphone audio sent with the camera source.")

                Text("Start it from the menu bar under \"Camera Source\". It appears as \"\(controller.sourcePrefix) – Camera (…)\" on the network, alongside the display streams.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if controller.selectedCameraDeviceUnavailable {
                    Text("The selected camera is not connected. Choose another camera or System Default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !controller.cameraPermissionGranted {
                    HStack(spacing: 8) {
                        Text("Camera access is requested when the source first starts.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Privacy Settings") {
                            controller.openCameraSettings()
                        }
                    }
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.automaticChecksEnabled)
                    .help("Checks the GitHub releases feed once a day.")

                HStack(spacing: 8) {
                    Text(updateStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch updates.phase {
                    case .available(let update):
                        Button("Install \(update.tagName)") {
                            updates.installAvailableUpdate()
                        }
                    case .checking, .installing:
                        ProgressView()
                            .controlSize(.small)
                    case .idle, .upToDate, .failed:
                        Button("Check Now") {
                            Task { await updates.checkForUpdates(userInitiated: true) }
                        }
                    }
                }
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
        .frame(minWidth: 460, minHeight: 480)
        .onAppear {
            controller.refreshMicrophones()
            controller.refreshCameras()
        }
    }

    private var updateStatusText: String {
        switch updates.phase {
        case .idle:
            return "Version \(updates.currentVersionString)"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Version \(updates.currentVersionString) — up to date"
        case .available(let update):
            return "Update available: \(update.tagName) (current \(updates.currentVersionString))"
        case .installing(let status):
            return status
        case .failed(let message):
            return message
        }
    }
}
