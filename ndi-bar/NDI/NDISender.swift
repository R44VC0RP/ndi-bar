// NDISender.swift
// Thin RAII wrapper around an NDI sender instance.
//
// One instance per NDI source (so one per captured display in our app).
// Not thread-safe on its own; callers synchronize on a dedicated queue.

import Foundation
import CoreVideo
import CoreMedia

final class NDISender {
    let name: String
    private let handle: OpaquePointer
    private let lib: NDILibrary

    init?(name: String, lib: NDILibrary = .shared) {
        guard lib.isLoaded else {
            NSLog("[ndi-bar] NDISender: library not loaded")
            return nil
        }
        guard let h = lib.createSender(name: name) else {
            NSLog("[ndi-bar] NDISender: createSender failed for \(name)")
            return nil
        }
        self.name = name
        self.handle = h
        self.lib = lib
    }

    deinit {
        lib.destroySender(handle)
    }

    /// Returns how many NDI receivers are currently subscribed.
    var connectionCount: Int32 {
        lib.connectionCount(handle, timeoutMs: 0)
    }

    // MARK: - Video

    /// Ships a BGRA `CVPixelBuffer` as an NDI video frame.
    /// The pixel buffer is locked for the duration of the call so this uses
    /// the synchronous send; that's simpler and fine at 60 fps on 10 GbE.
    /// We can move to `send_video_async_v2` with a double-buffered retain
    /// strategy once this is validated end-to-end.
    func sendVideo(pixelBuffer: CVPixelBuffer,
                   frameRateN: Int32 = 60000,
                   frameRateD: Int32 = 1000) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        let stride = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var frame = NDIlib_video_frame_v2_t(
            width: w,
            height: h,
            fourCC: NDIlib_FourCC_video_type_BGRA,
            frameRateN: frameRateN,
            frameRateD: frameRateD,
            strideBytes: stride,
            data: base
        )

        lib.sendVideo(handle, frame: &frame)
    }

    // MARK: - Audio

    /// Ships a CMSampleBuffer of PCM audio as planar-float NDI audio.
    /// Accepts 16-bit or float, interleaved or planar; we normalize to planar Float32.
    func sendAudio(sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, numSamples > 0 else { return }

        // Grab the AudioBufferList from the sample buffer.
        var bufferListSize: Int = 0
        var blockBuffer: CMBlockBuffer?
        let status0 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status0 == noErr, bufferListSize > 0 else { return }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawABL.deallocate() }

        let status1 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawABL.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status1 == noErr else { return }

        let ablPtr = UnsafeMutableAudioBufferListPointer(
            rawABL.assumingMemoryBound(to: AudioBufferList.self)
        )

        let isPlanar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat  = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        // Allocate a contiguous planar float buffer: [ch0 samples][ch1 samples]...
        let channelStrideBytes = numSamples * MemoryLayout<Float32>.size
        let totalBytes = channels * channelStrideBytes
        let plane = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 16)
        defer { plane.deallocate() }

        let floatPlane = plane.assumingMemoryBound(to: Float32.self)

        // Convert into planar Float32
        if isPlanar, isFloat, bitsPerChannel == 32 {
            // Already planar Float32 — copy channel by channel.
            for c in 0..<channels {
                guard c < ablPtr.count,
                      let src = ablPtr[c].mData else { continue }
                let dst = floatPlane.advanced(by: c * numSamples)
                memcpy(dst, src, min(Int(ablPtr[c].mDataByteSize), channelStrideBytes))
            }
        } else if !isPlanar, isFloat, bitsPerChannel == 32 {
            // Interleaved Float32
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Float32.self) else { return }
            for c in 0..<channels {
                let dst = floatPlane.advanced(by: c * numSamples)
                for s in 0..<numSamples {
                    dst[s] = src[s * channels + c]
                }
            }
        } else if !isPlanar, !isFloat, bitsPerChannel == 16 {
            // Interleaved Int16 — scale to [-1, 1]
            guard let src = ablPtr[0].mData?.assumingMemoryBound(to: Int16.self) else { return }
            let inv = Float32(1.0 / 32768.0)
            for c in 0..<channels {
                let dst = floatPlane.advanced(by: c * numSamples)
                for s in 0..<numSamples {
                    dst[s] = Float32(src[s * channels + c]) * inv
                }
            }
        } else {
            // Unknown layout — best effort zero and bail.
            memset(plane, 0, totalBytes)
        }

        var audio = NDIlib_audio_frame_v3_t(
            sampleRate: Int32(asbd.mSampleRate),
            channels: Int32(channels),
            samples: Int32(numSamples),
            data: plane,
            channelStrideBytes: Int32(channelStrideBytes)
        )

        lib.sendAudio(handle, frame: &audio)
    }
}
