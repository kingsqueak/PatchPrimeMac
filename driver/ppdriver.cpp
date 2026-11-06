// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Manages the driver's devices from the command line.
//
// ppdriver list
// ppdriver add <slot> <out|in> <name>
// ppdriver remove <slot>
// ppdriver rename <slot> <name>
// ppdriver prepare-uninstall   moves defaults off our devices, then deletes all of them
//                              and their saved list

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <chrono>
#include <cstdio>
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

// If a default device is ours, pick a real one, so nothing points at a device that's
// about to go.
void releaseDefault(AudioObjectPropertySelector which, AudioObjectPropertyScope scope,
    const char *label)
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
    for (AudioObjectID id : ids) {
        if (!ours(id) && hasStreams(id, scope)) {
            AudioObjectSetPropertyData(kAudioObjectSystemObject, &d, 0, nullptr, sizeof id, &id);
            std::printf("%s moved to %s\n", label, stringProperty(id, kAudioObjectPropertyName).c_str());
            return;
        }
    }
    std::printf("%s: no other device to move to\n", label);
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
        releaseDefault(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeOutput, "default output");
        releaseDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeOutput, "system sounds");
        releaseDefault(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeInput, "default input");
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
