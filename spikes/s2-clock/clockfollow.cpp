// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: the M2 as the chosen clock. The topology doesn't change. The driver's
// clock is steered to the M2's measured rate, from a non-realtime thread, and the
// follower's resampler should fall towards 1:1. A counting ramp through a second
// virtual device catches any break caused by moving the clock.
//   M2 inputs -> rings -> resampler -> engine IOProc -> virtual mic -> client
// It reads the M2's inputs and writes nothing to any hardware output, so this
// can't reach the amp. The output side of the M2 IOProc stays silent, and no
// device setting is changed. Audio is held in memory only for the comparison
// at the end, then dropped. Only levels and counts are printed.
//
// clockfollow [M2 buffer]

#include "follower.h"

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

using namespace pp;

namespace {

constexpr int kEngineChannels = 32;
constexpr int kMicSlot = 1;
constexpr int kEngineBlock = 128;
constexpr double kRate = 48000;
constexpr size_t kCapture = 48000 * 5;
constexpr float kRampPeak = 0.5f; // virtual device only
constexpr UInt32 kRampSteps = 1u << 20;

double secondsPerTick()
{
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    return double(tb.numer) / tb.denom * 1e-9;
}

struct Capture
{
    std::vector<float> samples = std::vector<float>(kCapture);
    std::atomic<size_t> count{0};
    double startSeconds = 0;
};

struct State
{
    Ring micL{1 << 16};
    Ring micR{1 << 16};
    Resampler resL{32, 256};
    Resampler resR{32, 256};
    RateController controller{1184, kEngineBlock / kRate};
    double secPerTick = secondsPerTick();
    std::atomic<double> lastCycleSeconds{0};
    std::atomic<bool> haveCycle{false};
    std::atomic<UInt64> overruns{0}, underruns{0}, deviceCycles{0}, engineCycles{0};
    std::atomic<double> ratioPpm{0}, fill{0};
    std::atomic<float> rawPeakL{0}, rawPeakR{0}, virtPeakL{0}, virtPeakR{0};
    std::atomic<bool> capturing{false};
    Capture rawCap, virtCap;
    UInt32 rampNext = 0;
    bool haveLast = false;
    UInt32 last = 0;
    std::atomic<UInt64> rampFrames{0}, rampBreaks{0};
    std::atomic<UInt32> m2Seq{0}, engineSeq{0};
    std::atomic<double> m2Host{0}, m2Sample{0}, engineHost{0}, engineSample{0};
    bool started = false;
    double target = 1184;
    double savedPpm = 0;
};

void maxInto(std::atomic<float> &peak, float v)
{
    if (v > peak.load(std::memory_order_relaxed)) {
        peak.store(v, std::memory_order_relaxed);
    }
}

void capture(Capture &c, const float *stereo, UInt32 frames, double firstSeconds)
{
    size_t n = c.count.load(std::memory_order_relaxed);
    if (n == 0) {
        c.startSeconds = firstSeconds;
    }
    for (UInt32 f = 0; f < frames && n < kCapture; ++f) {
        c.samples[n++] = stereo[f * 2];
    }
    c.count.store(n, std::memory_order_release);
}

// M2 side: hands the inputs to the rings. Writes nothing to the outputs.
OSStatus deviceProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *in,
    const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *st = static_cast<State *>(user);
    for (UInt32 i = 0; i < out->mNumberBuffers; ++i) {
        std::memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
    }
    if (in->mNumberBuffers == 0 || in->mBuffers[0].mNumberChannels < 2) {
        return noErr;
    }
    const auto *samples = static_cast<const float *>(in->mBuffers[0].mData);
    const int channels = int(in->mBuffers[0].mNumberChannels);
    const UInt32 frames = in->mBuffers[0].mDataByteSize / (UInt32(channels) * sizeof(float));
    static thread_local std::vector<float> *scratch = nullptr;
    if (!scratch) {
        scratch = new std::vector<float>(8192 * 3); // first cycle only, spike
    }
    float *l = scratch->data();
    float *r = l + 8192;
    float *lr = r + 4096;
    const UInt32 n = frames < 4096 ? frames : 4096;
    float pl = 0, pr = 0;
    for (UInt32 f = 0; f < n; ++f) {
        l[f] = samples[f * size_t(channels)];
        r[f] = samples[f * size_t(channels) + 1];
        lr[f * 2] = l[f];
        lr[f * 2 + 1] = r[f];
        pl = std::fmax(pl, std::fabs(l[f]));
        pr = std::fmax(pr, std::fabs(r[f]));
    }
    maxInto(st->rawPeakL, pl);
    maxInto(st->rawPeakR, pr);
    if (st->micL.write(l, n) < n) {
        st->overruns.fetch_add(1, std::memory_order_relaxed);
    }
    st->micR.write(r, n);
    if (st->capturing.load(std::memory_order_relaxed)) {
        capture(st->rawCap, lr, n, double(inTime->mHostTime) * st->secPerTick);
    }
    st->lastCycleSeconds.store(double(now->mHostTime) * st->secPerTick, std::memory_order_release);
    st->m2Seq.fetch_add(1, std::memory_order_acq_rel);
    st->m2Host.store(double(now->mHostTime) * st->secPerTick, std::memory_order_relaxed);
    st->m2Sample.store(now->mSampleTime, std::memory_order_relaxed);
    st->m2Seq.fetch_add(1, std::memory_order_acq_rel);
    st->haveCycle.store(true, std::memory_order_release);
    st->deviceCycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

// Engine side: on the hidden device, the Patch Prime clock.
OSStatus engineProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *st = static_cast<State *>(user);
    auto *output = static_cast<float *>(out->mBuffers[0].mData);
    const UInt32 frames = out->mBuffers[0].mDataByteSize / (kEngineChannels * sizeof(float));
    std::memset(output, 0, out->mBuffers[0].mDataByteSize);
    st->engineSeq.fetch_add(1, std::memory_order_acq_rel);
    st->engineHost.store(double(now->mHostTime) * st->secPerTick, std::memory_order_relaxed);
    st->engineSample.store(now->mSampleTime, std::memory_order_relaxed);
    st->engineSeq.fetch_add(1, std::memory_order_acq_rel);
    for (UInt32 f = 0; f < frames; ++f) { // slot 2: the break detector
        const float ramp = kRampPeak * float(st->rampNext % kRampSteps) / float(kRampSteps);
        float *to = output + size_t(f) * kEngineChannels + 4;
        to[0] = ramp;
        to[1] = ramp;
        ++st->rampNext;
    }
    if (!st->haveCycle.load(std::memory_order_acquire)) {
        return noErr;
    }
    const double since = (double(now->mHostTime) * st->secPerTick
                             - st->lastCycleSeconds.load(std::memory_order_acquire))
        * kRate;
    const double ringFill = double(st->micL.fill());
    if (!st->started) {
        if (ringFill < st->target) {
            return noErr;
        }
        const auto trim = size_t(ringFill - st->target);
        st->micL.consume(trim);
        st->micR.consume(trim);
        st->controller.lock(st->target + since, st->savedPpm);
        st->started = true;
    }
    const double position = double(st->micL.fill()) + since;
    const double ratio = st->controller.update(position, frames / kRate);
    float l[4096], r[4096];
    const UInt32 n = frames < 4096 ? frames : 4096;
    const int gotL = st->resL.process(st->micL, l, int(n), ratio);
    const int gotR = st->resR.process(st->micR, r, int(n), ratio);
    if (gotL < int(n) || gotR < int(n)) {
        st->underruns.fetch_add(1, std::memory_order_relaxed);
    }
    for (int f = 0; f < int(n); ++f) {
        float *to = output + size_t(f) * kEngineChannels + kMicSlot * 2;
        to[0] = f < gotL ? l[f] : 0;
        to[1] = f < gotR ? r[f] : 0;
    }
    st->ratioPpm.store((ratio - 1) * 1e6, std::memory_order_relaxed);
    st->fill.store(position, std::memory_order_relaxed);
    st->engineCycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

// What an app recording the virtual mic receives.
OSStatus clientProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in,
    const AudioTimeStamp *inTime, AudioBufferList *, const AudioTimeStamp *, void *user)
{
    auto *st = static_cast<State *>(user);
    const auto *samples = static_cast<const float *>(in->mBuffers[0].mData);
    const UInt32 frames = in->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    float pl = 0, pr = 0;
    for (UInt32 f = 0; f < frames; ++f) {
        pl = std::fmax(pl, std::fabs(samples[f * 2]));
        pr = std::fmax(pr, std::fabs(samples[f * 2 + 1]));
    }
    maxInto(st->virtPeakL, pl);
    maxInto(st->virtPeakR, pr);
    if (st->capturing.load(std::memory_order_relaxed)) {
        capture(st->virtCap, samples, frames, double(inTime->mHostTime) * st->secPerTick);
    }
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

AudioObjectID findInputByName(const char *wanted)
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
        char buffer[256] = {};
        CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
        CFRelease(value);
        AudioObjectPropertyAddress st{kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        UInt32 streams = 0;
        AudioObjectGetPropertyDataSize(id, &st, 0, nullptr, &streams);
        if (std::string(buffer) == wanted && streams > 0) {
            return id;
        }
    }
    return kAudioObjectUnknown;
}

double db(float v)
{
    return v > 0 ? 20 * std::log10(double(v)) : -200;
}

OSStatus rampProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *user)
{
    auto *st = static_cast<State *>(user);
    const auto *samples = static_cast<const float *>(in->mBuffers[0].mData);
    const UInt32 frames = in->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    for (UInt32 f = 0; f < frames; ++f) {
        const float v = samples[f * 2];
        if (v == 0 && !st->haveLast) {
            continue;
        }
        const auto n = UInt32(double(v) / kRampPeak * kRampSteps + 0.5);
        if (st->haveLast && n != ((st->last + 1) % kRampSteps)) {
            st->rampBreaks.fetch_add(1, std::memory_order_relaxed);
        }
        st->last = n;
        st->haveLast = true;
        st->rampFrames.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
}

void setRate(AudioObjectID engine, double ppm)
{
    AudioObjectPropertyAddress a{'pprt', kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    char text[64];
    std::snprintf(text, sizeof text, "%.4f", ppm);
    CFStringRef value = CFStringCreateWithCString(nullptr, text, kCFStringEncodingUTF8);
    AudioObjectSetPropertyData(engine, &a, 0, nullptr, sizeof value, &value);
    CFRelease(value);
}

struct Mark
{
    double host;
    double sample;
};

// Rate over the last `window` seconds, in ppm from nominal.
double fitPpm(const std::vector<Mark> &points, double window)
{
    if (points.size() < 8) {
        return 0;
    }
    const double end = points.back().host;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    double n = 0;
    const double x0 = points.back().host, y0 = points.back().sample;
    for (auto it = points.rbegin(); it != points.rend() && end - it->host <= window; ++it) {
        const double x = it->host - x0, y = it->sample - y0;
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
        n += 1;
    }
    const double slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    return (slope / kRate - 1) * 1e6;
}

Mark read(std::atomic<UInt32> &seq, std::atomic<double> &host, std::atomic<double> &sample)
{
    for (;;) {
        const UInt32 a = seq.load(std::memory_order_acquire);
        const Mark p{host.load(std::memory_order_relaxed), sample.load(std::memory_order_relaxed)};
        if ((a & 1) == 0 && a == seq.load(std::memory_order_acquire)) {
            return p;
        }
    }
}

} // namespace

int main(int argc, char **argv)
{
    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress rl{kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof none, &none);

    auto *st = new State;
    st->savedPpm = -18.4;
    const AudioObjectID engine = deviceForUID("PatchPrimeMacSpike.Engine");
    const AudioObjectID m2 = findInputByName("M2");
    if (engine == kAudioObjectUnknown || m2 == kAudioObjectUnknown) {
        std::puts("engine or M2 not found");
        return 1;
    }
    setRate(engine, 0);
    command(engine, "add 1 in Spike Mic");
    command(engine, "add 2 in Spike Ramp");
    AudioObjectID mic = kAudioObjectUnknown, rampDev = kAudioObjectUnknown;
    for (int i = 0; i < 40 && (mic == kAudioObjectUnknown || rampDev == kAudioObjectUnknown); ++i) {
        mic = deviceForUID("PatchPrimeMacSpike.Slot1");
        rampDev = deviceForUID("PatchPrimeMacSpike.Slot2");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    UInt32 buffer = kEngineBlock;
    AudioObjectPropertyAddress bf{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(engine, &bf, 0, nullptr, sizeof buffer, &buffer);
    AudioObjectSetPropertyData(mic, &bf, 0, nullptr, sizeof buffer, &buffer);
    AudioObjectSetPropertyData(rampDev, &bf, 0, nullptr, sizeof buffer, &buffer);
    if (argc > 1) { // the HAL restores this when the process ends
        UInt32 wanted = UInt32(std::atoi(argv[1]));
        AudioObjectSetPropertyData(m2, &bf, 0, nullptr, sizeof wanted, &wanted);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    UInt32 m2Buffer = 0, s = sizeof m2Buffer;
    AudioObjectGetPropertyData(m2, &bf, 0, nullptr, &s, &m2Buffer);
    st->target = 2.0 * m2Buffer + kEngineBlock + 32;

    AudioDeviceIOProcID deviceId{}, engineId{}, clientId{}, rampId{};
    AudioDeviceCreateIOProcID(m2, deviceProc, st, &deviceId);
    AudioDeviceCreateIOProcID(engine, engineProc, st, &engineId);
    AudioDeviceCreateIOProcID(mic, clientProc, st, &clientId);
    AudioDeviceCreateIOProcID(rampDev, rampProc, st, &rampId);
    AudioDeviceStart(engine, engineId);
    AudioDeviceStart(mic, clientId);
    AudioDeviceStart(rampDev, rampId);
    AudioDeviceStart(m2, deviceId);
    std::printf("M2 buffer %u, target %.0f frames\n", m2Buffer, st->target);
    std::puts("   t  stage     M2 ppm  driver ppm  engine ppm  resampler ppm  position  under over breaks");

    std::vector<Mark> m2Points, enginePoints;
    double driverPpm = 0;
    UInt64 lastBreaks = 0;
    constexpr double kSlewPerSecond = 2.0; // ppm a second
    constexpr double kTick = 0.25;
    const auto start = std::chrono::steady_clock::now();
    int printed = 0;
    for (;;) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        if (t >= 170) {
            break;
        }
        m2Points.push_back(read(st->m2Seq, st->m2Host, st->m2Sample));
        enginePoints.push_back(read(st->engineSeq, st->engineHost, st->engineSample));
        const double m2Ppm = fitPpm(m2Points, 20);
        const char *stage;
        double want = driverPpm;
        if (t < 30) {
            stage = "free";
            want = 0;
        } else if (t < 100) {
            stage = "follow";
            want = m2Ppm;
        } else if (t < 130) {
            stage = "lost";
            want = 0;
        } else if (t < 150) {
            stage = "jump";
            driverPpm = m2Ppm; // on purpose: no slew
            want = driverPpm;
        } else {
            stage = "jump0";
            driverPpm = 0;
            want = 0;
        }
        const double step = kSlewPerSecond * kTick;
        const double next = driverPpm + std::fmax(-step, std::fmin(step, want - driverPpm));
        if (next != driverPpm || t >= 130) {
            driverPpm = next;
            setRate(engine, driverPpm);
        }
        if (int(t / 10) != printed) {
            printed = int(t / 10);
            const UInt64 breaks = st->rampBreaks.load();
            std::printf("%4.0f  %-7s %8.2f  %10.2f  %10.2f  %13.2f  %8.0f  %5llu %4llu %6llu\n", t, stage,
                m2Ppm, driverPpm, fitPpm(enginePoints, 8), st->ratioPpm.load(), st->fill.load(),
                st->underruns.load(), st->overruns.load(), breaks);
            lastBreaks = breaks;
            std::fflush(stdout);
        }
    }
    (void)lastBreaks;
    const UInt64 runningUnder = st->underruns.load();
    const UInt64 runningOver = st->overruns.load();
    setRate(engine, 0);
    AudioDeviceStop(m2, deviceId);
    AudioDeviceStop(mic, clientId);
    AudioDeviceStop(rampDev, rampId);
    AudioDeviceStop(engine, engineId);
    AudioDeviceDestroyIOProcID(m2, deviceId);
    AudioDeviceDestroyIOProcID(mic, clientId);
    AudioDeviceDestroyIOProcID(rampDev, rampId);
    AudioDeviceDestroyIOProcID(engine, engineId);
    command(engine, "remove 1");
    command(engine, "remove 2");
    std::printf("ramp: %llu frames, %llu breaks\n", st->rampFrames.load(), st->rampBreaks.load());
    std::printf("follower while running: %llu underruns, %llu overruns; after shutdown began: %llu more\n",
        runningUnder, runningOver, st->underruns.load() - runningUnder);
    return 0;
}
