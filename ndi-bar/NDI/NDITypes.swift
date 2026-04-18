// NDITypes.swift
// Swift-side mirrors of a small subset of the NDI SDK C API.
// We only declare the types/fields we actually use; this keeps the
// Swift layer slim and avoids pulling in a bridging header.
//
// Reference: <Processing.NDI.Lib.h> from the NDI SDK for Apple.

import Foundation

// MARK: - FourCC helpers

@inline(__always)
func NDI_FOURCC(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> UInt32 {
    let aa = UInt32(a.asciiValue ?? 0)
    let bb = UInt32(b.asciiValue ?? 0)
    let cc = UInt32(c.asciiValue ?? 0)
    let dd = UInt32(d.asciiValue ?? 0)
    return aa | (bb << 8) | (cc << 16) | (dd << 24)
}

// Uncompressed video FourCCs
let NDIlib_FourCC_video_type_UYVY: UInt32 = NDI_FOURCC("U", "Y", "V", "Y")
let NDIlib_FourCC_video_type_BGRA: UInt32 = NDI_FOURCC("B", "G", "R", "A")
let NDIlib_FourCC_video_type_BGRX: UInt32 = NDI_FOURCC("B", "G", "R", "X")
let NDIlib_FourCC_video_type_RGBA: UInt32 = NDI_FOURCC("R", "G", "B", "A")
let NDIlib_FourCC_video_type_RGBX: UInt32 = NDI_FOURCC("R", "G", "B", "X")

// Audio FourCC (planar Float32, preferred for NDI 5+)
let NDIlib_FourCC_audio_type_FLTP: UInt32 = NDI_FOURCC("F", "L", "T", "p")

// MARK: - Enum constants

let NDIlib_frame_format_type_progressive: Int32 = 1
let NDIlib_frame_format_type_interleaved:  Int32 = 0

// Sentinel asking the SDK to synthesize a monotonic timecode
let NDIlib_send_timecode_synthesize: Int64 = Int64.max

// MARK: - C structs (Swift-layout matched)

/// Mirrors `NDIlib_send_create_t`.
/// We allocate the C string ourselves via strdup and free it in `cleanup()`.
struct NDIlib_send_create_t {
    var p_ndi_name: UnsafePointer<CChar>?
    var p_groups: UnsafePointer<CChar>?
    var clock_video: Bool
    var clock_audio: Bool

    init(name: String, groups: String? = nil, clockVideo: Bool = true, clockAudio: Bool = false) {
        self.p_ndi_name = UnsafePointer(strdup(name))
        self.p_groups = groups.map { UnsafePointer(strdup($0)) } ?? nil
        self.clock_video = clockVideo
        self.clock_audio = clockAudio
    }

    mutating func cleanup() {
        if let p = p_ndi_name { free(UnsafeMutableRawPointer(mutating: p)) }
        if let p = p_groups { free(UnsafeMutableRawPointer(mutating: p)) }
        p_ndi_name = nil
        p_groups = nil
    }
}

/// Mirrors `NDIlib_video_frame_v2_t`.
/// The trailing union is represented here as `line_stride_in_bytes`; we also
/// expose `data_size_in_bytes` as a computed alias for the compressed path.
struct NDIlib_video_frame_v2_t {
    var xres: Int32
    var yres: Int32
    var FourCC: UInt32
    var frame_rate_N: Int32
    var frame_rate_D: Int32
    var picture_aspect_ratio: Float
    var frame_format_type: Int32
    var timecode: Int64
    var p_data: UnsafeMutableRawPointer?
    var line_stride_in_bytes: Int32
    var p_metadata: UnsafePointer<CChar>?
    var timestamp: Int64

    var data_size_in_bytes: Int32 {
        get { line_stride_in_bytes }
        set { line_stride_in_bytes = newValue }
    }

    init(width: Int32,
         height: Int32,
         fourCC: UInt32 = NDIlib_FourCC_video_type_BGRA,
         frameRateN: Int32 = 60000,
         frameRateD: Int32 = 1000,
         strideBytes: Int32? = nil,
         data: UnsafeMutableRawPointer? = nil) {
        self.xres = width
        self.yres = height
        self.FourCC = fourCC
        self.frame_rate_N = frameRateN
        self.frame_rate_D = frameRateD
        self.picture_aspect_ratio = Float(width) / Float(max(height, 1))
        self.frame_format_type = NDIlib_frame_format_type_progressive
        self.timecode = NDIlib_send_timecode_synthesize
        self.p_data = data
        self.line_stride_in_bytes = strideBytes ?? (width * 4)
        self.p_metadata = nil
        self.timestamp = NDIlib_send_timecode_synthesize
    }
}

/// Mirrors `NDIlib_audio_frame_v3_t`.
/// For planar float audio (FLTP), `channel_stride_in_bytes` applies.
struct NDIlib_audio_frame_v3_t {
    var sample_rate: Int32
    var no_channels: Int32
    var no_samples: Int32
    var timecode: Int64
    var FourCC: UInt32
    var p_data: UnsafeMutableRawPointer?
    var channel_stride_in_bytes: Int32
    var p_metadata: UnsafePointer<CChar>?
    var timestamp: Int64

    init(sampleRate: Int32,
         channels: Int32,
         samples: Int32,
         data: UnsafeMutableRawPointer?,
         channelStrideBytes: Int32,
         fourCC: UInt32 = NDIlib_FourCC_audio_type_FLTP) {
        self.sample_rate = sampleRate
        self.no_channels = channels
        self.no_samples = samples
        self.timecode = NDIlib_send_timecode_synthesize
        self.FourCC = fourCC
        self.p_data = data
        self.channel_stride_in_bytes = channelStrideBytes
        self.p_metadata = nil
        self.timestamp = NDIlib_send_timecode_synthesize
    }
}

// MARK: - Function-pointer typealiases

typealias NDIlib_initialize_func              = @convention(c) () -> Bool
typealias NDIlib_destroy_func                 = @convention(c) () -> Void
typealias NDIlib_version_func                 = @convention(c) () -> UnsafePointer<CChar>?
typealias NDIlib_is_supported_CPU_func        = @convention(c) () -> Bool

typealias NDIlib_send_create_func             = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
typealias NDIlib_send_destroy_func            = @convention(c) (OpaquePointer?) -> Void
typealias NDIlib_send_send_video_v2_func      = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
typealias NDIlib_send_send_video_async_v2_func = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
typealias NDIlib_send_send_audio_v3_func      = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
typealias NDIlib_send_get_no_connections_func = @convention(c) (OpaquePointer?, UInt32) -> Int32
