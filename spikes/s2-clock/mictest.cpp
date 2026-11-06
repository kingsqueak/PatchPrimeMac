// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: first real audio through a follower.
//   M2 inputs -> rings -> resampler -> engine IOProc -> virtual mic -> client
// It reads the M2's inputs and writes nothing to any hardware output, so this
// can't reach the amp. The output side of the M2 IOProc stays silent, and no
// device setting is changed. Audio is held in memory only for the comparison
// at the end, then dropped. Only levels and counts are printed.
//
// mictest <seconds> [saved ppm] [M2 buffer]

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

double energyOf(const float *a, size_t start, int n)
{
    double e = 0;
    for (int i = 0; i < n; ++i) {
        e += double(a[start + size_t(i)]) * a[start + size_t(i)];
    }
    return e / n;
}

// Finds the delay between the two captures and how alike they are.
void compare(const State &st)
{
    const size_t n = std::min(st.rawCap.count.load(), st.virtCap.count.load());
    if (n < 96000) {
        std::puts("comparison: too little captured");
        return;
    }
    const float *a = st.rawCap.samples.data();
    const float *b = st.virtCap.samples.data();
    // Start offset between the two captures, in frames, from their timestamps.
    const double offset = (st.virtCap.startSeconds - st.rawCap.startSeconds) * kRate;
    double best = -2;
    int bestLag = 0;
    const size_t span = n - 8192;
    double energyA = 0;
    for (size_t i = 0; i < span; ++i) {
        energyA += double(a[i + 4096]) * a[i + 4096];
    }
    for (int lag = -4096; lag < 4096; ++lag) {
        double dot = 0, energyB = 0;
        for (size_t i = 0; i < span; ++i) {
            const float y = b[size_t(int(i) + 4096 + lag)];
            dot += double(a[i + 4096]) * y;
            energyB += double(y) * y;
        }
        const double r = dot / std::sqrt(energyA * energyB + 1e-30);
        if (r > best) {
            best = r;
            bestLag = lag;
        }
    }
    // A sample at raw index i is at virtual index i + lag. The two captures start
    // `offset` frames apart, so the true delay is their sum.
    const double delay = bestLag + offset;
    std::printf("whole capture over %.1f s: correlation %.5f (includes drift of about %.1f samples)\n",
        double(span) / kRate, best, 18.4e-6 * double(span));
    std::printf("delay from M2 input to virtual mic: %.0f frames (%.1f ms)\n", delay, delay / 48.0);

    if (std::getenv("MICTEST_FINE") == nullptr) {
        return;
    }

    // Short windows, where drift is negligible, aligned to a fraction of a sample
    // with a windowed-sinc interpolator.
    constexpr int kWindow = 4800;
    constexpr int kHalf = 32;
    double worst = 0, bestResidual = -300, sum = 0;
    int windows = 0;
    size_t maxEnergyAt = 0;
    double maxEnergy = 0;
    for (size_t start = 8192; start + kWindow + 8192 < n; start += kWindow) {
        double energy = 0;
        for (int i = 0; i < kWindow; ++i) {
            energy += double(a[start + size_t(i)]) * a[start + size_t(i)];
        }
        if (energy > maxEnergy) {
            maxEnergy = energy;
            maxEnergyAt = start;
        }
        double bestForWindow = 0, bestLagForWindow = 0;
        double driftCentre = bestLag + (double(start) - double(n) / 2) * -18.4e-6;
        for (int q = -256; q <= 256; ++q) {
            const double lag = double(bestLag) + q / 32.0;
            (void)driftCentre;
            const int whole = int(std::floor(lag));
            const double frac = lag - whole;
            std::vector<float> taps(2 * kHalf);
            double tapSum = 0;
            for (int t = -kHalf + 1; t <= kHalf; ++t) {
                const double x = double(t) - frac;
                const double w = 0.5 + 0.5 * std::cos(M_PI * x / (kHalf + 1));
                const double c = (std::abs(x) < 1e-9 ? 1.0 : std::sin(M_PI * x) / (M_PI * x)) * w;
                taps[size_t(t + kHalf - 1)] = float(c);
                tapSum += c;
            }
            double dot = 0, ey = 0, ex = 0;
            for (int i = 0; i < kWindow; ++i) {
                double y = 0;
                const long base = long(start) + i + whole;
                for (int t = 0; t < 2 * kHalf; ++t) {
                    y += double(taps[size_t(t)]) * b[size_t(base + t - kHalf + 1)];
                }
                y /= tapSum;
                const double x = a[start + size_t(i)];
                dot += x * y;
                ey += y * y;
                ex += x * x;
            }
            const double r = dot / std::sqrt(ex * ey + 1e-30);
            if (r > bestForWindow) {
                bestForWindow = r;
                bestLagForWindow = lag;
            }
        }
        const double res = 10 * std::log10(std::fmax(1 - bestForWindow * bestForWindow, 1e-14));
        worst = std::fmax(worst, res);
        std::printf("  %5.2f s  lag %+8.3f  residual %6.1f dB  level %6.1f dB\n", double(start) / kRate,
            bestLagForWindow - bestLag, res, 10 * std::log10(energyOf(a, start, kWindow) + 1e-30));
        bestResidual = std::fmax(bestResidual, -res);
        sum += res;
        ++windows;
    }
    std::printf("%d 0.1 s windows: residual mean %.1f dB, worst %.1f dB, best %.1f dB\n", windows,
        sum / windows, worst, -bestResidual);
}

} // namespace

int main(int argc, char **argv)
{
    const int seconds = argc > 1 ? std::atoi(argv[1]) : 60;
    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress rl{kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof none, &none);

    auto *st = new State;
    st->savedPpm = argc > 2 ? std::atof(argv[2]) : 0.0;
    const AudioObjectID engine = deviceForUID("PatchPrimeMacSpike.Engine");
    const AudioObjectID m2 = findInputByName("M2");
    if (engine == kAudioObjectUnknown || m2 == kAudioObjectUnknown) {
        std::puts("engine or M2 not found");
        return 1;
    }
    command(engine, "add 1 in Spike Mic");
    AudioObjectID mic = kAudioObjectUnknown;
    for (int i = 0; i < 40 && mic == kAudioObjectUnknown; ++i) {
        mic = deviceForUID("PatchPrimeMacSpike.Slot1");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    UInt32 buffer = kEngineBlock;
    AudioObjectPropertyAddress bf{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(engine, &bf, 0, nullptr, sizeof buffer, &buffer);
    AudioObjectSetPropertyData(mic, &bf, 0, nullptr, sizeof buffer, &buffer);
    if (argc > 3) { // the HAL restores this when the process ends
        UInt32 wanted = UInt32(std::atoi(argv[3]));
        AudioObjectSetPropertyData(m2, &bf, 0, nullptr, sizeof wanted, &wanted);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    UInt32 m2Buffer = 0, s = sizeof m2Buffer;
    AudioObjectGetPropertyData(m2, &bf, 0, nullptr, &s, &m2Buffer);
    const double m2Target = 2.0 * m2Buffer + kEngineBlock + 32;
    st->target = m2Target;

    AudioDeviceIOProcID deviceId{}, engineId{}, clientId{};
    AudioDeviceCreateIOProcID(m2, deviceProc, st, &deviceId);
    AudioDeviceCreateIOProcID(engine, engineProc, st, &engineId);
    AudioDeviceCreateIOProcID(mic, clientProc, st, &clientId);
    AudioDeviceStart(engine, engineId);
    AudioDeviceStart(mic, clientId);
    OSStatus started = AudioDeviceStart(m2, deviceId);
    std::printf("M2 start status %d, M2 buffer %u, target %.0f frames (%.1f ms), %d s\n", started,
        m2Buffer, m2Target, m2Target / 48.0, seconds);
    std::fflush(stdout);

    std::puts("  t   raw L    raw R    virt L   virt R   ratio ppm  position  under over");
    for (int t = 5; t <= seconds; t += 5) {
        if (t == 15) {
            st->capturing.store(true);
        }
        std::this_thread::sleep_for(std::chrono::seconds(5));
        std::printf("%3d %7.1f  %7.1f  %7.1f  %7.1f  %+9.2f  %8.0f  %5llu %4llu\n", t,
            db(st->rawPeakL.exchange(0)), db(st->rawPeakR.exchange(0)),
            db(st->virtPeakL.exchange(0)), db(st->virtPeakR.exchange(0)), st->ratioPpm.load(),
            st->fill.load(), st->underruns.load(), st->overruns.load());
        std::fflush(stdout);
    }
    AudioDeviceStop(m2, deviceId);
    AudioDeviceStop(mic, clientId);
    AudioDeviceStop(engine, engineId);
    AudioDeviceDestroyIOProcID(m2, deviceId);
    AudioDeviceDestroyIOProcID(mic, clientId);
    AudioDeviceDestroyIOProcID(engine, engineId);
    command(engine, "remove 1");
    std::printf("cycles: M2 %llu, engine %llu\n", st->deviceCycles.load(), st->engineCycles.load());
    compare(*st);
    return 0;
}
