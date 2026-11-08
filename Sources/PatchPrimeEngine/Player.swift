// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The player: one sound file into one strip, bus or output. A thread of its own
// decodes ahead into the mixer's feed (see ppcore.h) with macOS's audio file API,
// which also converts the file's sample rate to the engine's. Mono files play in both
// channels; files with more channels play their first two.

import AudioToolbox
import Foundation
import PPCore

final class Player: @unchecked Sendable {
    let url: URL
    let feed: OpaquePointer
    let duration: Double       // seconds
    private let rate: Double   // the engine's
    private let file: ExtAudioFileRef
    private let fileRate: Double
    private let channels: Int
    private let lock = NSLock()
    private var seekTo: Double?
    private var base = 0.0      // seconds: where the feed's audio starts
    private var looping = false
    private var stopped = false
    private var paused = false

    /// Opens url for playing at the engine's rate; nil with a reason when it can't.
    static func open(_ url: URL, rate: Double) -> (Player?, String?) {
        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &ref) == noErr, let ref else {
            return (nil, "couldn't open \(url.lastPathComponent)")
        }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &size, &format)
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        let channels = Int(max(1, format.mChannelsPerFrame))
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        guard format.mSampleRate > 0,
              ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr,
              let feed = pp_feed_create(Int32(rate)) // a second ahead
        else {
            ExtAudioFileDispose(ref)
            return (nil, "\(url.lastPathComponent) isn't a sound file macOS can play")
        }
        let player = Player(url: url, feed: feed, file: ref, fileRate: format.mSampleRate, channels: channels,
                            duration: Double(frames) / format.mSampleRate, rate: rate)
        return (player, nil)
    }

    private init(url: URL, feed: OpaquePointer, file: ExtAudioFileRef, fileRate: Double, channels: Int,
                 duration: Double, rate: Double) {
        self.url = url
        self.feed = feed
        self.file = file
        self.fileRate = fileRate
        self.channels = channels
        self.duration = duration
        self.rate = rate
    }

    var isPaused: Bool { lock.withLock { paused } }
    var isLooping: Bool { lock.withLock { looping } }

    /// Where it's playing, in seconds.
    var position: Double {
        let p = lock.withLock { base } + Double(pp_feed_played(feed)) / rate
        return duration > 0 ? (isLooping ? p.truncatingRemainder(dividingBy: duration) : min(p, duration)) : 0
    }

    var finished: Bool { pp_feed_finished(feed) != 0 }

    func setPaused(_ on: Bool) {
        lock.withLock { paused = on }
        pp_feed_set_paused(feed, on ? 1 : 0)
    }

    func setLooping(_ on: Bool) { lock.withLock { looping = on } }

    func seek(_ seconds: Double) { lock.withLock { seekTo = min(max(0, seconds), max(0, duration - 0.01)) } }

    /// Decodes on its own thread until stopped.
    func start(looping: Bool) {
        setLooping(looping)
        let thread = Thread { [self] in run() }
        thread.name = "Player"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func run() {
        let chunk = 4096
        var raw = [Float](repeating: 0, count: chunk * channels)
        var stereo = [Float](repeating: 0, count: chunk * 2)
        var pending = 0 // decoded frames in stereo not yet queued
        var pendingAt = 0
        while !lock.withLock({ stopped }) {
            if let to = lock.withLock({ () -> Double? in defer { seekTo = nil }; return seekTo }) {
                // Drop what's queued (the audio thread does it), then read from there.
                let ticket = pp_feed_flush(feed)
                let asked = Date()
                while pp_feed_flushed(feed, ticket) == 0, Date().timeIntervalSince(asked) < 0.5 {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                ExtAudioFileSeek(file, Int64(to * fileRate))
                lock.withLock { base = to }
                pending = 0
                continue
            }
            if pending == 0 {
                guard pp_feed_finished(feed) == 0 || isLooping else { // ended: wait for a seek or stop
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                var frames = UInt32(chunk)
                let status = raw.withUnsafeMutableBufferPointer { p -> OSStatus in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: UInt32(chunk * channels * 4),
                        mData: UnsafeMutableRawPointer(p.baseAddress!)))
                    return ExtAudioFileRead(file, &frames, &list)
                }
                if status != noErr || frames == 0 {
                    if isLooping, status == noErr {
                        ExtAudioFileSeek(file, 0) // again from the start, without a gap
                        continue
                    }
                    pp_feed_end(feed)
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                for f in 0..<Int(frames) {
                    let l = raw[f * channels]
                    stereo[f * 2] = l
                    stereo[f * 2 + 1] = channels > 1 ? raw[f * channels + 1] : l
                }
                pending = Int(frames)
                pendingAt = 0
            }
            let n = stereo.withUnsafeBufferPointer { p in
                Int(pp_feed_write(feed, p.baseAddress! + pendingAt * 2, Int32(pending)))
            }
            pending -= n
            pendingAt += n
            if pending > 0 { Thread.sleep(forTimeInterval: 0.01) } // full: a second is queued
        }
        ExtAudioFileDispose(file)
    }
}
