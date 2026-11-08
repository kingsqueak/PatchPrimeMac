// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The mixer: inputs -> mix buses -> outputs. Topology is fixed-size tables of
// atomics, so a control thread can change anything at any time with no locks and
// no swaps, and the audio thread never waits. Each gain glides to its target
// across a block; the work per block follows the routes in use, not the table size.

#include "feed.h"
#include "tap.h"
#include "ppcore.h"
#include "ppdsp.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
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
    bool fxAsleep = false; // audio thread only: its effects stopped while muted

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
    // Effects: on a strip before its fader; on a bus or output after it, with the
    // meter after the effects, so an output's meter shows what its limiter let by.
    std::array<PPFx *, PP_MAX_INPUTS> inputFx{};
    std::array<bool, PP_MAX_INPUTS> inputMono{}; // control thread: how strips' chains are built
    std::array<PPFx *, PP_MAX_BUSES> busFx{};
    std::array<PPFx *, PP_MAX_OUTPUTS> outputFx{};
    // The safety limiter on outputs that reach hardware, after the user's effects.
    std::array<PPFx *, PP_MAX_OUTPUTS> safetyFx{};

    // Recording taps (see ppcore.h), and the blocks processed so far.
    std::array<std::atomic<PPTap *>, PP_MAX_INPUTS> inputTap{};
    std::array<std::atomic<PPTap *>, PP_MAX_BUSES> busTap{};
    std::array<std::atomic<PPTap *>, PP_MAX_OUTPUTS> outputTap{};
    std::atomic<unsigned long long> block{0};
    // The player and the pads: each feed and where it plays (kind * 64 + slot).
    std::array<std::atomic<PPFeed *>, PP_MAX_FEEDS> feed{};
    std::array<std::atomic<int>, PP_MAX_FEEDS> feedTarget{};

    // [RT] The feeds that play into this one. The player (slot 0) into a strip plays in
    // place of its device or apps (so its effects can be set up on a recording); the
    // soundboard's pads always add, wherever they play.
    void playFeed(int kind, int slot, Stereo &audio, int frames, bool replace)
    {
        const int here = kind * 64 + slot;
        for (std::size_t n = 0; n < feed.size(); ++n) {
            PPFeed *f = feed[n].load(std::memory_order_acquire);
            if (f && feedTarget[n].load(std::memory_order_relaxed) == here) {
                f->play(audio.left, audio.right, frames, replace && n == 0);
            }
        }
    }

    std::atomic<PPTap *> *tapFor(int kind, int slot)
    {
        switch (kind) {
        case PP_KIND_STRIP: return slot >= 0 && slot < PP_MAX_INPUTS ? &inputTap[size_t(slot)] : nullptr;
        case PP_KIND_BUS: return slot >= 0 && slot < PP_MAX_BUSES ? &busTap[size_t(slot)] : nullptr;
        case PP_KIND_OUTPUT: return slot >= 0 && slot < PP_MAX_OUTPUTS ? &outputTap[size_t(slot)] : nullptr;
        default: return nullptr;
        }
    }

    // [RT] Into a tap, if one is attached (and, for a strip, at this point).
    static void tap(std::atomic<PPTap *> &slot, const Stereo &audio, int frames, unsigned long long block,
                    int point = -1)
    {
        PPTap *t = slot.load(std::memory_order_acquire);
        if (!t || (point >= 0 && t->processed.load(std::memory_order_relaxed) != (point == 1))) {
            return;
        }
        t->push(audio.left, audio.right, frames, block);
    }

    // [RT] Taps whose stop has come are finished, whether or not their strip ran.
    static void finishTaps(std::atomic<PPTap *> *taps, int count, unsigned long long block)
    {
        for (int i = 0; i < count; ++i) {
            PPTap *t = taps[i].load(std::memory_order_acquire);
            if (t && block >= t->stop.load(std::memory_order_acquire)) {
                t->finished.store(true, std::memory_order_release);
            }
        }
    }

    // Keys: the input strip whose sound (after its effects and fader, in mono) a
    // chain's ducker listens to, or -1. Inputs run in an order where a key comes before
    // the strips it ducks: two lists, the control thread writing the one not in use.
    std::array<std::atomic<int>, PP_MAX_INPUTS> inputKey{};
    std::array<std::atomic<int>, PP_MAX_BUSES> busKey{};
    std::array<std::atomic<int>, PP_MAX_OUTPUTS> outputKey{};
    std::array<std::array<std::atomic<int8_t>, PP_MAX_INPUTS>, 2> order{};
    std::atomic<int> orderInUse{0};
    alignas(64) float keyAudio[PP_MAX_INPUTS][PP_MAX_BLOCK];
    std::array<bool, PP_MAX_INPUTS> keyReady{}; // realtime only: made this block

    // Cue (solo in the headphones): cued strips, buses and outputs play to the cue
    // output instead of its own mix, before their fader (PFL, after a strip's effects,
    // as on a console) or after it (AFL). Switching in and out crossfades.
    std::atomic<int> cueOutput{-1};
    std::atomic<float> cueLevel{1};
    std::atomic<bool> cuePre{true};
    std::array<std::atomic<bool>, PP_MAX_INPUTS> cueInput{};
    std::array<std::atomic<bool>, PP_MAX_BUSES> cueBus{};
    std::array<std::atomic<bool>, PP_MAX_OUTPUTS> cueOut{};
    // Each cued thing fades in and out on its own, so cueing or uncueing one never
    // clicks, whatever else is cued.
    std::array<Gain, PP_MAX_INPUTS> cueSendInput{};
    std::array<Gain, PP_MAX_BUSES> cueSendBus{};
    std::array<Gain, PP_MAX_OUTPUTS> cueSendOut{};
    Stereo cueMix;
    Gain cueBlend; // 0: the output's own mix, 1: cue
    Gain cueGain;

    // Whether this one is heard on cue this block (cued, or still fading out).
    static bool cueOn(Gain &send, const std::atomic<bool> &cued, bool cueing)
    {
        send.target.store(cueing && cued.load(std::memory_order_relaxed) ? 1.f : 0.f, std::memory_order_relaxed);
        return !send.idle();
    }

    void addCue(Gain &send, const Stereo &from, int frames)
    {
        this->send(send, from, cueMix, frames);
    }

    bool anyCued() const
    {
        for (const auto &c : cueInput) {
            if (c.load(std::memory_order_relaxed)) return true;
        }
        for (const auto &c : cueBus) {
            if (c.load(std::memory_order_relaxed)) return true;
        }
        for (const auto &c : cueOut) {
            if (c.load(std::memory_order_relaxed)) return true;
        }
        return false;
    }

    const float *keyFor(int from)
    {
        return from >= 0 && from < PP_MAX_INPUTS && keyReady[size_t(from)] ? keyAudio[from] : nullptr;
    }

    PPFx *fxFor(int kind, int slot)
    {
        switch (kind) {
        case PP_KIND_STRIP: return slot >= 0 && slot < PP_MAX_INPUTS ? inputFx[size_t(slot)] : nullptr;
        case PP_KIND_BUS: return slot >= 0 && slot < PP_MAX_BUSES ? busFx[size_t(slot)] : nullptr;
        case PP_KIND_OUTPUT: return slot >= 0 && slot < PP_MAX_OUTPUTS ? outputFx[size_t(slot)] : nullptr;
        default: return nullptr;
        }
    }

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
    }

    // Whether a channel's effects can stop this block: muted, and the fade to silence
    // finished, so nothing after the fader can hear them. On the way back they're told
    // to forget what they held, so nothing from before the mute comes through.
    static bool asleep(Channel &c, PPFx *fx, bool heardBeforeFader = false)
    {
        const bool silent = c.fader.current == 0.f && c.fader.target.load(std::memory_order_relaxed) == 0.f
            && pp_fx_can_sleep(fx) && !heardBeforeFader;
        if (silent) {
            c.fxAsleep = true;
            return true;
        }
        if (c.fxAsleep) {
            pp_fx_resume(fx);
            c.fxAsleep = false;
        }
        return false;
    }

    static void measure(Channel &c, int frames)
    {
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
        for (auto &f : m->inputFx) {
            f = pp_fx_create();
        }
        for (auto &f : m->busFx) {
            f = pp_fx_create();
        }
        for (auto &f : m->outputFx) {
            f = pp_fx_create();
        }
        for (auto &f : m->safetyFx) {
            f = pp_fx_create();
        }
        for (auto &k : m->inputKey) {
            k.store(-1);
        }
        for (auto &k : m->busKey) {
            k.store(-1);
        }
        for (auto &k : m->outputKey) {
            k.store(-1);
        }
        for (auto &list : m->order) {
            for (int i = 0; i < PP_MAX_INPUTS; ++i) {
                list[size_t(i)].store(int8_t(i));
            }
        }
    }
    return m;
}

void pp_mixer_destroy(PPMixer *m)
{
    if (m) {
        for (auto &f : m->inputFx) {
            pp_fx_destroy(f);
        }
        for (auto &f : m->busFx) {
            pp_fx_destroy(f);
        }
        for (auto &f : m->outputFx) {
            pp_fx_destroy(f);
        }
        for (auto &f : m->safetyFx) {
            pp_fx_destroy(f);
        }
        m->~PPMixer();
        ::operator delete(m, std::align_val_t(64));
    }
}

int pp_mixer_set_effects(PPMixer *m, int kind, int slot, const char *spec)
{
    PPFx *fx = m->fxFor(kind, slot);
    if (!fx) {
        return -1;
    }
    const bool mono = kind == PP_KIND_STRIP && m->inputMono[size_t(slot)];
    return pp_fx_set_channels(fx, spec, m->sampleRate, mono ? 1 : 2);
}

void pp_mixer_set_input_mono(PPMixer *m, int input, int mono)
{
    if (input >= 0 && input < PP_MAX_INPUTS) {
        m->inputMono[size_t(input)] = mono != 0;
    }
}

PPFx *pp_mixer_effects(PPMixer *m, int kind, int slot) { return m->fxFor(kind, slot); }

int pp_mixer_set_key(PPMixer *m, int kind, int slot, int fromInput)
{
    if (fromInput < -1 || fromInput >= PP_MAX_INPUTS) {
        return -1;
    }
    std::atomic<int> *target = nullptr;
    if (kind == PP_KIND_STRIP && slot >= 0 && slot < PP_MAX_INPUTS) {
        target = &m->inputKey[size_t(slot)];
    } else if (kind == PP_KIND_BUS && slot >= 0 && slot < PP_MAX_BUSES) {
        target = &m->busKey[size_t(slot)];
    } else if (kind == PP_KIND_OUTPUT && slot >= 0 && slot < PP_MAX_OUTPUTS) {
        target = &m->outputKey[size_t(slot)];
    }
    if (!target || (kind == PP_KIND_STRIP && fromInput == slot)) {
        return -1;
    }
    if (kind != PP_KIND_STRIP) {
        target->store(fromInput);
        return 0;
    }
    // A strip's key must come before it: put the strips in an order where every key
    // comes first, or refuse the key if there's none (a loop).
    std::array<int, PP_MAX_INPUTS> keys{};
    for (int i = 0; i < PP_MAX_INPUTS; ++i) {
        keys[size_t(i)] = i == slot ? fromInput : m->inputKey[size_t(i)].load();
    }
    std::array<int8_t, PP_MAX_INPUTS> list{};
    std::array<bool, PP_MAX_INPUTS> placed{};
    int count = 0;
    for (int pass = 0; pass < PP_MAX_INPUTS && count < PP_MAX_INPUTS; ++pass) {
        for (int i = 0; i < PP_MAX_INPUTS; ++i) {
            const int k = keys[size_t(i)];
            if (!placed[size_t(i)] && (k < 0 || placed[size_t(k)])) {
                placed[size_t(i)] = true;
                list[size_t(count++)] = int8_t(i);
            }
        }
    }
    if (count < PP_MAX_INPUTS) {
        return -2; // a loop: some strip would wait for itself
    }
    const int spare = 1 - m->orderInUse.load();
    for (int i = 0; i < PP_MAX_INPUTS; ++i) {
        m->order[size_t(spare)][size_t(i)].store(list[size_t(i)], std::memory_order_relaxed);
    }
    m->orderInUse.store(spare, std::memory_order_release);
    target->store(fromInput);
    return 0;
}

void pp_mixer_set_cue_output(PPMixer *m, int output)
{
    m->cueOutput.store(output >= 0 && output < PP_MAX_OUTPUTS ? output : -1);
}

void pp_mixer_set_cue_level(PPMixer *m, float gain) { m->cueLevel.store(std::max(0.f, gain)); }

void pp_mixer_set_cue_pre_fader(PPMixer *m, int pre) { m->cuePre.store(pre != 0); }

void pp_mixer_set_cued(PPMixer *m, int kind, int slot, int cued)
{
    if (kind == PP_KIND_STRIP && slot >= 0 && slot < PP_MAX_INPUTS) {
        m->cueInput[size_t(slot)].store(cued != 0);
    } else if (kind == PP_KIND_BUS && slot >= 0 && slot < PP_MAX_BUSES) {
        m->cueBus[size_t(slot)].store(cued != 0);
    } else if (kind == PP_KIND_OUTPUT && slot >= 0 && slot < PP_MAX_OUTPUTS) {
        m->cueOut[size_t(slot)].store(cued != 0);
    }
}

void pp_mixer_set_output_safety(PPMixer *m, int output, float ceilingDb)
{
    if (output < 0 || output >= PP_MAX_OUTPUTS) {
        return;
    }
    char spec[96] = "";
    if (ceilingDb < 0) {
        std::snprintf(spec, sizeof spec, "limiter\t1\tceiling=%.3f;release=100;truePeak=1", double(ceilingDb));
    }
    pp_fx_set(m->safetyFx[size_t(output)], spec, m->sampleRate);
}

void pp_mixer_collect(PPMixer *m)
{
    for (auto &f : m->inputFx) {
        pp_fx_collect(f);
    }
    for (auto &f : m->busFx) {
        pp_fx_collect(f);
    }
    for (auto &f : m->outputFx) {
        pp_fx_collect(f);
    }
    for (auto &f : m->safetyFx) {
        pp_fx_collect(f);
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

int pp_mixer_attach_tap(PPMixer *m, int kind, int slot, PPTap *tap)
{
    auto *at = m->tapFor(kind, slot);
    if (!at || !tap) {
        return -1;
    }
    PPTap *none = nullptr;
    return at->compare_exchange_strong(none, tap, std::memory_order_acq_rel) ? 0 : -1;
}

void pp_mixer_detach_tap(PPMixer *m, int kind, int slot)
{
    if (auto *at = m->tapFor(kind, slot)) {
        at->store(nullptr, std::memory_order_release);
    }
}

unsigned long long pp_mixer_block(const PPMixer *m) { return m->block.load(std::memory_order_acquire); }

void pp_mixer_set_feed(PPMixer *m, int index, PPFeed *feed, int kind, int slot)
{
    if (index < 0 || index >= PP_MAX_FEEDS) {
        return;
    }
    m->feedTarget[size_t(index)].store(feed ? kind * 64 + slot : -1, std::memory_order_relaxed);
    m->feed[size_t(index)].store(feed, std::memory_order_release);
}

void pp_mixer_process(PPMixer *m, int frames)
{
    frames = std::clamp(frames, 0, int(PP_MAX_BLOCK));
    if (frames == 0) {
        return;
    }
    const unsigned long long block = m->block.load(std::memory_order_relaxed);
    PPMixer::finishTaps(m->inputTap.data(), PP_MAX_INPUTS, block);
    PPMixer::finishTaps(m->busTap.data(), PP_MAX_BUSES, block);
    PPMixer::finishTaps(m->outputTap.data(), PP_MAX_OUTPUTS, block);
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
    m->keyReady.fill(false);
    const int cueTo = m->cueOutput.load(std::memory_order_relaxed);
    const bool cueing = cueTo >= 0 && cueTo < PP_MAX_OUTPUTS && m->anyCued();
    const bool pre = m->cuePre.load(std::memory_order_relaxed);
    m->cueMix.clear(frames);
    std::array<bool, PP_MAX_INPUTS> done{};
    const auto &list = m->order[size_t(m->orderInUse.load(std::memory_order_acquire))];
    // In key order; then anything the list missed (it can't, but nothing may be lost).
    for (int n = 0; n < 2 * PP_MAX_INPUTS; ++n) {
        const int i = n < PP_MAX_INPUTS ? list[size_t(n)].load(std::memory_order_relaxed) : n - PP_MAX_INPUTS;
        if (i < 0 || i >= PP_MAX_INPUTS || done[size_t(i)]) {
            continue;
        }
        done[size_t(i)] = true;
        Channel &in = m->inputs[size_t(i)];
        if (!in.active.load(std::memory_order_relaxed)) {
            continue;
        }
        in.updateTarget();
        m->playFeed(PP_KIND_STRIP, i, in.audio, frames, true); // the player, in place of the device
        PPMixer::tap(m->inputTap[size_t(i)], in.audio, frames, block, 0); // raw: before its effects
        auto &cueSend = m->cueSendInput[size_t(i)];
        const bool cued = PPMixer::cueOn(cueSend, m->cueInput[size_t(i)], cueing);
        if (!PPMixer::asleep(in, m->inputFx[size_t(i)], cued && pre)) {
            pp_fx_process_keyed(m->inputFx[size_t(i)], in.audio.left, in.audio.right, frames,
                m->keyFor(m->inputKey[size_t(i)].load(std::memory_order_relaxed)));
        }
        if (cued && pre) {
            m->addCue(cueSend, in.audio, frames); // after its effects, before its fader
        }
        m->fade(in, frames);
        if (cued && !pre) {
            m->addCue(cueSend, in.audio, frames);
        }
        PPMixer::measure(in, frames);
        PPMixer::tap(m->inputTap[size_t(i)], in.audio, frames, block, 1); // processed
        // This strip as a key for others: mono, after its effects and fader.
        for (int f = 0; f < frames; ++f) {
            m->keyAudio[i][f] = 0.5f * (in.audio.left[f] + in.audio.right[f]);
        }
        m->keyReady[size_t(i)] = true;
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
        m->playFeed(PP_KIND_BUS, b, bus.audio, frames, false);
        auto &busSend = m->cueSendBus[size_t(b)];
        const bool busCued = PPMixer::cueOn(busSend, m->cueBus[size_t(b)], cueing);
        if (busCued && pre) {
            m->addCue(busSend, bus.audio, frames); // the bus's sum, before its fader
        }
        m->fade(bus, frames);
        if (!PPMixer::asleep(bus, m->busFx[size_t(b)])) {
            pp_fx_process_keyed(m->busFx[size_t(b)], bus.audio.left, bus.audio.right, frames,
                m->keyFor(m->busKey[size_t(b)].load(std::memory_order_relaxed)));
        }
        if (busCued && !pre) {
            m->addCue(busSend, bus.audio, frames);
        }
        PPMixer::measure(bus, frames);
        PPMixer::tap(m->busTap[size_t(b)], bus.audio, frames, block);
        for (int o = 0; o < PP_MAX_OUTPUTS; ++o) {
            if (m->outputs[size_t(o)].active.load(std::memory_order_relaxed)) {
                m->send(m->busToOutput[b][o], bus.audio, m->outputs[size_t(o)].audio, frames);
            }
        }
    }
    // Outputs; the cue output last, since what it plays may include the others.
    for (int n = 0; n <= PP_MAX_OUTPUTS; ++n) {
        const int o = n < PP_MAX_OUTPUTS ? n : cueTo;
        if (o < 0 || o >= PP_MAX_OUTPUTS || (n < PP_MAX_OUTPUTS && o == cueTo)) {
            continue;
        }
        Channel &out = m->outputs[size_t(o)];
        if (!out.active.load(std::memory_order_relaxed)) {
            continue;
        }
        m->playFeed(PP_KIND_OUTPUT, o, out.audio, frames, false);
        auto &outSend = m->cueSendOut[size_t(o)];
        const bool outCued = o != cueTo && PPMixer::cueOn(outSend, m->cueOut[size_t(o)], cueing);
        if (outCued && pre) {
            m->addCue(outSend, out.audio, frames);
        }
        m->fade(out, frames);
        const bool awake = !PPMixer::asleep(out, m->outputFx[size_t(o)]);
        if (awake) {
            pp_fx_process_keyed(m->outputFx[size_t(o)], out.audio.left, out.audio.right, frames,
                m->keyFor(m->outputKey[size_t(o)].load(std::memory_order_relaxed)));
        }
        if (outCued && !pre) {
            m->addCue(outSend, out.audio, frames);
        }
        if (o == cueTo) {
            // Crossfade between its own mix and cue, at the cue level.
            m->cueBlend.target.store(cueing ? 1.f : 0.f, std::memory_order_relaxed);
            m->cueGain.target.store(m->cueLevel.load(std::memory_order_relaxed), std::memory_order_relaxed);
            const float blendFrom = m->cueBlend.current, blendTo = m->glide(m->cueBlend, frames);
            const float gainFrom = m->cueGain.current, gainTo = m->glide(m->cueGain, frames);
            m->cueBlend.current = blendTo;
            m->cueGain.current = gainTo;
            if (blendFrom > 0.f || blendTo > 0.f) {
                applyRamp(out.audio.left, frames, 1.f - blendFrom, 1.f - blendTo);
                applyRamp(out.audio.right, frames, 1.f - blendFrom, 1.f - blendTo);
                addRamp(out.audio.left, m->cueMix.left, frames, blendFrom * gainFrom, blendTo * gainTo);
                addRamp(out.audio.right, m->cueMix.right, frames, blendFrom * gainFrom, blendTo * gainTo);
                pp_fx_process(m->safetyFx[size_t(o)], out.audio.left, out.audio.right, frames);
                PPMixer::measure(out, frames);
                PPMixer::tap(m->outputTap[size_t(o)], out.audio, frames, block);
                continue;
            }
        }
        if (awake) {
            pp_fx_process(m->safetyFx[size_t(o)], out.audio.left, out.audio.right, frames);
        }
        PPMixer::measure(out, frames);
        PPMixer::tap(m->outputTap[size_t(o)], out.audio, frames, block);
    }
    m->block.store(block + 1, std::memory_order_release);
}

PPMeter pp_mixer_read_input_meter(PPMixer *m, int i) { return m->inputs[size_t(i)].meter.read(); }
PPMeter pp_mixer_read_bus_meter(PPMixer *m, int i) { return m->buses[size_t(i)].meter.read(); }
PPMeter pp_mixer_read_output_meter(PPMixer *m, int i) { return m->outputs[size_t(i)].meter.read(); }

} // extern "C"
