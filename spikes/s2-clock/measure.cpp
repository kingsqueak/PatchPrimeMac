// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: real clock measurement. Opens the named output devices with an
// IOProc that writes silence, and logs each cycle's timestamps. It opens no
// inputs and changes no device setting, so it adds a silent client and nothing
// else. Only devices named on the command line are touched.
//
// measure <seconds> <outdir> "M2" "Mac Studio Speakers"

#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

struct Cycle
{
    UInt64 host;
    double sample;
    UInt32 frames;
};

struct Device
{
    AudioObjectID id = 0;
    std::string name;
    double nominal = 0;
    UInt32 buffer = 0;
    AudioDeviceIOProcID proc = nullptr;
    std::vector<Cycle> cycles;
    std::atomic<size_t> count{0};
};

OSStatus silentProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *d = static_cast<Device *>(user);
    UInt32 frames = 0;
    for (UInt32 i = 0; i < out->mNumberBuffers; ++i) {
        std::memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
        if (i == 0 && out->mBuffers[0].mNumberChannels > 0) {
            frames = out->mBuffers[0].mDataByteSize
                / (out->mBuffers[0].mNumberChannels * sizeof(Float32));
        }
    }
    const size_t n = d->count.load(std::memory_order_relaxed);
    if (n < d->cycles.size()) {
        d->cycles[n] = {now->mHostTime, now->mSampleTime, frames};
        d->count.store(n + 1, std::memory_order_release);
    }
    return noErr;
}

std::string nameOf(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
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

bool hasOutput(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size);
    return size > 0;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 4) {
        std::puts("usage: measure <seconds> <outdir> <device name>...");
        return 2;
    }
    const int seconds = std::atoi(argv[1]);
    const std::string outdir = argv[2];

    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());

    std::vector<Device *> devices;
    for (int i = 3; i < argc; ++i) {
        for (const AudioObjectID id : ids) {
            if (nameOf(id) == argv[i] && hasOutput(id)) {
                auto *d = new Device;
                d->id = id;
                d->name = argv[i];
                AudioObjectPropertyAddress p{kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                UInt32 s = sizeof d->nominal;
                AudioObjectGetPropertyData(id, &p, 0, nullptr, &s, &d->nominal);
                p.mSelector = kAudioDevicePropertyBufferFrameSize;
                s = sizeof d->buffer;
                AudioObjectGetPropertyData(id, &p, 0, nullptr, &s, &d->buffer);
                d->cycles.resize(size_t(seconds + 5) * 4000);
                devices.push_back(d);
            }
        }
    }
    if (devices.size() != size_t(argc - 3)) {
        std::puts("device not found; nothing opened");
        return 1;
    }
    for (Device *d : devices) {
        AudioDeviceCreateIOProcID(d->id, silentProc, d, &d->proc);
        AudioDeviceStart(d->id, d->proc);
        std::printf("opened %s, %.0f Hz, %u-frame buffer\n", d->name.c_str(), d->nominal, d->buffer);
    }
    std::fflush(stdout);
    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    for (Device *d : devices) {
        AudioDeviceStop(d->id, d->proc);
        AudioDeviceDestroyIOProcID(d->id, d->proc);
    }

    for (Device *d : devices) {
        std::string file = outdir + "/" + d->name + ".csv";
        for (char &c : file) {
            if (c == ' ') {
                c = '_';
            }
        }
        FILE *f = std::fopen(file.c_str(), "w");
        const size_t n = d->count.load();
        for (size_t i = 0; i < n; ++i) {
            std::fprintf(f, "%llu,%.3f,%u\n", d->cycles[i].host, d->cycles[i].sample,
                d->cycles[i].frames);
        }
        std::fclose(f);
        std::printf("%s: %zu cycles written\n", d->name.c_str(), n);
    }
    return 0;
}
