// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The audio devices on this Mac, as the rest of the app sees them.

import CoreAudio
import Foundation

public struct AudioDeviceInfo: Sendable, Equatable {
    public var id: AudioObjectID
    public var signature: DeviceSignature
    public var inputs: Int
    public var outputs: Int
    public var rate: Double
}

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
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
/// place some devices report a serial.
func serialNumber(_ id: AudioObjectID, uid: String) -> String {
    if let serial = stringProperty(id, kAudioObjectPropertySerialNumber), !serial.isEmpty {
        return serial
    }
    let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count >= 5, parts[0] == "AppleUSBAudioEngine", parts[3].count >= 6 {
        return String(parts[3])
    }
    return ""
}

public func listAudioDevices() -> [AudioDeviceInfo] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids.compactMap { id in
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "?"
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate)
        let signature = DeviceSignature(uid: uid, name: name, transport: transportName(id),
            serial: serialNumber(id, uid: uid))
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
