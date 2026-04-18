// NDILibrary.swift
// Runtime loader for the NDI SDK's libndi.dylib.
//
// Why dlopen instead of a bridging header?
//   - The NDI SDK ships only dynamic libraries (no static linking allowed per
//     the license), and the install path is well-known.
//   - Loading dynamically keeps the Xcode project free of an Objective-C
//     bridging header and lets ndi-bar build and launch on machines that
//     haven't installed the NDI SDK yet (it surfaces a proper error instead
//     of failing at load time).
//
// On first launch we show a one-shot alert pointing the user to
// https://ndi.video/sdk if libndi.dylib can't be found.

import Foundation

final class NDILibrary {
    static let shared = NDILibrary()

    enum LoadError: Error, LocalizedError {
        case libraryMissing
        case unsupportedCPU
        case initializeFailed
        case symbolMissing(String)

        var errorDescription: String? {
            switch self {
            case .libraryMissing:
                return "Couldn't find libndi.dylib. Install the NDI SDK from https://ndi.video/sdk."
            case .unsupportedCPU:
                return "This CPU is not supported by the NDI runtime."
            case .initializeFailed:
                return "NDIlib_initialize() returned false."
            case .symbolMissing(let name):
                return "NDI symbol missing: \(name). Try reinstalling the NDI SDK."
            }
        }
    }

    // MARK: State

    private(set) var isLoaded = false
    private var handle: UnsafeMutableRawPointer?

    // Function pointers we actually call.
    fileprivate var _initialize: NDIlib_initialize_func?
    fileprivate var _destroy: NDIlib_destroy_func?
    fileprivate var _version: NDIlib_version_func?
    fileprivate var _isSupportedCPU: NDIlib_is_supported_CPU_func?
    fileprivate var _sendCreate: NDIlib_send_create_func?
    fileprivate var _sendDestroy: NDIlib_send_destroy_func?
    fileprivate var _sendVideoV2: NDIlib_send_send_video_v2_func?
    fileprivate var _sendVideoAsyncV2: NDIlib_send_send_video_async_v2_func?
    fileprivate var _sendAudioV3: NDIlib_send_send_audio_v3_func?
    fileprivate var _sendGetNoConnections: NDIlib_send_get_no_connections_func?

    // MARK: Path discovery

    private static let candidatePaths: [String] = [
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        "/Library/NDI Advanced SDK for Apple/lib/macOS/libndi_advanced.dylib",
        "/Library/NDI Advanced SDK for Apple/lib/macOS/libndi.dylib",
        "/usr/local/lib/libndi.dylib",
        "/opt/homebrew/lib/libndi.dylib",
    ]

    private init() {}

    // MARK: Load / unload

    /// Loads libndi.dylib and resolves the function pointers we need.
    /// Safe to call more than once; subsequent calls are no-ops.
    func load() throws {
        if isLoaded { return }

        for path in Self.candidatePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                handle = h
                NSLog("[ndi-bar] NDI library loaded from \(path)")
                break
            }
        }

        guard let h = handle else {
            throw LoadError.libraryMissing
        }

        try resolveSymbols(h)

        if let check = _isSupportedCPU, !check() {
            throw LoadError.unsupportedCPU
        }

        guard let initFn = _initialize, initFn() else {
            throw LoadError.initializeFailed
        }

        isLoaded = true
        if let v = version() {
            NSLog("[ndi-bar] \(v)")
        }
    }

    func unload() {
        if isLoaded {
            _destroy?()
        }
        if let h = handle {
            dlclose(h)
        }
        handle = nil
        isLoaded = false
    }

    deinit { unload() }

    // MARK: Convenience accessors

    func version() -> String? {
        guard let v = _version?() else { return nil }
        return String(cString: v)
    }

    // MARK: Symbol resolution

    private func resolveSymbols(_ h: UnsafeMutableRawPointer) throws {
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(h, name) else {
                throw LoadError.symbolMissing(name)
            }
            return unsafeBitCast(raw, to: type)
        }

        _initialize           = try sym("NDIlib_initialize",               as: NDIlib_initialize_func.self)
        _destroy              = try sym("NDIlib_destroy",                  as: NDIlib_destroy_func.self)
        _version              = try sym("NDIlib_version",                  as: NDIlib_version_func.self)
        _isSupportedCPU       = try? sym("NDIlib_is_supported_CPU",        as: NDIlib_is_supported_CPU_func.self)
        _sendCreate           = try sym("NDIlib_send_create",              as: NDIlib_send_create_func.self)
        _sendDestroy          = try sym("NDIlib_send_destroy",             as: NDIlib_send_destroy_func.self)
        _sendVideoV2          = try sym("NDIlib_send_send_video_v2",       as: NDIlib_send_send_video_v2_func.self)
        _sendVideoAsyncV2     = try sym("NDIlib_send_send_video_async_v2", as: NDIlib_send_send_video_async_v2_func.self)
        _sendAudioV3          = try sym("NDIlib_send_send_audio_v3",       as: NDIlib_send_send_audio_v3_func.self)
        _sendGetNoConnections = try sym("NDIlib_send_get_no_connections",  as: NDIlib_send_get_no_connections_func.self)
    }
}

// MARK: - Low-level send wrappers
//
// Everything below takes an `OpaquePointer` sender instance and forwards
// through the resolved function pointers. Kept small on purpose; the
// higher-level lifecycle lives in NDISender.swift.

extension NDILibrary {

    func createSender(name: String, groups: String? = nil, clockVideo: Bool = true) -> OpaquePointer? {
        guard let fn = _sendCreate else { return nil }
        var s = NDIlib_send_create_t(name: name, groups: groups, clockVideo: clockVideo)
        defer { s.cleanup() }
        return withUnsafePointer(to: &s) { fn(UnsafeRawPointer($0)) }
    }

    func destroySender(_ sender: OpaquePointer) {
        _sendDestroy?(sender)
    }

    func sendVideo(_ sender: OpaquePointer, frame: inout NDIlib_video_frame_v2_t) {
        guard let fn = _sendVideoV2 else { return }
        withUnsafePointer(to: &frame) { fn(sender, UnsafeRawPointer($0)) }
    }

    func sendVideoAsync(_ sender: OpaquePointer, frame: inout NDIlib_video_frame_v2_t) {
        guard let fn = _sendVideoAsyncV2 else { return }
        withUnsafePointer(to: &frame) { fn(sender, UnsafeRawPointer($0)) }
    }

    func sendAudio(_ sender: OpaquePointer, frame: inout NDIlib_audio_frame_v3_t) {
        guard let fn = _sendAudioV3 else { return }
        withUnsafePointer(to: &frame) { fn(sender, UnsafeRawPointer($0)) }
    }

    /// Number of currently connected receivers. Pass `timeoutMs: 0` to poll.
    func connectionCount(_ sender: OpaquePointer, timeoutMs: UInt32 = 0) -> Int32 {
        _sendGetNoConnections?(sender, timeoutMs) ?? 0
    }
}
