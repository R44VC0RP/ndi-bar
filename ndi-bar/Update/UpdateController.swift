// UpdateController.swift
// Self-updater. Checks GitHub Releases for a newer version, then downloads,
// verifies (SHA-256 + code signature + Team ID policy), swaps the app bundle
// in place, and relaunches through the normal graceful-shutdown path.
//
// No third-party dependencies: URLSession + ditto + codesign do the work.
// Verification policy:
//   - the zip must match the release's published .sha256 when present
//   - the extracted app must pass `codesign --verify --deep --strict`
//   - if the running app has a Team ID, the update's Team ID must match;
//     an ad-hoc dev build accepts any validly Developer ID-signed update
//   - bundle identifier must match, and the payload version must equal the
//     release tag

import Foundation
import AppKit
import CryptoKit

@MainActor
final class UpdateController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case installing(String)
        case failed(String)
    }

    private enum Keys {
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
    }

    static let repository = "R44VC0RP/ndi-bar"
    private static let checkInterval: TimeInterval = 60 * 60 * 24
    private static let staleBundlePrefix = ".ndi-bar-old-"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckDate: Date?
    @Published var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecksEnabled, forKey: Keys.automaticUpdateChecks)
        }
    }

    let currentVersionString: String
    private let currentVersion: SemanticVersion?
    private var automaticCheckTask: Task<Void, Never>?
    private var isInstalling = false

    init() {
        let d = UserDefaults.standard
        self.automaticChecksEnabled = d.object(forKey: Keys.automaticUpdateChecks) as? Bool ?? true
        self.lastCheckDate = d.object(forKey: Keys.lastUpdateCheckDate) as? Date

        let versionString = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        self.currentVersionString = versionString
        self.currentVersion = SemanticVersion(versionString)

        cleanupStaleBundles()
    }

    // MARK: Automatic checks

    /// Long-lived loop: runs a check when one is due, then re-evaluates
    /// hourly so toggling the preference takes effect without a relaunch.
    func startAutomaticChecks() {
        guard automaticCheckTask == nil else { return }
        automaticCheckTask = Task { @MainActor [weak self] in
            // Let boot (NDI load, permission probes) settle first.
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                if let self, self.automaticChecksEnabled, self.isCheckDue {
                    await self.checkForUpdates(userInitiated: false)
                }
                guard self != nil else { return }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private var isCheckDue: Bool {
        switch phase {
        case .installing, .available:
            return false
        case .idle, .checking, .upToDate, .failed:
            break
        }
        guard let lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheckDate) >= Self.checkInterval
    }

    // MARK: Check

    func checkForUpdates(userInitiated: Bool) async {
        if case .installing = phase { return }
        if userInitiated { phase = .checking }

        do {
            let release = try await fetchLatestRelease()
            lastCheckDate = Date()
            UserDefaults.standard.set(lastCheckDate, forKey: Keys.lastUpdateCheckDate)

            guard let currentVersion else {
                phase = .failed("Current version \"\(currentVersionString)\" is not comparable.")
                return
            }
            if let update = UpdateLogic.availableUpdate(from: release, currentVersion: currentVersion) {
                phase = .available(update)
                NSLog("[ndi-bar] update available: \(update.tagName) (current \(currentVersion))")
            } else {
                phase = userInitiated ? .upToDate : .idle
            }
        } catch {
            NSLog("[ndi-bar] update check failed: \(error.localizedDescription)")
            if userInitiated {
                phase = .failed("Update check failed: \(error.localizedDescription)")
            }
            // Background failures stay quiet; the next cycle retries.
        }
    }

    private func fetchLatestRelease() async throws -> UpdateReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else {
            throw UpdateError.internalFailure("invalid releases URL")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ndi-bar/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.network("GitHub API returned HTTP \(code).")
        }
        return try JSONDecoder().decode(UpdateReleaseInfo.self, from: data)
    }

    // MARK: Install

    func installAvailableUpdate() {
        guard case .available(let update) = phase, !isInstalling else { return }
        isInstalling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.install(update)
                // Success ends in relaunch; this line is never reached.
            } catch {
                NSLog("[ndi-bar] update install failed: \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
            self.isInstalling = false
        }
    }

    private func install(_ update: AvailableUpdate) async throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw UpdateError.internalFailure("not running from an .app bundle")
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            throw UpdateError.installation("The folder containing \(bundleURL.lastPathComponent) is not writable.")
        }

        // Stage everything on the same volume as the bundle so the final
        // swap is a pair of atomic renames.
        let stagingDir = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: bundleURL,
            create: true
        )
        defer { try? fm.removeItem(at: stagingDir) }

        phase = .installing("Downloading \(update.tagName)…")
        let zipURL = try await download(update.zipAssetURL, to: stagingDir.appendingPathComponent(update.zipAssetName))

        phase = .installing("Verifying download…")
        if let checksumAssetURL = update.checksumAssetURL {
            try await verifyChecksum(zipURL: zipURL, checksumAssetURL: checksumAssetURL, assetName: update.zipAssetName)
        } else {
            NSLog("[ndi-bar] release \(update.tagName) publishes no .sha256 asset; relying on signature checks")
        }

        let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
        try await runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path], failure: "Extracting the update failed")

        let newApp = try locateAppBundle(in: extractDir)
        try await verifySignature(of: newApp)
        try verifyPayload(of: newApp, matches: update)

        // Belt and braces: our URLSession download isn't quarantined, but a
        // stray xattr would make Gatekeeper reassess on relaunch.
        try? await runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], failure: "")

        phase = .installing("Installing \(update.tagName)…")
        let parkedOld = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.staleBundlePrefix)\(ProcessInfo.processInfo.processIdentifier).app")
        try fm.moveItem(at: bundleURL, to: parkedOld)
        do {
            try fm.moveItem(at: newApp, to: bundleURL)
        } catch {
            // Roll back so the user still has a working install.
            try? fm.moveItem(at: parkedOld, to: bundleURL)
            throw UpdateError.installation("Installing the new version failed: \(error.localizedDescription)")
        }
        // The running executable stays alive via its open file handles even
        // after the old bundle is deleted. If deletion fails we sweep the
        // parked copy on next launch.
        try? fm.removeItem(at: parkedOld)

        phase = .installing("Relaunching…")
        NSLog("[ndi-bar] installed \(update.tagName); relaunching")
        try scheduleRelaunch(of: bundleURL)
        // Graceful path: stops streams, destroys senders, unloads NDI.
        NSApp.terminate(nil)
    }

    // MARK: Install steps

    private func download(_ remote: URL, to destination: URL) async throws -> URL {
        var request = URLRequest(url: remote)
        request.setValue("ndi-bar/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateError.network("Download failed with HTTP \(code).")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func verifyChecksum(zipURL: URL, checksumAssetURL: URL, assetName: String) async throws {
        var request = URLRequest(url: checksumAssetURL)
        request.setValue("ndi-bar/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let contents = String(data: data, encoding: .utf8) else {
            throw UpdateError.verification("Could not fetch the release checksum.")
        }
        guard let expected = UpdateLogic.expectedChecksum(fromSha256File: contents, assetName: assetName) else {
            throw UpdateError.verification("The release checksum file is malformed.")
        }

        let zipData = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw UpdateError.verification("Checksum mismatch — the download does not match the published release.")
        }
    }

    private func locateAppBundle(in directory: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw UpdateError.verification("The update archive does not contain exactly one app bundle.")
        }
        return app
    }

    private func verifySignature(of app: URL) async throws {
        try await runProcess(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", app.path],
            failure: "The update's code signature is invalid"
        )

        let newTeam = try await teamIdentifier(of: app)
        let currentTeam = try? await teamIdentifier(of: Bundle.main.bundleURL)
        if let currentTeam {
            guard newTeam == currentTeam else {
                throw UpdateError.verification("The update is signed by a different team (\(newTeam ?? "unsigned")) than this app (\(currentTeam)).")
            }
        } else {
            // Ad-hoc dev build updating to a release build: require the
            // update to carry a real signing team at minimum.
            guard newTeam != nil else {
                throw UpdateError.verification("The update is not signed with a Developer ID.")
            }
        }
    }

    private func teamIdentifier(of app: URL) async throws -> String? {
        let output = try await runProcessCapturingStderr("/usr/bin/codesign", ["-dvv", app.path])
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(line.dropFirst("TeamIdentifier=".count))
            return value == "not set" ? nil : value
        }
        return nil
    }

    private func verifyPayload(of app: URL, matches update: AvailableUpdate) throws {
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist) as? [String: Any] else {
            throw UpdateError.verification("The update has no readable Info.plist.")
        }
        guard let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.verification("The update's bundle identifier does not match.")
        }
        guard let versionString = info["CFBundleShortVersionString"] as? String,
              let version = SemanticVersion(versionString),
              version == update.version else {
            throw UpdateError.verification("The update's version does not match the release tag.")
        }
    }

    /// Detached watcher: waits for this process to fully exit (so the
    /// graceful NDI shutdown completes), then opens the new bundle.
    private func scheduleRelaunch(of bundleURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, bundleURL.path]
        try process.run()
    }

    /// Removes parked old bundles a previous update failed to delete.
    private func cleanupStaleBundles() {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.staleBundlePrefix)
            && entry.pathExtension == "app" {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: Process helpers (off-main)

    private func runProcess(_ launchPath: String, _ arguments: [String], failure: String) async throws {
        let result = await Self.run(launchPath: launchPath, arguments: arguments)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.verification("\(failure)\(detail.isEmpty ? "." : ": \(detail)")")
        }
    }

    private func runProcessCapturingStderr(_ launchPath: String, _ arguments: [String]) async throws -> String {
        let result = await Self.run(launchPath: launchPath, arguments: arguments)
        guard result.status == 0 else {
            throw UpdateError.verification("codesign inspection failed.")
        }
        return result.stderr
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let stderr: String
    }

    private nonisolated static func run(launchPath: String, arguments: [String]) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessResult(status: -1, stderr: error.localizedDescription))
                    return
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

enum UpdateError: Error, LocalizedError {
    case network(String)
    case verification(String)
    case installation(String)
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .network(let message),
             .verification(let message),
             .installation(let message):
            return message
        case .internalFailure(let message):
            return "Updater internal error: \(message)"
        }
    }
}
