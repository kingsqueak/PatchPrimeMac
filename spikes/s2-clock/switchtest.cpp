// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: switching outputs while the engine keeps running. This is the test
// for the failure the user wants gone.
//
//   engine IOProc on the hidden device (Patch Prime clock)
//     -> tone -> one output follower per hardware device
//     -> counting ramp -> virtual mic -> client, which proves that the engine and
//        everything else carry on, unbroken, through every switch
//
// Safety:
//  - The tone is -20 dBFS and is clipped there again just before the hardware.
//  - Only the devices listed in kAllowed can be opened. The radio is not one.
//  - It is silent unless given --audible, and refuses --audible or --buffer while
//    CASTER runs. Never test those refusals by running the real command: use
//    --guard-check, which opens no device.
//  - The -6 dBFS ramp only ever goes to the virtual device.
//  - --music makes a virtual output the system default for the run, and puts it
//    back afterwards. Music is cut by 12 dB and clipped at -6 dBFS at the hardware.
//
// switchtest [--audible] [--music] [--guard-check] [--keep-open] [--buffer N] [--switches N] [--dwell S] <device> <device>

#include "follower.h"

#include <CoreAudio/CoreAudio.h>
#include <csignal>
#include <libproc.h>
#include <unistd.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <thread>
#include <vector>

using namespace pp;

namespace {

constexpr int kEngineChannels = 32;
constexpr int kMicSlot = 1;
constexpr int kEngineBlock = 128;
constexpr double kRate = 48000;
constexpr float kToneLevel = 0.1f; // -20 dBFS
constexpr float kRampPeak = 0.5f;  // virtual device only
constexpr UInt32 kRampSteps = 1u << 20;
constexpr float kMusicGain = 0.25f;   // -12 dB
constexpr float kMusicLimit = 0.5f;   // never above -6 dBFS at the hardware
constexpr float kFadeStep = float(1.0 / (0.010 * kRate)); // 10 ms
const std::array<const char *, 2> kAllowed{"M2", "Mac Studio Speakers"};

double secondsPerTick()
{
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    return double(tb.numer) / tb.denom * 1e-9;
}
const double kSecPerTick = secondsPerTick();

// One open hardware output.
struct Follower
{
    explicit Follower(double target, double deviceSeconds)
        : controller(target, deviceSeconds)
        , target(target)
    {
    }

    Ring ringL{1 << 15};
    Ring ringR{1 << 15};
    Resampler resamplerL{32, 256};
    Resampler resamplerR{32, 256};
    RateController controller;
    double target;
    double savedPpm = 0;
    bool started = false;
    float gain = 0;
    std::atomic<float> wantGain{0};
    std::atomic<double> lastEngineSeconds{0};
    std::atomic<UInt64> underruns{0}, overruns{0}, cycles{0};
    std::atomic<UInt64> startCycle{0};
    double lastCycleSeconds = 0;
    std::atomic<UInt64> resyncs{0};
    std::atomic<double> position{0};
    std::array<std::atomic<UInt64>, 32> underrunAt{}; // cycles after the start
    std::atomic<double> ratioPpm{0};
    std::atomic<double> firstSoundSeconds{0}; // host time of the first faded-in frame
    std::atomic<bool> running{false};
    bool silent = false;
    float limit = 0;
    std::vector<float> scratchL = std::vector<float>(8192);
    std::vector<float> scratchR = std::vector<float>(8192);
};

struct Engine
{
    std::array<std::atomic<Follower *>, 2> outputs{};
    double tonePhase = 0;
    UInt32 rampNext = 0;
    bool silent = false;
    bool music = false;
    std::atomic<float> inputPeak{0};
    std::atomic<UInt64> cycles{0};
    double lastSeconds = 0;
    std::atomic<double> maxGapMs{0};
    std::atomic<double> intervalGapMs{0};
    // Sink side of the virtual mic.
    bool haveLast = false;
    UInt32 last = 0;
    std::atomic<UInt64> frames{0}, breaks{0};
};

OSStatus engineProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *e = static_cast<Engine *>(user);
    auto *output = static_cast<float *>(out->mBuffers[0].mData);
    const UInt32 frames = out->mBuffers[0].mDataByteSize / (kEngineChannels * sizeof(float));
    std::memset(output, 0, out->mBuffers[0].mDataByteSize);

    const double seconds = double(now->mHostTime) * kSecPerTick;
    if (e->lastSeconds > 0) {
        const double gap = (seconds - e->lastSeconds) * 1e3;
        if (gap > e->maxGapMs.load(std::memory_order_relaxed)) {
            e->maxGapMs.store(gap, std::memory_order_relaxed);
        }
        if (gap > e->intervalGapMs.load(std::memory_order_relaxed)) {
            e->intervalGapMs.store(gap, std::memory_order_relaxed);
        }
    }
    e->lastSeconds = seconds;

    float left[4096], right[4096];
    const UInt32 n = frames < 4096 ? frames : 4096;
    const auto *input = in->mNumberBuffers > 0 ? static_cast<const float *>(in->mBuffers[0].mData)
                                               : nullptr;
    float peak = 0;
    constexpr double kStep = 2 * M_PI * 440.0 / kRate;
    for (UInt32 f = 0; f < n; ++f) {
        if (e->music && input) { // slot 0: what apps play into the virtual output
            left[f] = kMusicGain * input[size_t(f) * kEngineChannels];
            right[f] = kMusicGain * input[size_t(f) * kEngineChannels + 1];
            peak = std::fmax(peak, std::fabs(left[f]));
        } else {
            left[f] = e->silent ? 0.0f : kToneLevel * float(std::sin(e->tonePhase));
            right[f] = left[f];
        }
        e->tonePhase += kStep;
        if (e->tonePhase > 2 * M_PI) {
            e->tonePhase -= 2 * M_PI;
        }
        const float ramp = kRampPeak * float(e->rampNext % kRampSteps) / float(kRampSteps);
        float *to = output + size_t(f) * kEngineChannels + kMicSlot * 2;
        to[0] = ramp;
        to[1] = ramp;
        ++e->rampNext;
    }
    for (auto &slot : e->outputs) {
        Follower *f = slot.load(std::memory_order_acquire);
        if (f) {
            if (f->ringL.write(left, n) < n) {
                f->overruns.fetch_add(1, std::memory_order_relaxed);
            }
            f->ringR.write(right, n);
            f->lastEngineSeconds.store(seconds, std::memory_order_release);
        }
    }
    if (peak > e->inputPeak.load(std::memory_order_relaxed)) {
        e->inputPeak.store(peak, std::memory_order_relaxed);
    }
    e->cycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

// The hardware side. Only this thread touches the resamplers and `gain`.
OSStatus deviceProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *f = static_cast<Follower *>(user);
    for (UInt32 i = 0; i < out->mNumberBuffers; ++i) {
        std::memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
    }
    if (out->mNumberBuffers == 0 || out->mBuffers[0].mNumberChannels == 0) {
        return noErr;
    }
    const int channels = int(out->mBuffers[0].mNumberChannels);
    const UInt32 frames = std::min<UInt32>(
        out->mBuffers[0].mDataByteSize / (UInt32(channels) * sizeof(float)), 8192);
    f->cycles.fetch_add(1, std::memory_order_relaxed);

    const double seconds = double(now->mHostTime) * kSecPerTick;
    if (f->lastCycleSeconds > 0 && seconds - f->lastCycleSeconds > 0.1) {
        // The device stopped and came back (sleep, a USB hiccup). The ring is stale:
        // start again from the target instead of trying to chase it.
        f->started = false;
        f->resyncs.fetch_add(1, std::memory_order_relaxed);
    }
    f->lastCycleSeconds = seconds;
    const double lastEngine = f->lastEngineSeconds.load(std::memory_order_acquire);
    if (lastEngine == 0) {
        return noErr;
    }
    const double since = (seconds - lastEngine) * kRate;
    const double fill = double(f->ringL.fill());
    if (!f->started) {
        if (fill < f->target) {
            return noErr;
        }
        f->ringL.consume(size_t(fill - f->target));
        f->ringR.consume(size_t(fill - f->target));
        const double known = f->ratioPpm.load(std::memory_order_relaxed);
        f->controller.lock(f->target + since, known != 0 ? known : f->savedPpm);
        f->started = true;
        f->startCycle.store(f->cycles.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        f->running.store(true, std::memory_order_release);
    }
    const double ratio
        = f->controller.update(double(f->ringL.fill()) + since, frames / kRate);
    const int got = f->resamplerL.process(f->ringL, f->scratchL.data(), int(frames), ratio);
    const int gotR = f->resamplerR.process(f->ringR, f->scratchR.data(), int(frames), ratio);
    if (got < int(frames)) {
        const UInt64 index = f->underruns.fetch_add(1, std::memory_order_relaxed);
        if (index < f->underrunAt.size()) {
            f->underrunAt[size_t(index)].store(
                f->cycles.load(std::memory_order_relaxed) - f->startCycle.load(std::memory_order_relaxed),
                std::memory_order_relaxed);
        }
        std::fill(f->scratchL.begin() + got, f->scratchL.begin() + frames, 0.0f);
        std::fill(f->scratchR.begin() + gotR, f->scratchR.begin() + frames, 0.0f);
    }
    f->ratioPpm.store((ratio - 1) * 1e6, std::memory_order_relaxed);
    f->position.store(double(f->ringL.fill()) + since, std::memory_order_relaxed);

    auto *samples = static_cast<float *>(out->mBuffers[0].mData);
    const float want = f->wantGain.load(std::memory_order_relaxed);
    const float limit = f->silent ? 0.0f : f->limit;
    for (UInt32 i = 0; i < frames; ++i) {
        if (f->gain < want) {
            f->gain = std::min(want, f->gain + kFadeStep);
        } else if (f->gain > want) {
            f->gain = std::max(want, f->gain - kFadeStep);
        }
        samples[size_t(i) * size_t(channels)] = std::clamp(f->scratchL[i] * f->gain, -limit, limit);
        if (channels > 1) {
            samples[size_t(i) * size_t(channels) + 1]
                = std::clamp(f->scratchR[i] * f->gain, -limit, limit);
        }
    }
    if (want > 0 && f->gain > 0 && f->firstSoundSeconds.load(std::memory_order_relaxed) == 0) {
        f->firstSoundSeconds.store(seconds, std::memory_order_release);
    }
    return noErr;
}

OSStatus clientProc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *user)
{
    auto *e = static_cast<Engine *>(user);
    const auto *samples = static_cast<const float *>(in->mBuffers[0].mData);
    const UInt32 frames = in->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    for (UInt32 f = 0; f < frames; ++f) {
        const float v = samples[f * 2];
        if (v == 0 && !e->haveLast) {
            continue;
        }
        const auto n = UInt32(double(v) / kRampPeak * kRampSteps + 0.5);
        if (e->haveLast && n != ((e->last + 1) % kRampSteps)) {
            e->breaks.fetch_add(1, std::memory_order_relaxed);
        }
        e->last = n;
        e->haveLast = true;
        e->frames.fetch_add(1, std::memory_order_relaxed);
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

AudioObjectID findOutputByName(const std::string &wanted)
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
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 streams = 0;
        AudioObjectGetPropertyDataSize(id, &st, 0, nullptr, &streams);
        if (wanted == buffer && streams > 0) {
            return id;
        }
    }
    return kAudioObjectUnknown;
}

// Fails closed: if it can't tell, it says CASTER is running.
AudioObjectID g_savedDefault = kAudioObjectUnknown;

void setDefaultOutput(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, sizeof id, &id);
}

AudioObjectID defaultOutput()
{
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID id = kAudioObjectUnknown;
    UInt32 size = sizeof id;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &id);
    return id;
}

void restoreDefault()
{
    if (g_savedDefault != kAudioObjectUnknown) {
        setDefaultOutput(g_savedDefault);
        g_savedDefault = kAudioObjectUnknown;
    }
}

void onSignal(int)
{
    restoreDefault();
    _exit(1);
}

bool casterRunning()
{
    std::vector<pid_t> pids(16384);
    // Despite what its size argument suggests, this returns a count of pids.
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

struct Output
{
    AudioObjectID id = kAudioObjectUnknown;
    std::string name;
    UInt32 buffer = 512;
    double savedPpm = 0;
    Follower *follower = nullptr;
    AudioDeviceIOProcID proc = nullptr;
};

struct Options
{
    bool silent = false;
    bool keepOpen = false;
    bool music = false;
    UInt32 buffer = 0;
    int switches = 12;
    double dwell = 3;
    int watch = 0;
};

// Opens a device and joins it to the engine. The engine carries on throughout.
void open(Engine &e, int slot, Output &o, const Options &opts)
{
    const double deviceSeconds = o.buffer / kRate;
    auto *f = new Follower(double(o.buffer) + kEngineBlock + 64, deviceSeconds);
    f->savedPpm = o.savedPpm;
    f->silent = opts.silent;
    f->limit = opts.music ? kMusicLimit : kToneLevel;
    o.follower = f;
    AudioDeviceCreateIOProcID(o.id, deviceProc, f, &o.proc);
    e.outputs[size_t(slot)].store(f, std::memory_order_release);
    AudioDeviceStart(o.id, o.proc);
}

void close(Engine &e, int slot, Output &o, std::vector<Follower *> &retired)
{
    // The device stops first: stopping its feed first starves its last cycle.
    AudioDeviceStop(o.id, o.proc);
    AudioDeviceDestroyIOProcID(o.id, o.proc);
    e.outputs[size_t(slot)].store(nullptr, std::memory_order_release);
    std::this_thread::sleep_for(std::chrono::milliseconds(10)); // past any engine cycle
    o.proc = nullptr;
    retired.push_back(o.follower); // counts are read at the end
    o.follower = nullptr;
}

} // namespace

int main(int argc, char **argv)
{
    Options opts;
    opts.silent = true;
    std::vector<std::string> names;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--audible") {
            opts.silent = false;
        } else if (a == "--guard-check") {
            std::printf("guard: CASTER %s\n", casterRunning() ? "running or unknown: sound and buffer changes refused" : "not running");
            return 0;
        } else if (a == "--music") {
            opts.music = true;
        } else if (a == "--keep-open") {
            opts.keepOpen = true;
        } else if (a == "--buffer" && i + 1 < argc) {
            opts.buffer = UInt32(std::atoi(argv[++i]));
        } else if (a == "--switches" && i + 1 < argc) {
            opts.switches = std::atoi(argv[++i]);
        } else if (a == "--watch" && i + 1 < argc) {
            opts.watch = std::atoi(argv[++i]);
        } else if (a == "--dwell" && i + 1 < argc) {
            opts.dwell = std::atof(argv[++i]);
        } else {
            names.push_back(a);
        }
    }
    if (names.size() != 2) {
        std::puts("name two devices");
        return 2;
    }
    for (const std::string &n : names) {
        if (std::find(kAllowed.begin(), kAllowed.end(), n) == kAllowed.end()) {
            std::printf("refusing device \"%s\": not on the allowed list\n", n.c_str());
            return 2;
        }
    }
    const bool caster = casterRunning();
    if (!opts.silent && caster) {
        std::puts("CASTER is running: refusing to make sound.");
        return 2;
    }
    if (opts.music && (opts.silent || caster)) {
        std::puts("--music needs --audible and CASTER closed.");
        return 2;
    }
    if (opts.buffer != 0 && caster) {
        std::puts("CASTER is running: refusing to change a device's buffer size.");
        return 2;
    }

    CFRunLoopRef none = nullptr;
    AudioObjectPropertyAddress rl{kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &rl, 0, nullptr, sizeof none, &none);

    std::array<Output, 2> outputs;
    AudioObjectPropertyAddress bf{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    for (size_t i = 0; i < 2; ++i) {
        outputs[i].name = names[i];
        outputs[i].id = findOutputByName(names[i]);
        if (outputs[i].id == kAudioObjectUnknown) {
            std::printf("not found: %s\n", names[i].c_str());
            return 1;
        }
        if (opts.buffer != 0) { // the HAL restores this when the process ends
            AudioObjectSetPropertyData(outputs[i].id, &bf, 0, nullptr, sizeof opts.buffer,
                &opts.buffer);
        }
        UInt32 s = sizeof outputs[i].buffer;
        AudioObjectGetPropertyData(outputs[i].id, &bf, 0, nullptr, &s, &outputs[i].buffer);
        // Engine frames per device frame, the inverse of the input case.
        outputs[i].savedPpm = names[i] == "M2" ? +18.4 : +3.2;
    }

    const AudioObjectID engineDevice = deviceForUID("PatchPrimeMacSpike.Engine");
    if (engineDevice == kAudioObjectUnknown) {
        std::puts("spike driver not loaded");
        return 1;
    }
    command(engineDevice, "add 1 in Spike Mic");
    AudioObjectID mic = kAudioObjectUnknown;
    for (int i = 0; i < 40 && mic == kAudioObjectUnknown; ++i) {
        mic = deviceForUID("PatchPrimeMacSpike.Slot1");
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    UInt32 engineBuffer = kEngineBlock;
    AudioObjectSetPropertyData(engineDevice, &bf, 0, nullptr, sizeof engineBuffer, &engineBuffer);
    AudioObjectSetPropertyData(mic, &bf, 0, nullptr, sizeof engineBuffer, &engineBuffer);

    AudioObjectID musicOut = kAudioObjectUnknown;
    if (opts.music) {
        command(engineDevice, "add 0 defout Spike Music");
        for (int i = 0; i < 40 && musicOut == kAudioObjectUnknown; ++i) {
            musicOut = deviceForUID("PatchPrimeMacSpike.Slot0");
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (musicOut == kAudioObjectUnknown) {
            std::puts("music device missing: is the updated driver installed?");
            return 1;
        }
        std::signal(SIGINT, onSignal);
        std::signal(SIGTERM, onSignal);
        g_savedDefault = defaultOutput();
        setDefaultOutput(musicOut);
    }

    auto *engine = new Engine;
    engine->silent = opts.silent;
    engine->music = opts.music;
    AudioDeviceIOProcID engineId{}, clientId{};
    AudioDeviceCreateIOProcID(engineDevice, engineProc, engine, &engineId);
    AudioDeviceCreateIOProcID(mic, clientProc, engine, &clientId);
    AudioDeviceStart(engineDevice, engineId);
    AudioDeviceStart(mic, clientId);
    std::this_thread::sleep_for(std::chrono::seconds(1));

    std::printf("%s, %s, %s %u / %s %u frames, %d switches, %.1f s each\n",
        opts.silent ? "SILENT" : opts.music ? "MUSIC, -12 dB, LIMITED AT -6 dBFS" : "TONE AT -20 dBFS", opts.keepOpen ? "devices kept open" : "open on demand",
        names[0].c_str(), outputs[0].buffer, names[1].c_str(), outputs[1].buffer, opts.switches,
        opts.dwell);
    std::fflush(stdout);

    std::vector<Follower *> retired;
    if (opts.keepOpen) {
        open(*engine, 0, outputs[0], opts);
        open(*engine, 1, outputs[1], opts);
        std::this_thread::sleep_for(std::chrono::seconds(2));
    }

    if (opts.watch > 0) {
        // Failure test: both outputs stay open and silent. Watches for a device
        // going away and coming back, and reopens it, while the engine carries on.
        const auto stamp = [] {
            const std::time_t t = std::time(nullptr);
            char text[32];
            std::strftime(text, sizeof text, "%H:%M:%S", std::localtime(&t));
            return std::string(text);
        };
        const auto alive = [](AudioObjectID id) {
            AudioObjectPropertyAddress a{kAudioDevicePropertyDeviceIsAlive,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            UInt32 value = 0, size = sizeof value;
            return AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value) == noErr
                && value != 0;
        };
        const auto defaultName = [] {
            AudioObjectID id = defaultOutput();
            AudioObjectPropertyAddress n{kAudioObjectPropertyName,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            CFStringRef value = nullptr;
            UInt32 s = sizeof value;
            if (AudioObjectGetPropertyData(id, &n, 0, nullptr, &s, &value) != noErr || !value) {
                return std::string("?");
            }
            char buffer[256] = {};
            CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
            CFRelease(value);
            return std::string(buffer);
        };
        std::printf("%s watching for %d s; default output %s\n", stamp().c_str(), opts.watch,
            defaultName().c_str());
        std::fflush(stdout);
        std::array<bool, 2> open_{true, true};
        std::array<UInt64, 2> lastResyncs{0, 0};
        UInt64 lastBreaks = 0;
        const auto begin = std::chrono::steady_clock::now();
        auto nextReport = begin + std::chrono::seconds(30);
        while (std::chrono::steady_clock::now() - begin < std::chrono::seconds(opts.watch)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            for (int i = 0; i < 2; ++i) {
                Output &o = outputs[size_t(i)];
                if (open_[size_t(i)] && !alive(o.id)) {
                    std::printf("%s %s GONE: engine cycles %llu, ramp breaks %llu, default output %s\n",
                        stamp().c_str(), o.name.c_str(), engine->cycles.load(),
                        engine->breaks.load(), defaultName().c_str());
                    std::fflush(stdout);
                    close(*engine, i, o, retired);
                    open_[size_t(i)] = false;
                } else if (!open_[size_t(i)]) {
                    const AudioObjectID id = findOutputByName(o.name);
                    if (id != kAudioObjectUnknown) {
                        const auto t0 = std::chrono::steady_clock::now();
                        o.id = id;
                        open(*engine, i, o, opts);
                        open_[size_t(i)] = true;
                        lastResyncs[size_t(i)] = 0;
                        for (int w = 0; w < 3000 && !o.follower->running.load(); ++w) {
                            std::this_thread::sleep_for(std::chrono::milliseconds(1));
                        }
                        std::printf("%s %s BACK: running in %.0f ms, ramp breaks %llu, default output %s\n",
                            stamp().c_str(), o.name.c_str(),
                            std::chrono::duration<double, std::milli>(
                                std::chrono::steady_clock::now() - t0).count(),
                            engine->breaks.load(), defaultName().c_str());
                        std::fflush(stdout);
                    }
                } else {
                    const UInt64 r = o.follower->resyncs.load();
                    if (r != lastResyncs[size_t(i)]) {
                        std::printf("%s %s re-locked after a gap (%llu so far)\n", stamp().c_str(),
                            o.name.c_str(), r);
                        std::fflush(stdout);
                        lastResyncs[size_t(i)] = r;
                    }
                }
            }
            const UInt64 breaks = engine->breaks.load();
            if (breaks != lastBreaks) {
                std::printf("%s ramp breaks now %llu; longest engine gap this period %.1f ms\n",
                    stamp().c_str(), breaks, engine->intervalGapMs.load());
                std::fflush(stdout);
                lastBreaks = breaks;
            }
            if (std::chrono::steady_clock::now() >= nextReport) {
                nextReport += std::chrono::seconds(opts.watch > 3600 ? 600 : 30);
                std::printf("%s", stamp().c_str());
                for (int i = 0; i < 2; ++i) {
                    const Follower *f = outputs[size_t(i)].follower;
                    if (f) {
                        std::printf("  %s %+.2f ppm pos %.0f under %llu over %llu",
                            outputs[size_t(i)].name.c_str(), f->ratioPpm.load(), f->position.load(),
                            f->underruns.load(), f->overruns.load());
                    } else {
                        std::printf("  %s closed", outputs[size_t(i)].name.c_str());
                    }
                }
                std::printf("  engine gap %.2f ms, breaks %llu\n", engine->intervalGapMs.exchange(0),
                    engine->breaks.load());
                std::fflush(stdout);
            }
        }
        for (int i = 0; i < 2; ++i) {
            if (outputs[size_t(i)].follower) {
                close(*engine, i, outputs[size_t(i)], retired);
            }
        }
        AudioDeviceStop(mic, clientId);
        AudioDeviceStop(engineDevice, engineId);
        AudioDeviceDestroyIOProcID(mic, clientId);
        AudioDeviceDestroyIOProcID(engineDevice, engineId);
        command(engineDevice, "remove 1");
        UInt64 under = 0, over = 0;
        for (const Follower *f : retired) {
            under += f->underruns.load();
            over += f->overruns.load();
        }
        std::printf("%s finished: engine cycles %llu, ramp %llu frames, %llu breaks, follower underruns %llu, overruns %llu, max gap %.2f ms\n",
            stamp().c_str(), engine->cycles.load(), engine->frames.load(), engine->breaks.load(),
            under, over, engine->maxGapMs.load());
        return 0;
    }

    std::puts(" # to                   to first sound ms   breaks so far   max engine gap ms");
    std::vector<double> times;
    int current = -1;
    const auto dwell = std::chrono::milliseconds(int(opts.dwell * 1000));
    for (int s = 0; s < opts.switches; ++s) {
        const int next = s % 2;
        Output &to = outputs[size_t(next)];
        const double t0 = double(mach_absolute_time()) * kSecPerTick;

        if (current >= 0) { // fade the old output out before the new one comes in
            Output &from = outputs[size_t(current)];
            from.follower->wantGain.store(0, std::memory_order_relaxed);
        }
        if (!opts.keepOpen) {
            open(*engine, next, to, opts);
        }
        to.follower->firstSoundSeconds.store(0, std::memory_order_release);
        to.follower->wantGain.store(1, std::memory_order_relaxed);
        for (int i = 0; i < 2000 && to.follower->firstSoundSeconds.load() == 0; ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        const double first = to.follower->firstSoundSeconds.load();
        const double ms = first > 0 ? (first - t0) * 1e3 : -1;
        times.push_back(ms);
        std::printf("%2d %-20s %17.1f %15llu %19.2f   input peak %.1f dBFS\n", s + 1,
            to.name.c_str(), ms, engine->breaks.load(), engine->maxGapMs.load(),
            20 * std::log10(double(engine->inputPeak.exchange(0)) + 1e-9));
        std::fflush(stdout);

        if (current >= 0 && !opts.keepOpen) {
            std::this_thread::sleep_for(std::chrono::milliseconds(40)); // fade finishes
            close(*engine, current, outputs[size_t(current)], retired);
        }
        current = next;
        std::this_thread::sleep_for(dwell);
    }

    outputs[size_t(current)].follower->wantGain.store(0, std::memory_order_relaxed);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    for (int i = 0; i < 2; ++i) {
        if (outputs[size_t(i)].follower) {
            close(*engine, i, outputs[size_t(i)], retired);
        }
    }
    AudioDeviceStop(mic, clientId);
    AudioDeviceStop(engineDevice, engineId);
    AudioDeviceDestroyIOProcID(mic, clientId);
    AudioDeviceDestroyIOProcID(engineDevice, engineId);
    restoreDefault();
    command(engineDevice, "remove 1");
    if (opts.music) {
        command(engineDevice, "remove 0");
    }

    UInt64 under = 0, over = 0;
    for (const Follower *f : retired) {
        under += f->underruns.load();
        over += f->overruns.load();
    }
    std::printf("underruns, in device cycles after each start:");
    for (const Follower *f : retired) {
        const UInt64 n = std::min<UInt64>(f->underruns.load(), f->underrunAt.size());
        std::printf(" [");
        for (UInt64 i = 0; i < n; ++i) {
            std::printf("%s%llu", i ? " " : "", f->underrunAt[size_t(i)].load());
        }
        std::printf("]/%llu", f->cycles.load());
    }
    std::puts("");
    std::sort(times.begin(), times.end());
    std::printf("switch to first sound: best %.1f, median %.1f, worst %.1f ms\n", times.front(),
        times[times.size() / 2], times.back());
    std::printf("engine cycles %llu, max gap %.2f ms (nominal 2.67)\n", engine->cycles.load(),
        engine->maxGapMs.load());
    std::printf("through the other path: %llu frames, %llu breaks\n", engine->frames.load(),
        engine->breaks.load());
    std::printf("followers: %llu underruns, %llu overruns\n", under, over);
    return 0;
}
