// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Live test of the real engine: M2 mics -> bridge -> mixer -> mix bus -> virtual mic
// -> a client, with routes changed while it runs. Reads mic levels only. It never
// enables hardware output, and fails if a single non-zero sample reached hardware.

#include "ppcore.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic<float> clientPeak{0};

OSStatus clientProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *)
{
    const auto *s = static_cast<const float *>(in->mBuffers[0].mData);
    const UInt32 n = in->mBuffers[0].mDataByteSize / sizeof(float);
    float p = 0;
    for (UInt32 i = 0; i < n; ++i) {
        p = std::fmax(p, std::fabs(s[i]));
    }
    if (p > clientPeak.load(std::memory_order_relaxed)) {
        clientPeak.store(p, std::memory_order_relaxed);
    }
    return noErr;
}

AudioObjectID byUID(const char *uid)
{
    CFStringRef cf = CFStringCreateWithCString(nullptr, uid, kCFStringEncodingUTF8);
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof id;
    AudioObjectPropertyAddress a{kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof cf, &cf, &size, &id);
    CFRelease(cf);
    return id;
}

AudioObjectID byName(const std::string &wanted)
{
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
    for (const AudioObjectID id : ids) {
        AudioObjectPropertyAddress n{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        CFStringRef v = nullptr;
        UInt32 s = sizeof v;
        if (AudioObjectGetPropertyData(id, &n, 0, nullptr, &s, &v) != noErr || !v) {
            continue;
        }
        char b[256] = {};
        CFStringGetCString(v, b, sizeof b, kCFStringEncodingUTF8);
        CFRelease(v);
        AudioObjectPropertyAddress st{kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain};
        UInt32 streams = 0;
        AudioObjectGetPropertyDataSize(id, &st, 0, nullptr, &streams);
        if (wanted == b && streams > 0) {
            return id;
        }
    }
    return kAudioObjectUnknown;
}

void command(AudioObjectID engine, const char *text)
{
    AudioObjectPropertyAddress a{'ppcm', kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef v = CFStringCreateWithCString(nullptr, text, kCFStringEncodingUTF8);
    AudioObjectSetPropertyData(engine, &a, 0, nullptr, sizeof v, &v);
    CFRelease(v);
}

double db(float v) { return v > 0 ? 20 * std::log10(double(v)) : -200; }

int failures = 0;
void check(const char *name, bool ok)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    failures += ok ? 0 : 1;
}

void pause(double seconds)
{
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
}

} // namespace

int main()
{
    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress rl{kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof none, &none);

    const AudioObjectID hidden = byUID("PatchPrimeMac.Engine");
    const AudioObjectID m2 = byName("M2");
    if (hidden == kAudioObjectUnknown || m2 == kAudioObjectUnknown) {
        std::puts("engine device or M2 missing");
        return 1;
    }
    command(hidden, "add 1 in PatchPrimeMac Test Mic");
    AudioObjectID mic = kAudioObjectUnknown;
    for (int i = 0; i < 40 && mic == kAudioObjectUnknown; ++i) {
        mic = byUID("PatchPrimeMac.Device.1");
        pause(0.05);
    }
    UInt32 buffer = 128;
    AudioObjectPropertyAddress bf{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(mic, &bf, 0, nullptr, sizeof buffer, &buffer);

    PPEngine *e = pp_engine_create(hidden, 48000, 128);
    PPMixer *m = pp_engine_mixer(e);

    // Mic 1 on strip 0, mic 2 on strip 1, both into bus 0, bus 0 to the virtual mic.
    pp_mixer_set_input_active(m, 0, 1);
    pp_mixer_set_input_active(m, 1, 1);
    pp_mixer_set_bus_active(m, 0, 1);
    pp_mixer_set_output_active(m, 0, 1);
    pp_mixer_set_input_to_bus(m, 0, 0, 0.5f);
    pp_mixer_set_input_to_bus(m, 1, 0, 0.5f);
    pp_mixer_set_bus_to_output(m, 0, 0, 1);
    pp_engine_bind_output_virtual(e, 0, 1);

    AudioDeviceIOProcID clientId{};
    AudioDeviceCreateIOProcID(mic, clientProc, nullptr, &clientId);
    AudioDeviceStart(mic, clientId);
    const int started = pp_engine_start(e);
    const int bound0 = pp_engine_bind_input_device(e, 0, m2, 0, 0, -18.4);
    const int bound1 = pp_engine_bind_input_device(e, 1, m2, 1, 1, -18.4);
    check("engine started and mics bound", started == 0 && bound0 == 0 && bound1 == 0);

    pause(6);
    PPMeter strip0 = pp_mixer_read_input_meter(m, 0);
    PPMeter strip1 = pp_mixer_read_input_meter(m, 1);
    PPMeter bus = pp_mixer_read_bus_meter(m, 0);
    clientPeak.store(0);
    pause(4);
    const float heard = clientPeak.exchange(0);
    std::printf("     strip 0 %.1f dBFS, strip 1 %.1f dBFS, bus %.1f dBFS, client %.1f dBFS, ratio %.2f ppm\n",
        db(strip0.peakLeft), db(strip1.peakLeft), db(bus.peakLeft), db(heard),
        pp_engine_input_ratio_ppm(e, 0));
    check("mics reach both strips", strip0.peakLeft > 0 && strip1.peakLeft > 0);
    check("bus reaches the virtual mic", heard > 0);
    check("input locked near the M2's rate", std::abs(pp_engine_input_ratio_ppm(e, 0) + 18.4) < 3);

    // A hardware output, routed, with hardware output never enabled.
    pp_mixer_set_output_active(m, 1, 1);
    pp_mixer_set_bus_to_output(m, 0, 1, 1);
    const int boundOut = pp_engine_bind_output_device(e, 1, m2, 0, 1, 18.4);
    pause(5);
    PPEngineStats s = pp_engine_stats(e);
    PPMeter toHardware = pp_mixer_read_output_meter(m, 1);
    std::printf("     hardware output meter %.1f dBFS inside the mixer; written to hardware %.6f; ratio %.2f ppm\n",
        db(toHardware.peakLeft), s.hardwarePeak, pp_engine_output_ratio_ppm(e, 1));
    check("hardware output bound", boundOut == 0);
    check("audio really was routed to it", toHardware.peakLeft > 0);
    check("not one non-zero sample reached hardware", s.hardwarePeak == 0.f);

    pp_engine_unbind_output(e, 1);
    pp_mixer_set_output_active(m, 1, 0);
    clientPeak.store(0);
    pause(2);
    check("removing that output left the virtual mic running", clientPeak.load() > 0);

    pp_mixer_set_input_mute(m, 0, 1);
    pp_mixer_set_input_mute(m, 1, 1);
    pause(0.3);
    clientPeak.store(0);
    pause(1.5);
    check("muting both strips silences the virtual mic", clientPeak.load() == 0.f);
    pp_mixer_set_input_mute(m, 0, 0);
    pause(2);

    s = pp_engine_stats(e);
    std::printf("     cycles %llu, underruns %llu, overruns %llu, resyncs %llu, longest gap %.2f ms, devices %d\n",
        s.cycles, s.underruns, s.overruns, s.resyncs, s.maxGapMs, s.devices);
    check("no underruns or overruns while running", s.underruns == 0 && s.overruns == 0);

    pp_engine_destroy(e);
    pause(0.5);
    clientPeak.store(0);
    pause(3);
    check("with the engine stopped, the virtual mic is silent, not replaying old audio",
        clientPeak.load() == 0.f);
    AudioDeviceStop(mic, clientId);
    AudioDeviceDestroyIOProcID(mic, clientId);
    command(hidden, "remove 1");
    std::puts(failures == 0 ? "all passed" : "FAILED");
    return failures == 0 ? 0 : 1;
}
