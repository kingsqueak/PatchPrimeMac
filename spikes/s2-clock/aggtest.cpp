// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: the alternative design, for comparison. One private aggregate device
// (M2 as clock, speakers and the spike's engine device drift-corrected) with one
// IOProc doing everything, against the follower design in switchtest.
//
// Writes silence to the hardware. A counting ramp on the engine device's channels
// reaches a virtual mic, to catch any interruption. It then changes the aggregate's
// sub-device list while running, as a device being switched or unplugged would.
//
// Safety: silent always, refuses if CASTER runs (or if it can't tell), touches only
// the M2 and the speakers, and destroys the private aggregate on exit or signal.
//
// aggtest [steady seconds] [changes]

#include <CoreAudio/CoreAudio.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kEngineChannels = 32;
constexpr int kSlot = 1;
constexpr float kRampPeak = 0.5f; // virtual device only
constexpr UInt32 kRampSteps = 1u << 20;
constexpr UInt32 kBuffer = 128;

double secondsPerTick()
{
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    return double(tb.numer) / tb.denom * 1e-9;
}
const double kSecPerTick = secondsPerTick();

AudioObjectID g_aggregate = kAudioObjectUnknown;

void destroyAggregate()
{
    if (g_aggregate != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(g_aggregate);
        g_aggregate = kAudioObjectUnknown;
    }
}

void onSignal(int)
{
    destroyAggregate();
    _exit(1);
}

struct State
{
    UInt32 rampNext = 0;
    double lastSeconds = 0;
    std::atomic<double> maxGapMs{0};
    std::atomic<UInt64> cycles{0};
    std::atomic<int> engineBuffer{-1};
    bool haveLast = false;
    UInt32 last = 0;
    std::atomic<UInt64> frames{0}, breaks{0};
    std::atomic<double> lastClientSeconds{0}, maxClientGapMs{0};
};

OSStatus aggregateProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *st = static_cast<State *>(user);
    const double seconds = double(now->mHostTime) * kSecPerTick;
    if (st->lastSeconds > 0) {
        const double gap = (seconds - st->lastSeconds) * 1e3;
        if (gap > st->maxGapMs.load(std::memory_order_relaxed)) {
            st->maxGapMs.store(gap, std::memory_order_relaxed);
        }
    }
    st->lastSeconds = seconds;
    int engine = -1;
    for (UInt32 i = 0; i < out->mNumberBuffers; ++i) {
        std::memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
        if (out->mBuffers[i].mNumberChannels == kEngineChannels) {
            engine = int(i);
        }
    }
    if (engine >= 0) {
        auto *samples = static_cast<float *>(out->mBuffers[engine].mData);
        const UInt32 frames = out->mBuffers[engine].mDataByteSize / (kEngineChannels * sizeof(float));
        for (UInt32 f = 0; f < frames; ++f) {
            const float ramp = kRampPeak * float(st->rampNext % kRampSteps) / float(kRampSteps);
            float *to = samples + size_t(f) * kEngineChannels + kSlot * 2;
            to[0] = ramp;
            to[1] = ramp;
            ++st->rampNext;
        }
    }
    st->engineBuffer.store(engine, std::memory_order_relaxed);
    st->cycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

OSStatus clientProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *user)
{
    auto *st = static_cast<State *>(user);
    const auto *samples = static_cast<const float *>(in->mBuffers[0].mData);
    const UInt32 frames = in->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    const double seconds = double(now->mHostTime) * kSecPerTick;
    for (UInt32 f = 0; f < frames; ++f) {
        const float v = samples[f * 2];
        if (v == 0 && !st->haveLast) {
            continue;
        }
        const auto n = UInt32(double(v) / kRampPeak * kRampSteps + 0.5);
        if (st->haveLast && n != ((st->last + 1) % kRampSteps)) {
            st->breaks.fetch_add(1, std::memory_order_relaxed);
        }
        st->last = n;
        st->haveLast = true;
        st->frames.fetch_add(1, std::memory_order_relaxed);
    }
    (void)seconds;
    return noErr;
}

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

void command(AudioObjectID engine, const char *text)
{
    AudioObjectPropertyAddress a{'ppcm', kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef value = CFStringCreateWithCString(nullptr, text, kCFStringEncodingUTF8);
    AudioObjectSetPropertyData(engine, &a, 0, nullptr, sizeof value, &value);
    CFRelease(value);
}

std::string stringOf(CFStringRef value)
{
    char buffer[512] = {};
    CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    return buffer;
}

// UID of the output device with this exact name.
std::string uidForName(const char *wanted)
{
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
    for (const AudioObjectID id : ids) {
        AudioObjectPropertyAddress n{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        CFStringRef value = nullptr;
        UInt32 s = sizeof value;
        if (AudioObjectGetPropertyData(id, &n, 0, nullptr, &s, &value) != noErr || !value) {
            continue;
        }
        const std::string name = stringOf(value);
        CFRelease(value);
        AudioObjectPropertyAddress st{kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 streams = 0;
        AudioObjectGetPropertyDataSize(id, &st, 0, nullptr, &streams);
        if (name == wanted && streams > 0) {
            AudioObjectPropertyAddress u{kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            CFStringRef uid = nullptr;
            s = sizeof uid;
            AudioObjectGetPropertyData(id, &u, 0, nullptr, &s, &uid);
            const std::string text = stringOf(uid);
            CFRelease(uid);
            return text;
        }
    }
    return {};
}

bool casterRunning() // fails closed
{
    std::vector<pid_t> pids(16384);
    const int count = proc_listallpids(pids.data(), int(pids.size() * sizeof(pid_t)));
    if (count <= 0 || count >= int(pids.size())) {
        return true;
    }
    int named = 0;
    for (int i = 0; i < count; ++i) {
        char name[PROC_PIDPATHINFO_MAXSIZE] = {};
        if (proc_name(pids[size_t(i)], name, sizeof name) > 0) {
            ++named;
            if (std::string(name) == "CASTER") {
                return true;
            }
        }
    }
    return named == 0;
}

CFStringRef cf(const std::string &s)
{
    return CFStringCreateWithCString(nullptr, s.c_str(), kCFStringEncodingUTF8);
}

CFDictionaryRef subDevice(const std::string &uid, bool drift)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef u = cf(uid);
    CFDictionarySetValue(d, CFSTR(kAudioSubDeviceUIDKey), u);
    CFRelease(u);
    int one = drift ? 1 : 0;
    CFNumberRef n = CFNumberCreate(nullptr, kCFNumberIntType, &one);
    CFDictionarySetValue(d, CFSTR(kAudioSubDeviceDriftCompensationKey), n);
    CFRelease(n);
    return d;
}

void setSubDevices(AudioObjectID aggregate, const std::vector<std::string> &uids)
{
    CFMutableArrayRef list = CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks);
    for (const std::string &u : uids) {
        CFStringRef s = cf(u);
        CFArrayAppendValue(list, s);
        CFRelease(s);
    }
    AudioObjectPropertyAddress a{kAudioAggregateDevicePropertyFullSubDeviceList,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(aggregate, &a, 0, nullptr, sizeof list, &list);
    CFRelease(list);
}

} // namespace

int main(int argc, char **argv)
{
    const int steady = argc > 1 ? std::atoi(argv[1]) : 30;
    const int changes = argc > 2 ? std::atoi(argv[2]) : 6;
    if (casterRunning()) {
        std::puts("CASTER running or unknown: refusing.");
        return 2;
    }
    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress rl{kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof none, &none);

    const std::string m2 = uidForName("M2");
    const std::string speakers = uidForName("Mac Studio Speakers");
    const std::string engineUid = "PatchPrimeMacSpike.Engine";
    const AudioObjectID engine = deviceForUID(engineUid.c_str());
    if (m2.empty() || speakers.empty() || engine == kAudioObjectUnknown) {
        std::puts("devices missing");
        return 1;
    }
    command(engine, "add 1 in Spike Mic");
    AudioObjectID mic = kAudioObjectUnknown;
    for (int i = 0; i < 40 && mic == kAudioObjectUnknown; ++i) {
        mic = deviceForUID("PatchPrimeMacSpike.Slot1");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    std::atexit(destroyAggregate);

    CFMutableDictionaryRef desc = CFDictionaryCreateMutable(nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceNameKey), CFSTR("PatchPrimeMac Spike Aggregate"));
    CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceUIDKey), CFSTR("PatchPrimeMacSpike.Aggregate"));
    int one = 1;
    CFNumberRef yes = CFNumberCreate(nullptr, kCFNumberIntType, &one);
    CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceIsPrivateKey), yes);
    CFRelease(yes);
    CFMutableArrayRef subs = CFArrayCreateMutable(nullptr, 0, &kCFTypeArrayCallBacks);
    for (const CFDictionaryRef d :
        {subDevice(m2, false), subDevice(speakers, true), subDevice(engineUid, true)}) {
        CFArrayAppendValue(subs, d);
        CFRelease(d);
    }
    CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceSubDeviceListKey), subs);
    CFStringRef mainUid = cf(m2);
    CFDictionarySetValue(desc, CFSTR(kAudioAggregateDeviceMainSubDeviceKey), mainUid);
    CFRelease(mainUid);

    const OSStatus created = AudioHardwareCreateAggregateDevice(desc, &g_aggregate);
    CFRelease(desc);
    CFRelease(subs);
    if (created != noErr) {
        std::printf("aggregate create failed: %d\n", created);
        command(engine, "remove 1");
        return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    UInt32 buffer = kBuffer;
    AudioObjectPropertyAddress bf{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(g_aggregate, &bf, 0, nullptr, sizeof buffer, &buffer);
    AudioObjectSetPropertyData(mic, &bf, 0, nullptr, sizeof buffer, &buffer);

    auto *st = new State;
    AudioDeviceIOProcID procId{}, clientId{};
    AudioDeviceCreateIOProcID(g_aggregate, aggregateProc, st, &procId);
    AudioDeviceCreateIOProcID(mic, clientProc, st, &clientId);
    AudioDeviceStart(mic, clientId);
    AudioDeviceStart(g_aggregate, procId);
    UInt32 actual = 0, s = sizeof actual;
    AudioObjectGetPropertyData(g_aggregate, &bf, 0, nullptr, &s, &actual);
    std::this_thread::sleep_for(std::chrono::seconds(2));
    std::printf("aggregate running at %u frames, engine buffer index %d, cycles %llu\n", actual,
        st->engineBuffer.load(), st->cycles.load());

    rusage before{}, after{};
    getrusage(RUSAGE_SELF, &before);
    st->maxGapMs.store(0);
    const UInt64 cyclesBefore = st->cycles.load();
    std::this_thread::sleep_for(std::chrono::seconds(steady));
    getrusage(RUSAGE_SELF, &after);
    const auto cpu = [](const rusage &r) {
        return double(r.ru_utime.tv_sec + r.ru_stime.tv_sec)
            + double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) * 1e-6;
    };
    std::printf("steady %d s: process CPU %.2f%% of a core, %.0f voluntary switches a second, "
                "%llu cycles, max gap %.2f ms, breaks %llu\n",
        steady, 100 * (cpu(after) - cpu(before)) / steady,
        double(after.ru_nvcsw - before.ru_nvcsw) / steady, st->cycles.load() - cyclesBefore,
        st->maxGapMs.load(), st->breaks.load());
    std::fflush(stdout);

    std::puts("change                       set took ms   IO gap ms   ramp breaks added");
    const std::vector<std::string> all{m2, speakers, engineUid};
    const std::vector<std::string> without{m2, engineUid};
    for (int c = 0; c < changes; ++c) {
        const bool remove = c % 2 == 0;
        st->maxGapMs.store(0);
        const UInt64 breaksBefore = st->breaks.load();
        const auto t0 = std::chrono::steady_clock::now();
        setSubDevices(g_aggregate, remove ? without : all);
        const double took
            = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::this_thread::sleep_for(std::chrono::seconds(3));
        std::printf("%-28s %11.1f %11.2f %19llu\n", remove ? "remove speakers" : "add speakers back",
            took, st->maxGapMs.load(), st->breaks.load() - breaksBefore);
        std::fflush(stdout);
    }

    AudioDeviceStop(g_aggregate, procId);
    AudioDeviceStop(mic, clientId);
    AudioDeviceDestroyIOProcID(g_aggregate, procId);
    AudioDeviceDestroyIOProcID(mic, clientId);
    destroyAggregate();
    command(engine, "remove 1");
    std::printf("total: %llu ramp frames, %llu breaks\n", st->frames.load(), st->breaks.load());
    return 0;
}
