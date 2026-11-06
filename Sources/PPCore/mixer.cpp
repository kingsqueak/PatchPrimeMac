// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The mixer: inputs -> mix buses -> outputs. Topology is fixed-size tables of
// atomics, so a control thread can change anything at any time with no locks and
// no swaps, and the audio thread never waits. Each gain glides to its target
// across a block; the work per block follows the routes in use, not the table size.

#include "ppcore.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>

namespace {

// Glides a gain towards its target with no zipper noise.
struct Gain
{
    std::atomic<float> target{0};
    float current = 0;

    bool idle() const
    {
        return current == 0 && target.load(std::memory_order_relaxed) == 0;
    }
};

struct alignas(64) Stereo
{
    alignas(16) float left[PP_MAX_BLOCK];
    alignas(16) float right[PP_MAX_BLOCK];

    void clear(int frames)
    {
        std::memset(left, 0, size_t(frames) * sizeof(float));
        std::memset(right, 0, size_t(frames) * sizeof(float));
    }
};

struct Meter
{
    std::atomic<float> left{0};
    std::atomic<float> right{0};

    // Keeps the highest peak until read. Relaxed: a meter may lag a block.
    void add(float l, float r)
    {
        if (l > left.load(std::memory_order_relaxed)) {
            left.store(l, std::memory_order_relaxed);
        }
        if (r > right.load(std::memory_order_relaxed)) {
            right.store(r, std::memory_order_relaxed);
        }
    }

    PPMeter read()
    {
        return {left.exchange(0, std::memory_order_relaxed),
            right.exchange(0, std::memory_order_relaxed)};
    }
};

struct Channel
{
    Stereo audio;
    Gain fader;
    std::atomic<float> gain{1};
    std::atomic<bool> muted{false};
    std::atomic<bool> active{false};
    Meter meter;

    void updateTarget()
    {
        const float g = muted.load(std::memory_order_relaxed) ? 0.f
                                                              : gain.load(std::memory_order_relaxed);
        fader.target.store(g, std::memory_order_relaxed);
    }
};

// Scales a block by a gain that moves linearly from `from` to `to`.
inline void applyRamp(float *audio, int frames, float from, float to)
{
    if (from == to) {
        if (from == 1.f) {
            return;
        }
        for (int i = 0; i < frames; ++i) {
            audio[i] *= to;
        }
        return;
    }
    const float step = (to - from) / float(frames);
    float g = from;
    for (int i = 0; i < frames; ++i) {
        audio[i] *= g;
        g += step;
    }
}

// Adds a block into another, with a gain that moves from `from` to `to`.
inline void addRamp(float *into, const float *audio, int frames, float from, float to)
{
    if (from == to) {
        for (int i = 0; i < frames; ++i) {
            into[i] += audio[i] * to;
        }
        return;
    }
    const float step = (to - from) / float(frames);
    float g = from;
    for (int i = 0; i < frames; ++i) {
        into[i] += audio[i] * g;
        g += step;
    }
}

inline float peakOf(const float *audio, int frames)
{
    float peak = 0;
    for (int i = 0; i < frames; ++i) {
        peak = std::max(peak, std::fabs(audio[i]));
    }
    return peak;
}

} // namespace

struct PPMixer
{
    double sampleRate;
    float glideStep; // the most a gain moves per frame

    std::array<Channel, PP_MAX_INPUTS> inputs;
    std::array<Channel, PP_MAX_BUSES> buses;
    std::array<Channel, PP_MAX_OUTPUTS> outputs;
    Gain inputToBus[PP_MAX_INPUTS][PP_MAX_BUSES];
    Gain inputToOutput[PP_MAX_INPUTS][PP_MAX_OUTPUTS];
    Gain busToOutput[PP_MAX_BUSES][PP_MAX_OUTPUTS];

    float glide(Gain &g, int frames) const
    {
        const float target = g.target.load(std::memory_order_relaxed);
        const float reach = glideStep * float(frames);
        const float next = g.current < target ? std::min(target, g.current + reach)
                                              : std::max(target, g.current - reach);
        return next;
    }

    void send(Gain &route, const Stereo &from, Stereo &to, int frames)
    {
        if (route.idle()) {
            return;
        }
        const float next = glide(route, frames);
        addRamp(to.left, from.left, frames, route.current, next);
        addRamp(to.right, from.right, frames, route.current, next);
        route.current = next;
    }

    void fade(Channel &c, int frames)
    {
        c.updateTarget();
        const float next = glide(c.fader, frames);
        applyRamp(c.audio.left, frames, c.fader.current, next);
        applyRamp(c.audio.right, frames, c.fader.current, next);
        c.fader.current = next;
        c.meter.add(peakOf(c.audio.left, frames), peakOf(c.audio.right, frames));
    }
};

extern "C" {

PPMixer *pp_mixer_create(double sampleRate)
{
    auto *m = new (std::align_val_t(64), std::nothrow) PPMixer();
    if (m) {
        m->sampleRate = sampleRate;
        m->glideStep = float(1.0 / (0.010 * sampleRate)); // full scale in 10 ms
    }
    return m;
}

void pp_mixer_destroy(PPMixer *m)
{
    if (m) {
        m->~PPMixer();
        ::operator delete(m, std::align_val_t(64));
    }
}

void pp_mixer_set_input_gain(PPMixer *m, int i, float g) { m->inputs[size_t(i)].gain.store(g); }
void pp_mixer_set_input_mute(PPMixer *m, int i, int v) { m->inputs[size_t(i)].muted.store(v != 0); }
void pp_mixer_set_bus_gain(PPMixer *m, int i, float g) { m->buses[size_t(i)].gain.store(g); }
void pp_mixer_set_bus_mute(PPMixer *m, int i, int v) { m->buses[size_t(i)].muted.store(v != 0); }
void pp_mixer_set_output_gain(PPMixer *m, int i, float g) { m->outputs[size_t(i)].gain.store(g); }
void pp_mixer_set_output_mute(PPMixer *m, int i, int v) { m->outputs[size_t(i)].muted.store(v != 0); }

void pp_mixer_set_input_to_bus(PPMixer *m, int i, int b, float g)
{
    m->inputToBus[i][b].target.store(g, std::memory_order_relaxed);
}
void pp_mixer_set_input_to_output(PPMixer *m, int i, int o, float g)
{
    m->inputToOutput[i][o].target.store(g, std::memory_order_relaxed);
}
void pp_mixer_set_bus_to_output(PPMixer *m, int b, int o, float g)
{
    m->busToOutput[b][o].target.store(g, std::memory_order_relaxed);
}

void pp_mixer_set_input_active(PPMixer *m, int i, int v) { m->inputs[size_t(i)].active.store(v != 0); }
void pp_mixer_set_bus_active(PPMixer *m, int i, int v) { m->buses[size_t(i)].active.store(v != 0); }
void pp_mixer_set_output_active(PPMixer *m, int i, int v) { m->outputs[size_t(i)].active.store(v != 0); }

float *pp_mixer_input_left(PPMixer *m, int i) { return m->inputs[size_t(i)].audio.left; }
float *pp_mixer_input_right(PPMixer *m, int i) { return m->inputs[size_t(i)].audio.right; }
const float *pp_mixer_output_left(const PPMixer *m, int o) { return m->outputs[size_t(o)].audio.left; }
const float *pp_mixer_output_right(const PPMixer *m, int o) { return m->outputs[size_t(o)].audio.right; }

void pp_mixer_process(PPMixer *m, int frames)
{
    frames = std::clamp(frames, 0, int(PP_MAX_BLOCK));
    if (frames == 0) {
        return;
    }
    for (int b = 0; b < PP_MAX_BUSES; ++b) {
        if (m->buses[size_t(b)].active.load(std::memory_order_relaxed)) {
            m->buses[size_t(b)].audio.clear(frames);
        }
    }
    for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
        if (m->outputs[size_t(o)].active.load(std::memory_order_relaxed)) {
            m->outputs[size_t(o)].audio.clear(frames);
        }
    }
    for (int i = 0; i < PP_MAX_INPUTS; ++i) {
        Channel &in = m->inputs[size_t(i)];
        if (!in.active.load(std::memory_order_relaxed)) {
            continue;
        }
        m->fade(in, frames);
        for (int b = 0; b < PP_MAX_BUSES; ++b) {
            if (m->buses[size_t(b)].active.load(std::memory_order_relaxed)) {
                m->send(m->inputToBus[i][b], in.audio, m->buses[size_t(b)].audio, frames);
            }
        }
        for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
            if (m->outputs[size_t(o)].active.load(std::memory_order_relaxed)) {
                m->send(m->inputToOutput[i][o], in.audio, m->outputs[size_t(o)].audio, frames);
            }
        }
    }
    for (int b = 0; b < PP_MAX_BUSES; ++b) {
        Channel &bus = m->buses[size_t(b)];
        if (!bus.active.load(std::memory_order_relaxed)) {
            continue;
        }
        m->fade(bus, frames);
        for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
            if (m->outputs[size_t(o)].active.load(std::memory_order_relaxed)) {
                m->send(m->busToOutput[b][o], bus.audio, m->outputs[size_t(o)].audio, frames);
            }
        }
    }
    for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
        Channel &out = m->outputs[size_t(o)];
        if (out.active.load(std::memory_order_relaxed)) {
            m->fade(out, frames);
        }
    }
}

PPMeter pp_mixer_read_input_meter(PPMixer *m, int i) { return m->inputs[size_t(i)].meter.read(); }
PPMeter pp_mixer_read_bus_meter(PPMixer *m, int i) { return m->buses[size_t(i)].meter.read(); }
PPMeter pp_mixer_read_output_meter(PPMixer *m, int i) { return m->outputs[size_t(i)].meter.read(); }

} // extern "C"
