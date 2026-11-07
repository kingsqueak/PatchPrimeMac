// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The engine: one realtime callback on the driver's hidden device runs the mixer,
// on a clock no hardware can take away. Each hardware device has its own IOProc,
// which only moves samples through bridges, so a device that stalls or vanishes
// takes nothing else with it.
//
// Hardware outputs are muted until pp_engine_enable_hardware_output is called. That
// isn't a test feature: a bug or a bad route must not reach someone's amplifier.

#include "bridge.h"
#include "ppcore.h"

#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {

constexpr int kEngineBlock = 128;
constexpr int kDriverChannels = 32;
constexpr int kDriverSlots = kDriverChannels / 2;
constexpr int kRoutesPerDevice = 16;

double secondsPerTick()
{
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    return double(tb.numer) / tb.denom * 1e-9;
}

// Reads channel `c` across a device's buffers, interleaved or not.
inline bool findChannel(const AudioBufferList *list, int c, float *&data, int &stride)
{
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer &buffer = list->mBuffers[b];
        const int channels = int(buffer.mNumberChannels);
        if (c < channels) {
            data = static_cast<float *>(buffer.mData) + c;
            stride = channels;
            return true;
        }
        c -= channels;
    }
    return false;
}

struct Route
{
    pp::Bridge bridge;
    int left;
    int right;

    Route(double rate, int producer, int consumer, double ppm, int l, int r)
        : bridge(rate, producer, consumer, ppm)
        , left(l)
        , right(r)
    {
    }
};

} // namespace

struct PPDevice
{
    PPEngine *engine = nullptr;
    AudioObjectID id = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    UInt32 block = 512;
    std::array<std::atomic<Route *>, kRoutesPerDevice> inputs{};
    std::array<std::atomic<Route *>, kRoutesPerDevice> outputs{};
    std::atomic<uint64_t> cycles{0};
    std::atomic<float> writtenPeak{0};
    // This device's clock, for steering the engine's: a seqlock, written once a cycle.
    std::atomic<uint32_t> markSeq{0};
    std::atomic<double> markSeconds{0};
    std::atomic<double> markSample{0};
};

struct PPEngine
{
    PPMixer *mixer = nullptr;
    double rate = 48000;
    double secPerTick = secondsPerTick();
    AudioObjectID hidden = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    std::atomic<bool> hardwareEnabled{false};
    std::atomic<float> outputLimit{0.5f};

    std::array<std::atomic<Route *>, PP_MAX_INPUTS> inputBridge{};
    std::array<std::atomic<Route *>, PP_MAX_OUTPUTS> outputBridge{};
    std::array<std::atomic<int>, PP_MAX_INPUTS> inputSlot{};
    std::array<std::atomic<int>, PP_MAX_OUTPUTS> outputSlot{};

    std::atomic<uint64_t> cycles{0};
    std::atomic<double> maxGapMs{0};
    double lastSeconds = 0;

    std::mutex control; // never touched by audio threads
    std::vector<std::unique_ptr<PPDevice>> devices;

    PPDevice *deviceFor(AudioObjectID id);
    void waitCycles(PPDevice *d);
    void stopDeviceIfIdle(PPDevice *d);
};

namespace {

OSStatus deviceProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *d = static_cast<PPDevice *>(user);
    const double seconds = double(now->mHostTime) * d->engine->secPerTick;
    d->markSeq.fetch_add(1, std::memory_order_acq_rel);
    d->markSeconds.store(seconds, std::memory_order_relaxed);
    d->markSample.store(now->mSampleTime, std::memory_order_relaxed);
    d->markSeq.fetch_add(1, std::memory_order_acq_rel);
    for (UInt32 i = 0; i < out->mNumberBuffers; ++i) {
        std::memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
    }
    float left[PP_MAX_BLOCK], right[PP_MAX_BLOCK];
    for (auto &slot : d->inputs) {
        Route *r = slot.load(std::memory_order_acquire);
        if (!r || in->mNumberBuffers == 0) {
            continue;
        }
        float *lData, *rData;
        int lStride, rStride;
        if (!findChannel(in, r->left, lData, lStride) || !findChannel(in, r->right, rData, rStride)) {
            continue;
        }
        const int channels = int(in->mBuffers[0].mNumberChannels);
        const int frames = std::min(int(in->mBuffers[0].mDataByteSize / (UInt32(channels) * sizeof(float))),
            int(PP_MAX_BLOCK));
        for (int f = 0; f < frames; ++f) {
            left[f] = lData[size_t(f) * size_t(lStride)];
            right[f] = rData[size_t(f) * size_t(rStride)];
        }
        r->bridge.write(left, right, frames, seconds);
    }
    const bool enabled = d->engine->hardwareEnabled.load(std::memory_order_relaxed);
    const float limit = d->engine->outputLimit.load(std::memory_order_relaxed);
    for (auto &slot : d->outputs) {
        Route *r = slot.load(std::memory_order_acquire);
        if (!r || out->mNumberBuffers == 0) {
            continue;
        }
        float *lData, *rData;
        int lStride, rStride;
        if (!findChannel(out, r->left, lData, lStride) || !findChannel(out, r->right, rData, rStride)) {
            continue;
        }
        const int channels = int(out->mBuffers[0].mNumberChannels);
        const int frames = std::min(int(out->mBuffers[0].mDataByteSize / (UInt32(channels) * sizeof(float))),
            int(PP_MAX_BLOCK));
        r->bridge.read(left, right, frames, seconds);
        if (!enabled) {
            continue; // the zeros above stand
        }
        float peak = 0;
        for (int f = 0; f < frames; ++f) {
            const float l = std::fmax(-limit, std::fmin(limit, left[f]));
            const float rr = std::fmax(-limit, std::fmin(limit, right[f]));
            lData[size_t(f) * size_t(lStride)] += l;
            rData[size_t(f) * size_t(rStride)] += rr;
            peak = std::fmax(peak, std::fmax(std::fabs(l), std::fabs(rr)));
        }
        if (peak > d->writtenPeak.load(std::memory_order_relaxed)) {
            d->writtenPeak.store(peak, std::memory_order_relaxed);
        }
    }
    d->cycles.fetch_add(1, std::memory_order_release);
    return noErr;
}

OSStatus engineProc(AudioObjectID, const AudioTimeStamp *now, const AudioBufferList *in,
    const AudioTimeStamp *, AudioBufferList *out, const AudioTimeStamp *, void *user)
{
    auto *e = static_cast<PPEngine *>(user);
    const double seconds = double(now->mHostTime) * e->secPerTick;
    if (e->lastSeconds > 0) {
        const double gap = (seconds - e->lastSeconds) * 1e3;
        if (gap > e->maxGapMs.load(std::memory_order_relaxed)) {
            e->maxGapMs.store(gap, std::memory_order_relaxed);
        }
    }
    e->lastSeconds = seconds;

    auto *output = static_cast<float *>(out->mBuffers[0].mData);
    const auto *input = in->mNumberBuffers > 0 ? static_cast<const float *>(in->mBuffers[0].mData)
                                               : nullptr;
    const int frames = std::min(int(out->mBuffers[0].mDataByteSize / (kDriverChannels * sizeof(float))),
        int(PP_MAX_BLOCK));
    std::memset(output, 0, out->mBuffers[0].mDataByteSize);

    for (int i = 0; i < PP_MAX_INPUTS; ++i) {
        float *l = pp_mixer_input_left(e->mixer, i);
        float *r = pp_mixer_input_right(e->mixer, i);
        const int slot = e->inputSlot[size_t(i)].load(std::memory_order_relaxed);
        Route *route = e->inputBridge[size_t(i)].load(std::memory_order_acquire);
        if (slot >= 0 && input) { // apps playing into a virtual device
            const float *from = input + slot * 2;
            for (int f = 0; f < frames; ++f) {
                l[f] = from[size_t(f) * kDriverChannels];
                r[f] = from[size_t(f) * kDriverChannels + 1];
            }
        } else if (route) {
            route->bridge.read(l, r, frames, seconds);
        }
    }
    pp_mixer_process(e->mixer, frames);
    for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
        const float *l = pp_mixer_output_left(e->mixer, o);
        const float *r = pp_mixer_output_right(e->mixer, o);
        const int slot = e->outputSlot[size_t(o)].load(std::memory_order_relaxed);
        Route *route = e->outputBridge[size_t(o)].load(std::memory_order_acquire);
        if (slot >= 0) { // what apps record from a virtual mic
            float *to = output + slot * 2;
            for (int f = 0; f < frames; ++f) {
                to[size_t(f) * kDriverChannels] += l[f];
                to[size_t(f) * kDriverChannels + 1] += r[f];
            }
        } else if (route) {
            route->bridge.write(l, r, frames, seconds);
        }
    }
    e->cycles.fetch_add(1, std::memory_order_release);
    return noErr;
}

UInt32 deviceBlock(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 value = 512, size = sizeof value;
    AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value);
    return value;
}

} // namespace

PPDevice *PPEngine::deviceFor(AudioObjectID id)
{
    for (auto &d : devices) {
        if (d->id == id) {
            return d.get();
        }
    }
    auto device = std::make_unique<PPDevice>();
    device->engine = this;
    device->id = id;
    device->block = deviceBlock(id);
    if (AudioDeviceCreateIOProcID(id, deviceProc, device.get(), &device->proc) != noErr) {
        return nullptr;
    }
    if (AudioDeviceStart(id, device->proc) != noErr) {
        AudioDeviceDestroyIOProcID(id, device->proc);
        return nullptr;
    }
    devices.push_back(std::move(device));
    return devices.back().get();
}

// Waits until both audio threads are past anything they could have been reading.
void PPEngine::waitCycles(PPDevice *d)
{
    const uint64_t engineStart = cycles.load(std::memory_order_acquire);
    const uint64_t deviceStart = d ? d->cycles.load(std::memory_order_acquire) : 0;
    for (int i = 0; i < 500; ++i) {
        const bool engineDone = cycles.load(std::memory_order_acquire) >= engineStart + 2;
        const bool deviceDone = !d || d->cycles.load(std::memory_order_acquire) >= deviceStart + 2;
        if (engineDone && deviceDone) {
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}

void PPEngine::stopDeviceIfIdle(PPDevice *d)
{
    for (const auto &r : d->inputs) {
        if (r.load()) {
            return;
        }
    }
    for (const auto &r : d->outputs) {
        if (r.load()) {
            return;
        }
    }
    AudioDeviceStop(d->id, d->proc);
    AudioDeviceDestroyIOProcID(d->id, d->proc);
    for (auto it = devices.begin(); it != devices.end(); ++it) {
        if (it->get() == d) {
            devices.erase(it);
            break;
        }
    }
}

extern "C" {

PPEngine *pp_engine_create(unsigned int hiddenDevice, double sampleRate)
{
    auto *e = new PPEngine;
    e->mixer = pp_mixer_create(sampleRate);
    e->rate = sampleRate;
    e->hidden = hiddenDevice;
    for (auto &s : e->inputSlot) {
        s.store(-1);
    }
    for (auto &s : e->outputSlot) {
        s.store(-1);
    }
    return e;
}

PPMixer *pp_engine_mixer(PPEngine *e) { return e->mixer; }

int pp_engine_start(PPEngine *e)
{
    UInt32 block = kEngineBlock;
    AudioObjectPropertyAddress a{kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectSetPropertyData(e->hidden, &a, 0, nullptr, sizeof block, &block);
    OSStatus status = AudioDeviceCreateIOProcID(e->hidden, engineProc, e, &e->proc);
    if (status == noErr) {
        status = AudioDeviceStart(e->hidden, e->proc);
    }
    return int(status);
}

void pp_engine_enable_hardware_output(PPEngine *e, int enabled, float limit)
{
    e->outputLimit.store(limit);
    e->hardwareEnabled.store(enabled != 0);
}

void pp_engine_bind_input_virtual(PPEngine *e, int input, int slot)
{
    e->inputSlot[size_t(input)].store(slot);
}

void pp_engine_bind_output_virtual(PPEngine *e, int output, int slot)
{
    e->outputSlot[size_t(output)].store(slot);
}

static int freeSlot(std::array<std::atomic<Route *>, kRoutesPerDevice> &slots)
{
    for (int i = 0; i < kRoutesPerDevice; ++i) {
        if (!slots[size_t(i)].load()) {
            return i;
        }
    }
    return -1;
}

int pp_engine_bind_input_device(PPEngine *e, int input, unsigned int device, int left, int right,
    double savedPpm)
{
    std::lock_guard lock(e->control);
    PPDevice *d = e->deviceFor(device);
    if (!d) {
        return -1;
    }
    const int slot = freeSlot(d->inputs);
    if (slot < 0) {
        return -2;
    }
    auto *r = new Route(e->rate, int(d->block), kEngineBlock, savedPpm, left, right);
    d->inputs[size_t(slot)].store(r, std::memory_order_release);
    e->inputBridge[size_t(input)].store(r, std::memory_order_release);
    return 0;
}

int pp_engine_bind_output_device(PPEngine *e, int output, unsigned int device, int left, int right,
    double savedPpm)
{
    std::lock_guard lock(e->control);
    PPDevice *d = e->deviceFor(device);
    if (!d) {
        return -1;
    }
    const int slot = freeSlot(d->outputs);
    if (slot < 0) {
        return -2;
    }
    auto *r = new Route(e->rate, kEngineBlock, int(d->block), savedPpm, left, right);
    d->outputs[size_t(slot)].store(r, std::memory_order_release);
    e->outputBridge[size_t(output)].store(r, std::memory_order_release);
    return 0;
}

void pp_engine_unbind_input(PPEngine *e, int input)
{
    std::lock_guard lock(e->control);
    Route *r = e->inputBridge[size_t(input)].exchange(nullptr);
    e->inputSlot[size_t(input)].store(-1);
    if (!r) {
        return;
    }
    for (auto &d : e->devices) {
        for (auto &s : d->inputs) {
            if (s.load() == r) {
                s.store(nullptr);
                PPDevice *device = d.get();
                e->waitCycles(device);
                delete r;
                e->stopDeviceIfIdle(device);
                return;
            }
        }
    }
}

void pp_engine_unbind_output(PPEngine *e, int output)
{
    std::lock_guard lock(e->control);
    Route *r = e->outputBridge[size_t(output)].exchange(nullptr);
    e->outputSlot[size_t(output)].store(-1);
    if (!r) {
        return;
    }
    for (auto &d : e->devices) {
        for (auto &s : d->outputs) {
            if (s.load() == r) {
                s.store(nullptr);
                PPDevice *device = d.get();
                e->waitCycles(device);
                delete r;
                e->stopDeviceIfIdle(device);
                return;
            }
        }
    }
}

// A device is gone: its IOProc will never run again, so don't wait for it.
void pp_engine_device_lost(PPEngine *e, unsigned int device)
{
    std::lock_guard lock(e->control);
    for (auto it = e->devices.begin(); it != e->devices.end(); ++it) {
        PPDevice *d = it->get();
        if (d->id != device) {
            continue;
        }
        std::vector<Route *> doomed;
        for (auto &s : d->inputs) {
            if (Route *r = s.exchange(nullptr)) {
                doomed.push_back(r);
                for (auto &b : e->inputBridge) {
                    Route *expected = r;
                    b.compare_exchange_strong(expected, nullptr);
                }
            }
        }
        for (auto &s : d->outputs) {
            if (Route *r = s.exchange(nullptr)) {
                doomed.push_back(r);
                for (auto &b : e->outputBridge) {
                    Route *expected = r;
                    b.compare_exchange_strong(expected, nullptr);
                }
            }
        }
        AudioDeviceStop(d->id, d->proc);
        AudioDeviceDestroyIOProcID(d->id, d->proc);
        e->waitCycles(nullptr);
        for (Route *r : doomed) {
            delete r;
        }
        e->devices.erase(it);
        return;
    }
}

PPEngineStats pp_engine_stats(PPEngine *e)
{
    std::lock_guard lock(e->control);
    PPEngineStats s{};
    s.cycles = e->cycles.load();
    s.maxGapMs = e->maxGapMs.load();
    s.devices = int(e->devices.size());
    for (const auto &d : e->devices) {
        s.hardwarePeak = std::fmax(s.hardwarePeak, d->writtenPeak.load());
        for (const auto *list : {&d->inputs, &d->outputs}) {
            for (const auto &slot : *list) {
                if (const Route *r = slot.load()) {
                    s.underruns += r->bridge.underruns();
                    s.overruns += r->bridge.overruns();
                    s.resyncs += r->bridge.resyncs();
                }
            }
        }
    }
    return s;
}

int pp_engine_device_clock(PPEngine *e, unsigned int device, double *seconds, double *sample)
{
    std::lock_guard lock(e->control);
    for (const auto &d : e->devices) {
        if (d->id != device) {
            continue;
        }
        for (int tries = 0; tries < 8; ++tries) {
            const uint32_t seq = d->markSeq.load(std::memory_order_acquire);
            const double s = d->markSeconds.load(std::memory_order_relaxed);
            const double f = d->markSample.load(std::memory_order_relaxed);
            if ((seq & 1) == 0 && seq == d->markSeq.load(std::memory_order_acquire) && s > 0) {
                *seconds = s;
                *sample = f;
                return 1;
            }
        }
    }
    return 0;
}

double pp_engine_input_ratio_ppm(PPEngine *e, int input)
{
    const Route *r = e->inputBridge[size_t(input)].load();
    return r ? r->bridge.ratioPpm() : 0;
}

double pp_engine_output_ratio_ppm(PPEngine *e, int output)
{
    const Route *r = e->outputBridge[size_t(output)].load();
    return r ? r->bridge.ratioPpm() : 0;
}

void pp_engine_destroy(PPEngine *e)
{
    for (int i = 0; i < PP_MAX_INPUTS; ++i) {
        pp_engine_unbind_input(e, i);
    }
    for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
        pp_engine_unbind_output(e, o);
    }
    if (e->proc) {
        AudioDeviceStop(e->hidden, e->proc);
        AudioDeviceDestroyIOProcID(e->hidden, e->proc);
    }
    pp_mixer_destroy(e->mixer);
    delete e;
}

} // extern "C"
