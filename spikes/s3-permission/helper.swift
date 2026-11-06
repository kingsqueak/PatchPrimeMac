// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S3: the helper. Asks for the microphone, reads the M2's inputs for ten
// seconds, logs levels only, and exits, so launchd has nothing to keep running.
// Writes nothing to any output.
import AVFoundation
import CoreAudio
import Foundation

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PatchPrimeMacS3/log.txt")
try? FileManager.default.createDirectory(
    at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func log(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) pid \(getpid()) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

func describe(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

func findM2() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    for id in ids {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
            let value = name?.takeRetainedValue() as String?, value == "M2"
        else { continue }
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize)
        if streamSize > 0 { return id }
    }
    return nil
}

log("helper started: \(Bundle.main.bundlePath)")
let before = AVCaptureDevice.authorizationStatus(for: .audio)
log("mic status at start: \(describe(before))")
if before == .notDetermined {
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        log("prompt answered: granted=\(granted)")
        done.signal()
    }
    if done.wait(timeout: .now() + 120) == .timedOut { log("prompt not answered in 120 s") }
}
log("mic status now: \(describe(AVCaptureDevice.authorizationStatus(for: .audio)))")

guard let m2 = findM2() else {
    log("M2 not found")
    exit(1)
}
let lock = NSLock()
var peak: Float = 0
var callbacks = 0
var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&procID, m2, nil) { _, input, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let buffer = list.first, let data = buffer.mData else { return }
    let samples = data.assumingMemoryBound(to: Float.self)
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    var p: Float = 0
    for i in 0..<count { p = max(p, abs(samples[i])) }
    lock.lock()
    peak = max(peak, p)
    callbacks += 1
    lock.unlock()
}
log("create ioproc: \(status)")
let start = AudioDeviceStart(m2, procID)
log("start: \(start)")
Thread.sleep(forTimeInterval: 10)
AudioDeviceStop(m2, procID)
if let procID { AudioDeviceDestroyIOProcID(m2, procID) }
let db = peak > 0 ? 20 * log10(Double(peak)) : -200
log(String(format: "result: %d callbacks, peak %.1f dBFS%@", callbacks, db, peak == 0 ? " (SILENCE)" : ""))
exit(0)
