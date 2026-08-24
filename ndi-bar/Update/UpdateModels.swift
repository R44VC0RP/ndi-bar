// UpdateModels.swift
// Pure, testable logic for the self-updater: version parsing/ordering,
// GitHub release decoding, asset selection, and checksum-file parsing.
// All side effects (network, filesystem, process) live in UpdateController.

import Foundation

/// Strict X.Y.Z version. Pre-release/build suffixes are rejected on purpose:
/// release tags are plain semver (`v0.2.1`) and anything else should never
/// be offered as an update.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts "0.3.0" or "v0.3.0".
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text = String(text.dropFirst())
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// Subset of the GitHub Releases API payload the updater needs.
struct UpdateReleaseInfo: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

/// A concrete, installable update resolved from a release.
struct AvailableUpdate: Equatable, Sendable {
    let version: SemanticVersion
    let tagName: String
    let releasePageURL: URL
    let zipAssetName: String
    let zipAssetURL: URL
    /// Companion `<zip>.sha256` asset, when the release publishes one.
    let checksumAssetURL: URL?
}

enum UpdateLogic {

    /// Decides whether `release` is a newer, installable version than
    /// `currentVersion`, and resolves its download assets.
    static func availableUpdate(
        from release: UpdateReleaseInfo,
        currentVersion: SemanticVersion
    ) -> AvailableUpdate? {
        guard !release.draft, !release.prerelease else { return nil }
        guard let version = SemanticVersion(release.tagName), version > currentVersion else {
            return nil
        }

        // Prefer the canonical Makefile artifact name; fall back to the only
        // zip in the release. Refuse ambiguity rather than guessing.
        let canonicalName = "ndi-bar-v\(version).zip"
        let zipAssets = release.assets.filter { $0.name.hasSuffix(".zip") }
        let zipAsset: UpdateReleaseInfo.Asset?
        if let canonical = zipAssets.first(where: { $0.name == canonicalName }) {
            zipAsset = canonical
        } else if zipAssets.count == 1 {
            zipAsset = zipAssets.first
        } else {
            zipAsset = nil
        }
        guard let zipAsset else { return nil }

        let checksumAsset = release.assets.first { $0.name == zipAsset.name + ".sha256" }

        return AvailableUpdate(
            version: version,
            tagName: release.tagName,
            releasePageURL: release.htmlURL,
            zipAssetName: zipAsset.name,
            zipAssetURL: zipAsset.browserDownloadURL,
            checksumAssetURL: checksumAsset?.browserDownloadURL
        )
    }

    /// Extracts the expected SHA-256 hex digest for `assetName` from a
    /// `shasum -a 256` output file ("<hex>  <filename>" lines). When a line
    /// names a file, it must name our asset; a bare digest is also accepted.
    static func expectedChecksum(fromSha256File contents: String, assetName: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = tokens.first, isSHA256Hex(first) else { continue }
            if tokens.count == 1 {
                return String(first).lowercased()
            }
            // shasum binary-mode lines prefix the name with "*".
            let namedFile = tokens[1].hasPrefix("*") ? tokens[1].dropFirst() : tokens[1]
            if namedFile == Substring(assetName) {
                return String(first).lowercased()
            }
        }
        return nil
    }

    private static func isSHA256Hex(_ text: Substring) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}
