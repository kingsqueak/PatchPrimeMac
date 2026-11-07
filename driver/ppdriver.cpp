// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Manages the driver's devices from the command line.
//
// ppdriver list
// ppdriver add <slot> <out|in> <name>
// ppdriver remove <slot>
// ppdriver rename <slot> <name>
// ppdriver prepare-uninstall [previous-defaults.txt]
//                              moves defaults off our devices (back to the ones in the
//                              file, which the helper wrote, else built-in, else a real
//                              device), then deletes all of them and their saved list

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <chrono>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr AudioObjectPropertySelector kCommandProperty = 'ppcm';
constexpr AudioObjectPropertySelector kListProperty = 'ppls';

AudioObjectID engineDevice()
{
    CFStringRef uid = CFSTR("PatchPrimeMac.Engine");
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof id;
    AudioObjectPropertyAddress a{kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof uid, &uid, &size, &id);
    return id;
}

std::string stringProperty(AudioObjectID id, AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress a{selector, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef value = nullptr;
    UInt32 size = sizeof value;
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value) != noErr || !value) {
        return {};
    }
    char buffer[2048] = {};
    CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    CFRelease(value);
    return buffer;
}

std::string command(AudioObjectID engine, const std::string &text)
{
    AudioObjectPropertyAddress a{kCommandProperty, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef value = CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
    const OSStatus status = AudioObjectSetPropertyData(engine, &a, 0, nullptr, sizeof value, &value);
    CFRelease(value);
    if (status != noErr) {
        return "error: " + std::to_string(status);
    }
    return stringProperty(engine, kCommandProperty);
}

bool ours(AudioObjectID id)
{
    return stringProperty(id, kAudioDevicePropertyDeviceUID).rfind("PatchPrimeMac.", 0) == 0;
}

bool hasStreams(AudioObjectID id, AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress a{kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size);
    return size > 0;
}

UInt32 transportOf(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 value = 0, size = sizeof value;
    AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value);
    return value;
}

// If a default device is ours, move it so nothing points at a device that's about to
// go: to the device it was on before (from the helper's file), else a built-in one,
// else any real device, else anything that isn't ours.
void releaseDefault(AudioObjectPropertySelector which, AudioObjectPropertyScope scope,
    const char *label, const std::string &previousUID)
{
    AudioObjectPropertyAddress d{which, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    AudioObjectID current = kAudioObjectUnknown;
    UInt32 size = sizeof current;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &d, 0, nullptr, &size, &current);
    if (current == kAudioObjectUnknown || !ours(current)) {
        return;
    }
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
    AudioObjectID best = kAudioObjectUnknown;
    int bestRank = 0;
    for (AudioObjectID id : ids) {
        if (ours(id) || !hasStreams(id, scope)) {
            continue;
        }
        const UInt32 t = transportOf(id);
        int rank = 1;
        if (!previousUID.empty() && stringProperty(id, kAudioDevicePropertyDeviceUID) == previousUID) {
            rank = 4;
        } else if (t == kAudioDeviceTransportTypeBuiltIn) {
            rank = 3;
        } else if (t != kAudioDeviceTransportTypeVirtual && t != kAudioDeviceTransportTypeAggregate
            && t != kAudioDeviceTransportTypeAutoAggregate) {
            rank = 2;
        }
        if (rank > bestRank) {
            best = id;
            bestRank = rank;
        }
    }
    if (best == kAudioObjectUnknown) {
        std::printf("%s: no other device to move to\n", label);
        return;
    }
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &d, 0, nullptr, sizeof best, &best);
    std::printf("%s moved to %s%s\n", label, stringProperty(best, kAudioObjectPropertyName).c_str(),
        bestRank == 4 ? " (where it was before)" : "");
}

std::map<std::string, std::string> readPrevious(const char *path)
{
    std::map<std::string, std::string> result;
    std::ifstream in(path ? path : "");
    std::string line;
    while (std::getline(in, line)) {
        const auto space = line.find(' ');
        if (space != std::string::npos) {
            result[line.substr(0, space)] = line.substr(space + 1);
        }
    }
    return result;
}

} // namespace

int main(int argc, char **argv)
{
    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress rl{kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof none, &none);

    const std::string verb = argc > 1 ? argv[1] : "list";
    const AudioObjectID engine = engineDevice();
    if (engine == kAudioObjectUnknown) {
        std::puts(verb == "prepare-uninstall" ? "driver not loaded; nothing to prepare"
                                              : "driver not loaded");
        return verb == "prepare-uninstall" ? 0 : 1;
    }
    if (verb == "list") {
        std::puts("driver loaded");
        const std::string text = stringProperty(engine, kListProperty);
        std::fputs(text.empty() ? "no devices\n" : text.c_str(), stdout);
        return 0;
    }
    if (verb == "prepare-uninstall") {
        auto previous = readPrevious(argc > 2 ? argv[2] : nullptr);
        releaseDefault(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeOutput,
            "default output", previous["output"]);
        releaseDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeOutput,
            "system sounds", previous["systemOutput"]);
        releaseDefault(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeInput,
            "default input", previous["input"]);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        std::puts(command(engine, "reset").c_str());
        return 0;
    }
    std::string text = verb;
    for (int i = 2; i < argc; ++i) {
        text += " ";
        text += argv[i];
    }
    const std::string result = command(engine, text);
    std::puts(result.c_str());
    return result == "ok" ? 0 : 1;
}
