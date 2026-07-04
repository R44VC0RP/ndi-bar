import XCTest
@testable import ndi_bar

final class CaptureConfigurationTests: XCTestCase {
    func testNativeResolutionUsesContentRectTimesPointPixelScale() {
        let native = CaptureGeometry.nativeResolution(
            contentWidth: 1512,
            contentHeight: 982,
            pointPixelScale: 2,
            fallback: PixelSize(width: 1, height: 1)
        )

        XCTAssertEqual(native, .init(size: PixelSize(width: 3024, height: 1964), usedFallback: false))
    }

    func testNativeResolutionFallsBackForInvalidSCKGeometry() {
        let native = CaptureGeometry.nativeResolution(
            contentWidth: 0,
            contentHeight: 1080,
            pointPixelScale: 2,
            fallback: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(native, .init(size: PixelSize(width: 1920, height: 1080), usedFallback: true))
    }

    func testNativeResolutionFallsBackAtIntConversionBoundary() {
        let native = CaptureGeometry.nativeResolution(
            contentWidth: Double(Int.max),
            contentHeight: 1080,
            pointPixelScale: 1,
            fallback: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(native, .init(size: PixelSize(width: 1920, height: 1080), usedFallback: true))
    }

    func testLandscapePresetFitsBothBounds() {
        let output = CaptureGeometry.outputSize(
            source: PixelSize(width: 3840, height: 2160),
            maximum: OutputResolutionCap.p1080.maximumSize(customWidth: 2, customHeight: 2)
        )

        XCTAssertEqual(output, PixelSize(width: 1920, height: 1080))
    }

    func testAllPresetBoundingBoxesRemainStable() {
        XCTAssertEqual(
            OutputResolutionCap.p1440.maximumSize(customWidth: 2, customHeight: 2),
            PixelSize(width: 2560, height: 1440)
        )
        XCTAssertEqual(
            OutputResolutionCap.p1080.maximumSize(customWidth: 2, customHeight: 2),
            PixelSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(
            OutputResolutionCap.p720.maximumSize(customWidth: 2, customHeight: 2),
            PixelSize(width: 1280, height: 720)
        )
        XCTAssertNil(OutputResolutionCap.native.maximumSize(customWidth: 2, customHeight: 2))
    }

    func testCustomCapPreservesAspectWithoutForcedCanvas() {
        let source = PixelSize(width: 3000, height: 2000)
        let output = CaptureGeometry.outputSize(
            source: source,
            maximum: PixelSize(width: 1000, height: 1000)
        )

        XCTAssertEqual(output, PixelSize(width: 1000, height: 666))
        assertAspect(source, output)
    }

    func testPortraitFitsHeightAndPreservesAspect() {
        let source = PixelSize(width: 2160, height: 3840)
        let output = CaptureGeometry.outputSize(
            source: source,
            maximum: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(output, PixelSize(width: 606, height: 1080))
        assertAspect(source, output)
    }

    func testUltrawideFitsWidthAndPreservesAspect() {
        let source = PixelSize(width: 5120, height: 1440)
        let output = CaptureGeometry.outputSize(
            source: source,
            maximum: PixelSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(output, PixelSize(width: 1920, height: 540))
        assertAspect(source, output)
    }

    func testPresetNeverUpscalesSmallerSource() {
        let source = PixelSize(width: 1280, height: 720)
        let output = CaptureGeometry.outputSize(
            source: source,
            maximum: PixelSize(width: 2560, height: 1440)
        )

        XCTAssertEqual(output, source)
    }

    func testNativeOddDimensionsBecomePositiveAndEven() {
        let output = CaptureGeometry.outputSize(
            source: PixelSize(width: 1919, height: 1079),
            maximum: nil
        )

        XCTAssertEqual(output, PixelSize(width: 1918, height: 1078))
        XCTAssertEqual(output.width % 2, 0)
        XCTAssertEqual(output.height % 2, 0)
    }

    func testSmallPracticalInputRemainsPositiveEvenAndDoesNotUpscale() {
        let output = CaptureGeometry.outputSize(
            source: PixelSize(width: 3, height: 2),
            maximum: PixelSize(width: 2, height: 2)
        )

        XCTAssertEqual(output, PixelSize(width: 2, height: 2))
    }

    func testOutputSizingDoesNotOverflowAtIntBoundary() {
        let output = CaptureGeometry.outputSize(
            source: PixelSize(width: Int.max, height: Int.max),
            maximum: nil
        )

        XCTAssertEqual(output, PixelSize(width: Int.max - 1, height: Int.max - 1))
    }

    func testFPSValidationClampsToSupportedRange() {
        XCTAssertEqual(CapturePreferences.normalizedFPS(-1), 1)
        XCTAssertEqual(CapturePreferences.normalizedFPS(1), 1)
        XCTAssertEqual(CapturePreferences.normalizedFPS(73), 73)
        XCTAssertEqual(CapturePreferences.normalizedFPS(120), 120)
        XCTAssertEqual(CapturePreferences.normalizedFPS(999), 120)
    }

    func testArbitraryFPSUsesMatchingSCKAndNDIMetadata() {
        let frameRate = CaptureFrameRate(73)

        XCTAssertEqual(frameRate.framesPerSecond, 73)
        XCTAssertEqual(frameRate.minimumFrameTimescale, 73)
        XCTAssertEqual(frameRate.ndiNumerator, 73)
        XCTAssertEqual(frameRate.ndiDenominator, 1)
    }

    func testPersistedZeroFPSMigratesToLegacyDefault() throws {
        let suiteName = "CaptureConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0, forKey: "fps")

        let loaded = CapturePreferences(defaults: defaults)
        XCTAssertEqual(loaded.fps, 60)
        XCTAssertEqual(defaults.integer(forKey: "fps"), 60)
    }

    func testPreferencesPersistAndCanonicalizeInvalidValues() throws {
        let suiteName = "CaptureConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(-100, forKey: "fps")
        defaults.set("custom", forKey: "resolutionCap")
        defaults.set(-100, forKey: "customResolutionWidth")
        defaults.set(100_000, forKey: "customResolutionHeight")

        let loaded = CapturePreferences(defaults: defaults)
        XCTAssertEqual(loaded.fps, 1)
        XCTAssertEqual(loaded.resolutionCap, .custom)
        XCTAssertEqual(loaded.customWidth, 2)
        XCTAssertEqual(loaded.customHeight, 16_384)
        XCTAssertEqual(CapturePreferences(defaults: defaults), loaded)
    }

    func testLegacyResolutionBooleanMigratesOnce() throws {
        let suiteName = "CaptureConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "limitTo1080p")

        let loaded = CapturePreferences(defaults: defaults)
        XCTAssertEqual(loaded.resolutionCap, .native)
        XCTAssertNil(defaults.object(forKey: "limitTo1080p"))
        XCTAssertEqual(defaults.string(forKey: "resolutionCap"), "native")
    }

    func testUnknownPersistedResolutionFallsBackDeterministically() throws {
        let suiteName = "CaptureConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-a-resolution", forKey: "resolutionCap")

        let loaded = CapturePreferences(defaults: defaults)
        XCTAssertEqual(loaded.resolutionCap, .p1080)
        XCTAssertEqual(defaults.string(forKey: "resolutionCap"), "p1080")
    }

    func testTerminationReplyGateResolvesExactlyOnce() {
        var gate = TerminationReplyGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.resolve(.timedOut))
        XCTAssertEqual(gate.resolution, .timedOut)
        XCTAssertFalse(gate.resolve(.graceful))
        XCTAssertEqual(gate.resolution, .timedOut)
    }

    func testTerminationReplyGateCannotResolveBeforeBegin() {
        var gate = TerminationReplyGate()

        XCTAssertFalse(gate.resolve(.graceful))
        XCTAssertNil(gate.resolution)
    }

    private func assertAspect(
        _ source: PixelSize,
        _ output: PixelSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sourceAspect = Double(source.width) / Double(source.height)
        let outputAspect = Double(output.width) / Double(output.height)
        XCTAssertEqual(sourceAspect, outputAspect, accuracy: 0.005, file: file, line: line)
    }
}
