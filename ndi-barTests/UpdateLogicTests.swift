import XCTest
@testable import ndi_bar

final class UpdateLogicTests: XCTestCase {

    // MARK: SemanticVersion

    func testSemanticVersionParsesPlainAndPrefixedTags() {
        XCTAssertEqual(SemanticVersion("0.2.1"), SemanticVersion(major: 0, minor: 2, patch: 1))
        XCTAssertEqual(SemanticVersion("v1.10.3"), SemanticVersion(major: 1, minor: 10, patch: 3))
        XCTAssertEqual(SemanticVersion(" v0.3.0\n"), SemanticVersion(major: 0, minor: 3, patch: 0))
    }

    func testSemanticVersionRejectsNonSemverInput() {
        XCTAssertNil(SemanticVersion("0.3"))
        XCTAssertNil(SemanticVersion("0.3.0.1"))
        XCTAssertNil(SemanticVersion("0.3.0-beta"))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.-2.3"))
    }

    func testSemanticVersionOrdersNumericallyNotLexically() {
        XCTAssertLessThan(SemanticVersion("0.2.1")!, SemanticVersion("0.10.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("1.0.1")!)
        XCTAssertFalse(SemanticVersion("1.0.0")! < SemanticVersion("1.0.0")!)
    }

    // MARK: Release → AvailableUpdate

    private func release(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assetNames: [String]
    ) -> UpdateReleaseInfo {
        UpdateReleaseInfo(
            tagName: tag,
            htmlURL: URL(string: "https://github.com/R44VC0RP/ndi-bar/releases/tag/\(tag)")!,
            draft: draft,
            prerelease: prerelease,
            assets: assetNames.map {
                UpdateReleaseInfo.Asset(
                    name: $0,
                    browserDownloadURL: URL(string: "https://example.com/\($0)")!
                )
            }
        )
    }

    func testNewerReleaseWithCanonicalAssetsIsInstallable() {
        let update = UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.0", assetNames: ["ndi-bar-v0.3.0.zip", "ndi-bar-v0.3.0.zip.sha256"]),
            currentVersion: SemanticVersion("0.2.1")!
        )

        XCTAssertEqual(update?.version, SemanticVersion("0.3.0"))
        XCTAssertEqual(update?.zipAssetName, "ndi-bar-v0.3.0.zip")
        XCTAssertNotNil(update?.checksumAssetURL)
    }

    func testOlderEqualDraftAndPrereleaseAreNotOffered() {
        let current = SemanticVersion("0.3.0")!
        let assets = ["ndi-bar-v0.3.1.zip"]

        XCTAssertNil(UpdateLogic.availableUpdate(
            from: release(tag: "v0.2.1", assetNames: ["ndi-bar-v0.2.1.zip"]),
            currentVersion: current
        ))
        XCTAssertNil(UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.0", assetNames: ["ndi-bar-v0.3.0.zip"]),
            currentVersion: current
        ))
        XCTAssertNil(UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.1", draft: true, assetNames: assets),
            currentVersion: current
        ))
        XCTAssertNil(UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.1", prerelease: true, assetNames: assets),
            currentVersion: current
        ))
    }

    func testFallsBackToSoleZipButRefusesAmbiguousAssets() {
        let current = SemanticVersion("0.2.1")!

        let sole = UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.0", assetNames: ["renamed-artifact.zip"]),
            currentVersion: current
        )
        XCTAssertEqual(sole?.zipAssetName, "renamed-artifact.zip")
        XCTAssertNil(sole?.checksumAssetURL)

        XCTAssertNil(UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.0", assetNames: ["a.zip", "b.zip"]),
            currentVersion: current
        ))
        XCTAssertNil(UpdateLogic.availableUpdate(
            from: release(tag: "v0.3.0", assetNames: ["notes.txt"]),
            currentVersion: current
        ))
    }

    func testChecksumAssetMustMatchChosenZipName() {
        let update = UpdateLogic.availableUpdate(
            from: release(
                tag: "v0.3.0",
                assetNames: ["ndi-bar-v0.3.0.zip", "ndi-bar-v0.2.1.zip.sha256"]
            ),
            currentVersion: SemanticVersion("0.2.1")!
        )
        XCTAssertNil(update?.checksumAssetURL)
    }

    // MARK: Checksum file parsing

    private let digest = String(repeating: "ab", count: 32)

    func testParsesShasumOutputForNamedAsset() {
        let contents = "\(digest)  ndi-bar-v0.3.0.zip\n"
        XCTAssertEqual(
            UpdateLogic.expectedChecksum(fromSha256File: contents, assetName: "ndi-bar-v0.3.0.zip"),
            digest
        )
    }

    func testParsesBinaryModeAndBareDigestLines() {
        XCTAssertEqual(
            UpdateLogic.expectedChecksum(
                fromSha256File: "\(digest) *ndi-bar-v0.3.0.zip",
                assetName: "ndi-bar-v0.3.0.zip"
            ),
            digest
        )
        XCTAssertEqual(
            UpdateLogic.expectedChecksum(fromSha256File: digest, assetName: "anything.zip"),
            digest
        )
    }

    func testNormalizesDigestCaseAndRejectsWrongNameOrMalformedDigest() {
        XCTAssertEqual(
            UpdateLogic.expectedChecksum(
                fromSha256File: "\(digest.uppercased())  ndi-bar-v0.3.0.zip",
                assetName: "ndi-bar-v0.3.0.zip"
            ),
            digest
        )
        XCTAssertNil(UpdateLogic.expectedChecksum(
            fromSha256File: "\(digest)  other.zip",
            assetName: "ndi-bar-v0.3.0.zip"
        ))
        XCTAssertNil(UpdateLogic.expectedChecksum(
            fromSha256File: "zzzz  ndi-bar-v0.3.0.zip",
            assetName: "ndi-bar-v0.3.0.zip"
        ))
        XCTAssertNil(UpdateLogic.expectedChecksum(fromSha256File: "", assetName: "a.zip"))
    }

    func testGitHubReleasePayloadDecodes() throws {
        let json = """
        {
          "tag_name": "v0.3.0",
          "html_url": "https://github.com/R44VC0RP/ndi-bar/releases/tag/v0.3.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "ndi-bar-v0.3.0.zip",
              "browser_download_url": "https://github.com/R44VC0RP/ndi-bar/releases/download/v0.3.0/ndi-bar-v0.3.0.zip"
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(UpdateReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tagName, "v0.3.0")
        XCTAssertEqual(decoded.assets.count, 1)
        XCTAssertEqual(decoded.assets.first?.name, "ndi-bar-v0.3.0.zip")
    }
}
