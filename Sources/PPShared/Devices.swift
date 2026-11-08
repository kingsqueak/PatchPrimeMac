// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The audio devices on this Mac, as the rest of the app sees them.

import CoreAudio
import Foundation
import IOKit

public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: AudioObjectID
    public var signature: DeviceSignature
    public var inputs: Int
    public var outputs: Int
    public var rate: Double
}

public func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectHasProperty(id, &address),
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value?.takeRetainedValue() as String?
}

func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    let list = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportName(_ id: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    switch value {
    case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    default: return "Other"
    }
}

/// Apple's USB UIDs read AppleUSBAudioEngine:Maker:Name:Serial:Port, which is the only
/// place some devices report a serial. A device with no serial of its own has its USB
/// location there instead (a radio's codec, say): that changes with the port, so it
/// isn't a serial, and such a device has none.
func serialNumber(_ id: AudioObjectID, uid: String, locations: Set<String>) -> String {
    if let serial = stringProperty(id, kAudioObjectPropertySerialNumber), !serial.isEmpty {
        return serial
    }
    let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count >= 5, parts[0] == "AppleUSBAudioEngine", parts[3].count >= 6,
       !locations.contains(parts[3].lowercased()) {
        return String(parts[3])
    }
    return ""
}

/// Every USB device's location, as the hex Apple writes into a USB audio UID.
func usbLocations() -> Set<String> {
    var found: Set<String> = []
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
        return found
    }
    defer { IOObjectRelease(iterator) }
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        if let value = IORegistryEntryCreateCFProperty(entry, "locationID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber {
            found.insert(String(value.uint32Value, radix: 16))
        }
    }
    return found
}

public func listAudioDevices() -> [AudioDeviceInfo] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    let locations = usbLocations()
    return ids.compactMap { id in
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "?"
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate)
        let signature = DeviceSignature(uid: uid, name: name, transport: transportName(id),
            serial: serialNumber(id, uid: uid, locations: locations))
        return AudioDeviceInfo(id: id, signature: signature, inputs: channels(id, kAudioObjectPropertyScopeInput),
            outputs: channels(id, kAudioObjectPropertyScopeOutput), rate: rate)
    }
}

public func deviceForUID(_ uid: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf = uid as CFString
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &cf) { pointer in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
    }
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

/// Sends a command to the driver and returns its answer.
public func driverCommand(_ text: String) -> String {
    guard let engine = deviceForUID("PatchPrimeMac.Engine") else { return "error: driver not loaded" }
    var address = AudioObjectPropertyAddress(mSelector: 0x7070_636D, // 'ppcm'
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = text as CFString
    let status = AudioObjectSetPropertyData(engine, &address, 0, nil,
        UInt32(MemoryLayout<CFString>.size), &value)
    guard status == noErr else { return "error: \(status)" }
    return stringProperty(engine, 0x7070_636D) ?? "error: no answer"
}

public func driverList() -> String {
    guard let engine = deviceForUID("PatchPrimeMac.Engine") else { return "" }
    return stringProperty(engine, 0x7070_6C73) ?? "" // 'ppls'
}

public enum DefaultKind {
    case output, input, systemOutput

    var selector: AudioObjectPropertySelector {
        switch self {
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .systemOutput: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }
}

public func defaultDevice(_ kind: DefaultKind) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: kind.selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return id
}

/// Before a default moves to one of our devices, remember the device it was on, so
/// the uninstaller can put it back. Kept in previous-defaults.txt as "<kind> <uid>"
/// lines; the first device seen for each kind is kept, not overwritten.
public func rememberDefault(_ kind: DefaultKind) {
    let current = defaultDevice(kind)
    guard current != kAudioObjectUnknown,
          let uid = stringProperty(current, kAudioDevicePropertyDeviceUID),
          !uid.hasPrefix("PatchPrimeMac.") else { return }
    let key = "\(kind)"
    let file = Store.defaultFolder.appendingPathComponent("previous-defaults.txt")
    var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init)
    lines.removeAll { $0.hasPrefix(key + " ") }
    lines.append("\(key) \(uid)")
    try? FileManager.default.createDirectory(at: Store.defaultFolder, withIntermediateDirectories: true)
    try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
}

@discardableResult
public func setDefaultDevice(_ kind: DefaultKind, _ id: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kind.selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
}

public func deviceName(_ id: AudioObjectID) -> String {
    stringProperty(id, kAudioObjectPropertyName) ?? ""
}

/// Steers the driver's clock, in parts per million from nominal.
public func setDriverRate(ppm: Double) {
    guard let engine = deviceForUID("PatchPrimeMac.Engine") else { return }
    var address = AudioObjectPropertyAddress(mSelector: 0x7070_7274, // 'pprt'
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = String(format: "%.4f", ppm) as CFString
    AudioObjectSetPropertyData(engine, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), &value)
}

// MARK: Rates and buffer sizes

public func nominalRate(_ id: AudioObjectID) -> Double {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
    return rate
}

/// The rates a device offers. Ranges count if the rate falls inside one.
public func supportsRate(_ id: AudioObjectID, _ rate: Double) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return false }
    return ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 }
}

/// Asks for a new rate and waits up to `timeout` for the device to report it, since a
/// device changes rate in its own time. Returns whether it got there.
@discardableResult
public func setNominalRate(_ id: AudioObjectID, _ rate: Double, timeout: TimeInterval = 3) -> Bool {
    if abs(nominalRate(id) - rate) < 0.5 { return true }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = rate
    guard AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value) == noErr
    else { return false }
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if abs(nominalRate(id) - rate) < 0.5 { return true }
        usleep(20_000)
    }
    return false
}

public func bufferFrames(_ id: AudioObjectID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var frames: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames)
    return Int(frames)
}

/// The buffer sizes a device allows, as a range.
public func bufferRange(_ id: AudioObjectID) -> ClosedRange<Int>? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var range = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr else { return nil }
    return Int(range.mMinimum)...Int(range.mMaximum)
}

/// Sets this process's buffer size on a device, clamped to what it allows, and
/// returns what it got. It applies to this process only; other apps keep theirs.
@discardableResult
public func setBufferFrames(_ id: AudioObjectID, _ frames: Int) -> Int {
    var wanted = frames
    if let range = bufferRange(id) { wanted = min(max(frames, range.lowerBound), range.upperBound) }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = UInt32(wanted)
    AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    return bufferFrames(id)
}
