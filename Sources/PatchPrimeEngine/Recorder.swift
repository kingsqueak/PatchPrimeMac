// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Recording to files. The mixer's audio thread only copies each recorded strip's
// sound into a tap (a lock-free queue, see ppcore.h); a thread of the recording's own
// empties it and writes the file with macOS's audio file API: FLAC and WAV at 24 bits,
// or AAC. A recording after a chain's effects leaves that chain's latency off its
// start (and adds as much silence at its end), so it lines up with real time and with
// the other tracks of a take.

import AudioToolbox
import Foundation
import PPCore

enum RecordingFormat: String, CaseIterable {
    case flac, wav, aac

    var fileExtension: String { self == .aac ? "m4a" : rawValue }
    var fileType: AudioFileTypeID {
        switch self {
        case .flac: return kAudioFileFLACType
        case .wav: return kAudioFileWAVEType
        case .aac: return kAudioFileM4AType
        }
    }
    /// AAC goes up to 48 kHz.
    func allows(rate: Double) -> Bool { self != .aac || rate <= 48000 }
}

enum RecordingFiles {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/PatchPrimeMac", isDirectory: true)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    /// A label made fit for a file name.
    static func stem(_ label: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = label.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Recording" : cleaned
    }

    /// The path, or "<stem> (2).<ext>" and so on when it's taken.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let next = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}

/// One file being written from one tap.
final class Recording: @unchecked Sendable {
    let key: String          // "s0", "b1", "o2"
    let tap: OpaquePointer
    let url: URL
    let take: Bool
    private let format: RecordingFormat
    private let rate: Double
    private let channels: Int
    private let latency: Int // frames
    private let lock = NSLock()
    private var written: Int64 = 0
    private var problem: String?
    private var stopAsked: Date?
    private var closed = false
    /// Whether the mixer it's attached to is still there (the engine restarts it).
    var attached = true

    init(key: String, tap: OpaquePointer, url: URL, take: Bool, format: RecordingFormat, rate: Double,
         latency: Int) {
        self.key = key
        self.tap = tap
        self.url = url
        self.take = take
        self.format = format
        self.rate = rate
        self.channels = Int(pp_tap_channels(tap))
        self.latency = max(0, latency)
    }

    var seconds: Double { lock.withLock { rate > 0 ? Double(written) / rate : 0 } }
    var error: String? { lock.withLock { problem } }
    /// Its file is finished (written and closed, or never opened).
    var isClosed: Bool { lock.withLock { closed } }

    /// Writes on its own thread until the tap is finished, then calls done (on the
    /// main queue).
    func start(done: @escaping (Recording) -> Void) {
        let thread = Thread { [self] in
            run()
            lock.withLock { closed = true }
            DispatchQueue.main.async { done(self) }
        }
        thread.name = "Recording \(key)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stop at this block (the same block for every track of a take).
    func stop(atBlock block: UInt64) {
        lock.withLock { if stopAsked == nil { stopAsked = Date() } }
        pp_tap_stop_at(tap, block)
    }

    private func fail(_ message: String) {
        lock.withLock { if problem == nil { problem = message } }
    }

    private func run() {
        guard let file = openFile() else {
            pp_tap_end(tap)
            while pp_tap_finished(tap) == 0 { // let the queue drain, so it can be freed
                var sink = [Float](repeating: 0, count: 4096 * channels)
                if pp_tap_read(tap, &sink, 4096) == 0 { Thread.sleep(forTimeInterval: 0.02) }
            }
            return
        }
        let chunk = 4096
        var buffer = [Float](repeating: 0, count: chunk * channels)
        var skip = latency
        var idleSince = Date()
        while true {
            let n = Int(pp_tap_read(tap, &buffer, Int32(chunk)))
            if n > 0 {
                idleSince = Date()
                var start = 0
                if skip > 0 {
                    start = min(skip, n)
                    skip -= start
                }
                if n > start, !write(file, buffer, from: start, count: n - start) { break }
                continue
            }
            if pp_tap_finished(tap) != 0 { break }
            // Asked to stop, but no audio is coming (the device went away): don't wait.
            let asked = lock.withLock { stopAsked }
            if let asked, Date().timeIntervalSince(asked) > 1, Date().timeIntervalSince(idleSince) > 1 {
                pp_tap_end(tap)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // What was left off the start, as silence at the end, so every track of a take
        // has the same length. Only once something was written.
        let pad = latency - skip
        if pad > 0, lock.withLock({ written }) > 0, error == nil {
            let silence = [Float](repeating: 0, count: pad * channels)
            _ = write(file, silence, from: 0, count: pad)
        }
        ExtAudioFileDispose(file)
        // Drain anything left, in case writing failed part way.
        while pp_tap_finished(tap) == 0 {
            pp_tap_end(tap)
            if pp_tap_read(tap, &buffer, Int32(chunk)) == 0 { break }
        }
    }

    private func write(_ file: ExtAudioFileRef, _ samples: [Float], from: Int, count: Int) -> Bool {
        var samples = samples
        let status = samples.withUnsafeMutableBufferPointer { p -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * channels * 4),
                mData: UnsafeMutableRawPointer(p.baseAddress! + from * channels)))
            return ExtAudioFileWrite(file, UInt32(count), &list)
        }
        guard status == noErr else {
            fail("couldn't write \(url.lastPathComponent) (error \(status))")
            return false
        }
        lock.withLock { written += Int64(count) }
        return true
    }

    private func openFile() -> ExtAudioFileRef? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            fail("couldn't make \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
            return nil
        }
        var file = AudioStreamBasicDescription()
        file.mSampleRate = rate
        file.mChannelsPerFrame = UInt32(channels)
        switch format {
        case .wav:
            file.mFormatID = kAudioFormatLinearPCM
            file.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
            file.mBitsPerChannel = 24
            file.mFramesPerPacket = 1
            file.mBytesPerFrame = UInt32(3 * channels)
            file.mBytesPerPacket = file.mBytesPerFrame
        case .flac:
            file.mFormatID = kAudioFormatFLAC
            file.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData
        case .aac:
            file.mFormatID = kAudioFormatMPEG4AAC
        }
        if format != .wav {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &file)
        }
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, format.fileType, &file, nil,
                                               AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let ref else {
            fail("couldn't create \(url.lastPathComponent) (error \(status))")
            return nil
        }
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            ExtAudioFileDispose(ref)
            try? FileManager.default.removeItem(at: url)
            fail("couldn't set up \(url.lastPathComponent) (error \(status))")
            return nil
        }
        return ref
    }
}
