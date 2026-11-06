// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S1 probe. Uses only the driver's own virtual devices: it never opens
// hardware and never changes a default device. Its test signal stays at or
// below -6 dBFS, so a leak can't be loud.
//
// probe list            show whether the driver loaded, and its devices
// probe add <slot> <out|in> <name>
// probe remove <slot>
// probe loop [seconds]  run the full round trip and report continuity
//
// The loop test sends a counting ramp from a client through an output device
// to the engine, and from the engine through an input device to a client. A
// missing or repeated sample breaks the count, so a glitch from adding or
// removing a device shows as a discontinuity.

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr AudioObjectPropertySelector kCommandProperty = 'ppcm';
constexpr int kEngineChannels = 32;
constexpr float kRampPeak = 0.5f; // -6 dBFS
constexpr UInt32 kRampSteps = 1u << 20; // fits a float's 24-bit mantissa at this scale

AudioObjectID deviceForUID(const char *uid)
{
    CFStringRef cf = CFStringCreateWithCString(nullptr, uid, kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof device;
    AudioObjectPropertyAddress a{kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof cf, &cf, &size, &device);
    CFRelease(cf);
    return device;
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
    char buffer[256] = {};
    CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    CFRelease(value);
    return buffer;
}

UInt32 u32Property(AudioObjectID id, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    AudioObjectPropertyAddress a{selector, scope, kAudioObjectPropertyElementMain};
    UInt32 value = 0;
    UInt32 size = sizeof value;
    AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value);
    return value;
}

void setU32(AudioObjectID id, AudioObjectPropertySelector selector, UInt32 value)
{
    AudioObjectPropertyAddress a{selector, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(id, &a, 0, nullptr, sizeof value, &value);
}

std::string command(const std::string &text)
{
    const AudioObjectID engine = deviceForUID("PatchPrimeMacSpike.Engine");
    if (engine == kAudioObjectUnknown) {
        return "error: driver not loaded";
    }
    AudioObjectPropertyAddress a{kCommandProperty, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef value = CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
    const OSStatus status
        = AudioObjectSetPropertyData(engine, &a, 0, nullptr, sizeof value, &value);
    CFRelease(value);
    if (status != noErr) {
        return "error: set failed " + std::to_string(status);
    }
    return stringProperty(engine, kCommandProperty);
}

AudioObjectID waitForDevice(const char *uid)
{
    for (int i = 0; i < 40; ++i) {
        const AudioObjectID d = deviceForUID(uid);
        if (d != kAudioObjectUnknown) {
            return d;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return kAudioObjectUnknown;
}

int list()
{
    const AudioObjectID engine = deviceForUID("PatchPrimeMacSpike.Engine");
    if (engine == kAudioObjectUnknown) {
        std::puts("driver: NOT loaded");
        return 1;
    }
    std::printf("driver: loaded, engine device id %u\n", engine);
    std::printf("  hidden: %u  clock domain: 0x%08X  buffer frames: %u\n",
        u32Property(engine, kAudioDevicePropertyIsHidden),
        u32Property(engine, kAudioDevicePropertyClockDomain),
        u32Property(engine, kAudioDevicePropertyBufferFrameSize));
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
    bool engineListed = false;
    for (const AudioObjectID id : ids) {
        const std::string uid = stringProperty(id, kAudioDevicePropertyDeviceUID);
        engineListed = engineListed || id == engine;
        if (uid.rfind("PatchPrimeMacSpike", 0) == 0) {
            std::printf("  %s  \"%s\"  domain 0x%08X\n", uid.c_str(),
                stringProperty(id, kAudioObjectPropertyName).c_str(),
                u32Property(id, kAudioDevicePropertyClockDomain));
        }
    }
    std::printf("  engine in public device list: %s\n", engineListed ? "YES (bad)" : "no");
    return 0;
}

struct Stats
{
    std::atomic<UInt32> nextOut{0};
    std::atomic<bool> dropOne{false};
    std::atomic<UInt64> frames{0};
    std::atomic<UInt64> breaks{0};
    std::atomic<UInt64> locked{0};
    std::atomic<SInt64> latency{-1};
    std::atomic<UInt64> engineCycles{0};
    std::atomic<UInt64> engineNonSilent{0};
    bool haveLast = false;
    UInt32 last = 0;
};

// Client -> visible output device.
OSStatus sourceProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *stats = static_cast<Stats *>(user);
    auto *samples = static_cast<float *>(out->mBuffers[0].mData);
    const UInt32 frames = out->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    UInt32 n = stats->nextOut.load(std::memory_order_relaxed);
    for (UInt32 f = 0; f < frames; ++f) {
        const float v = kRampPeak * float(n % kRampSteps) / float(kRampSteps);
        samples[f * 2] = v;
        samples[f * 2 + 1] = v;
        ++n;
    }
    // Negative control: skip one sample once, to prove a break gets counted.
    if (stats->dropOne.exchange(false, std::memory_order_relaxed)) {
        ++n;
    }
    stats->nextOut.store(n, std::memory_order_relaxed);
    return noErr;
}

// Engine: copies slot A's input to slot B's output, as a mixer strip would.
struct EngineArgs
{
    Stats *stats;
    int from;
    int to;
};

OSStatus engineProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *args = static_cast<EngineArgs *>(user);
    const auto *input = static_cast<const float *>(in->mBuffers[0].mData);
    auto *output = static_cast<float *>(out->mBuffers[0].mData);
    const UInt32 frames = out->mBuffers[0].mDataByteSize / (kEngineChannels * sizeof(float));
    std::memset(output, 0, out->mBuffers[0].mDataByteSize);
    bool sound = false;
    for (UInt32 f = 0; f < frames; ++f) {
        const float *from = input + f * kEngineChannels + args->from * 2;
        float *to = output + f * kEngineChannels + args->to * 2;
        to[0] = from[0];
        to[1] = from[1];
        sound = sound || from[0] != 0;
    }
    args->stats->engineCycles.fetch_add(1, std::memory_order_relaxed);
    if (sound) {
        args->stats->engineNonSilent.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
}

// Visible input device -> client: checks that the count never breaks.
OSStatus sinkProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *user)
{
    auto *stats = static_cast<Stats *>(user);
    const auto *samples = static_cast<const float *>(in->mBuffers[0].mData);
    const UInt32 frames = in->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    for (UInt32 f = 0; f < frames; ++f) {
        const float v = samples[f * 2];
        if (v == 0 && !stats->haveLast) {
            continue;
        }
        const auto n = UInt32(double(v) / kRampPeak * kRampSteps + 0.5);
        if (stats->haveLast) {
            if (n != ((stats->last + 1) % kRampSteps)) {
                stats->breaks.fetch_add(1, std::memory_order_relaxed);
            }
        } else {
            stats->locked.store(1);
            const auto sent = stats->nextOut.load(std::memory_order_relaxed);
            stats->latency.store(SInt64(sent % kRampSteps) - SInt64(n));
        }
        stats->last = n;
        stats->haveLast = true;
        stats->frames.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
}

int loop(int seconds)
{
    constexpr int kOut = 0;
    constexpr int kIn = 1;
    constexpr int kExtra = 2;
    command("add 0 out Spike Out");
    command("add 1 in Spike In");
    const AudioObjectID engine = deviceForUID("PatchPrimeMacSpike.Engine");
    const AudioObjectID outDev = waitForDevice("PatchPrimeMacSpike.Slot0");
    const AudioObjectID inDev = waitForDevice("PatchPrimeMacSpike.Slot1");
    if (engine == kAudioObjectUnknown || outDev == kAudioObjectUnknown
        || inDev == kAudioObjectUnknown) {
        std::puts("devices missing");
        return 1;
    }
    constexpr UInt32 kBuffer = 128;
    setU32(engine, kAudioDevicePropertyBufferFrameSize, kBuffer);
    setU32(outDev, kAudioDevicePropertyBufferFrameSize, kBuffer);
    setU32(inDev, kAudioDevicePropertyBufferFrameSize, kBuffer);

    Stats stats;
    EngineArgs args{&stats, kOut, kIn};
    AudioDeviceIOProcID sourceId{}, engineId{}, sinkId{};
    AudioDeviceCreateIOProcID(outDev, sourceProc, &stats, &sourceId);
    AudioDeviceCreateIOProcID(engine, engineProc, &args, &engineId);
    AudioDeviceCreateIOProcID(inDev, sinkProc, &stats, &sinkId);
    AudioDeviceStart(engine, engineId);
    AudioDeviceStart(inDev, sinkId);
    AudioDeviceStart(outDev, sourceId);

    std::printf("running %d s at %u frames\n", seconds, kBuffer);
    const auto tick = std::chrono::seconds(1);
    for (int s = 1; s <= seconds; ++s) {
        std::this_thread::sleep_for(tick);
        if (s == 3 && std::getenv("PROBE_DROP_ONE") != nullptr) {
            stats.dropOne.store(true);
            std::puts("t=3s dropped one sample on purpose");
        }
        if (s == seconds / 3) {
            const UInt64 before = stats.breaks.load();
            std::printf("t=%ds add extra device: %s\n", s, command("add 2 out Spike Extra").c_str());
            std::this_thread::sleep_for(std::chrono::seconds(1));
            std::printf("  breaks from adding: %llu\n", stats.breaks.load() - before);
        }
        if (s == 2 * seconds / 3) {
            const UInt64 before = stats.breaks.load();
            std::printf("t=%ds remove extra device: %s\n", s, command("remove 2").c_str());
            std::this_thread::sleep_for(std::chrono::seconds(1));
            std::printf("  breaks from removing: %llu\n", stats.breaks.load() - before);
        }
    }
    (void)kExtra;

    AudioDeviceStop(outDev, sourceId);
    AudioDeviceStop(inDev, sinkId);
    AudioDeviceStop(engine, engineId);
    AudioDeviceDestroyIOProcID(outDev, sourceId);
    AudioDeviceDestroyIOProcID(inDev, sinkId);
    AudioDeviceDestroyIOProcID(engine, engineId);
    command("remove 0");
    command("remove 1");

    std::printf("engine cycles %llu, with sound %llu\n", stats.engineCycles.load(),
        stats.engineNonSilent.load());
    std::printf("received %llu frames, count breaks %llu\n", stats.frames.load(),
        stats.breaks.load());
    std::printf("round trip when locked: %lld frames (%.2f ms) at %u-frame buffers\n",
        (long long)stats.latency.load(), double(stats.latency.load()) / 48.0, kBuffer);
    return stats.locked.load() != 0 ? 0 : 1;
}

} // namespace

int main(int argc, char **argv)
{
    // Let device changes reach this process without a CFRunLoop on the main thread.
    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress a{kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, sizeof none, &none);

    const std::string verb = argc > 1 ? argv[1] : "list";
    if (verb == "list") {
        return list();
    }
    if (verb == "add" && argc >= 5) {
        std::string text = "add " + std::string(argv[2]) + " " + argv[3] + " " + argv[4];
        std::puts(command(text).c_str());
        return 0;
    }
    if (verb == "remove" && argc >= 3) {
        std::puts(command("remove " + std::string(argv[2])).c_str());
        return 0;
    }
    if (verb == "loop") {
        return loop(argc > 2 ? std::atoi(argv[2]) : 30);
    }
    std::puts("usage: probe list | add <slot> <out|in> <name> | remove <slot> | loop [seconds]");
    return 2;
}
