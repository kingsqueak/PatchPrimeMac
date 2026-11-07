// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Checks one plugin variant, the way PatchPrimeMac will run it: loaded out of process,
// set to its channels at 48 kHz, initialised, a few blocks rendered. Prints the result
// (a PluginCheck) as one line of JSON. The helper runs several of these at once and
// kills any that take too long, so a plugin that hangs or crashes harms nothing.
//
//   patchprime-scan <variant id> <version> <inputs> <outputs>

import AudioToolbox
import AVFoundation
import Foundation
import PPShared

func finish(_ check: PluginCheck) -> Never {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    if let data = try? e.encode(check), let line = String(data: data, encoding: .utf8) {
        print(line)
    }
    exit(0)
}

let args = CommandLine.arguments
guard args.count >= 3, let desc = AudioUnitCatalog.description(args[1]) else {
    FileHandle.standardError.write("usage: patchprime-scan <variant id> <version> [channels]\n".data(using: .utf8)!)
    exit(2)
}
let version = args[2]
let inCount = args.count > 3 ? UInt32(args[3]) ?? 2 : 2
let outCount = args.count > 4 ? UInt32(args[4]) ?? 2 : 2
let started = Date()

func failed(_ message: String, _ status: OSStatus = noErr) -> Never {
    var c = PluginCheck(status: .failed, version: version, message: status == noErr ? message : "\(message) (\(status))")
    c.seconds = Date().timeIntervalSince(started)
    finish(c)
}

guard let component = AudioComponentFindNext(nil, [desc]) else { failed("not installed") }

// Load it out of process, as it will run.
var unit: AudioUnit?
var loadStatus: OSStatus = noErr
let loaded = DispatchSemaphore(value: 0)
AudioComponentInstantiate(component, .loadOutOfProcess) { au, status in
    unit = au
    loadStatus = status
    loaded.signal()
}
while loaded.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
guard let au = unit else { failed("couldn't load", loadStatus) }

let inputs = inCount
let outputs = outCount
func format(_ n: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: n, mBitsPerChannel: 32, mReserved: 0)
}
var inFormat = format(inputs), outFormat = format(outputs)
let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var st = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inFormat, size)
if st != noErr { failed("won't take \(inputs) channel\(inputs == 1 ? "" : "s") in", st) }
st = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outFormat, size)
if st != noErr { failed("won't give \(outputs) channel\(outputs == 1 ? "" : "s") out", st) }
var maxFrames: UInt32 = 4096
AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)

// Input: a quiet tone, fed from here.
final class Feed { var phase = 0.0 }
let feed = Feed()
var callback = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, list in
    let f = Unmanaged<Feed>.fromOpaque(ref).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(list!)
    var phase = f.phase
    for b in buffers {
        guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
        phase = f.phase
        for i in 0..<Int(frames) {
            data[i] = Float(0.1 * sin(phase))
            phase += 2 * Double.pi * 1000 / 48000
        }
    }
    f.phase = phase
    return noErr
}, inputProcRefCon: Unmanaged.passUnretained(feed).toOpaque())
st = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
    UInt32(MemoryLayout<AURenderCallbackStruct>.size))
if st != noErr { failed("won't take its input", st) }
st = AudioUnitInitialize(au)
if st != noErr { failed("won't initialise", st) }

// A second's worth of 128-frame blocks.
let frames: UInt32 = 128
let list = AudioBufferList.allocate(maximumBuffers: Int(outputs))
let storage = (0..<Int(outputs)).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Int(frames)) }
var stamp = AudioTimeStamp()
stamp.mFlags = .sampleTimeValid
for _ in 0..<375 {
    for (i, p) in storage.enumerated() {
        list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: p)
    }
    var flags = AudioUnitRenderActionFlags()
    st = AudioUnitRender(au, &flags, &stamp, 0, frames, list.unsafeMutablePointer)
    if st != noErr { failed("won't render", st) }
    stamp.mSampleTime += Double(frames)
}

var check = PluginCheck(status: .ok, version: version)
check.inputs = Int(inputs)
check.outputs = Int(outputs)
var latency: Float64 = 0, tail: Float64 = 0
var fsize = UInt32(MemoryLayout<Float64>.size)
AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &fsize)
fsize = UInt32(MemoryLayout<Float64>.size)
AudioUnitGetProperty(au, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &fsize)
check.latencySeconds = latency
check.tailSeconds = tail
var listSize: UInt32 = 0
if AudioUnitGetPropertyInfo(au, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &listSize, nil) == noErr {
    check.parameters = Int(listSize) / MemoryLayout<AudioUnitParameterID>.size
}
var viewSize: UInt32 = 0
check.hasView = AudioUnitGetPropertyInfo(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &viewSize, nil) == noErr && viewSize > 0
check.seconds = Date().timeIntervalSince(started)
AudioUnitUninitialize(au)
AudioComponentInstanceDispose(au)
finish(check)
