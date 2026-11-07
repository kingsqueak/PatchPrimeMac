// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/reverb.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include "effects.h"

#include <array>
#include <atomic>
#include <string>
#include <vector>

namespace pp {

// An algorithmic reverb: the input (all channels summed) goes through a
// pre-delay and four diffusing allpasses into an 8-line feedback delay
// network with a Householder matrix. Each line is damped (high frequencies
// die first, like a real room) and turned down per pass so the tail falls by
// 60 dB over the decay time. Two lines' lengths move slowly, which keeps the
// tail from ringing. Left and right take the lines with different signs.
//
// Parameters: "size" (%, the room: scales every line), "decay" (s, RT60),
// "predelay" (ms), "damping" (%), "width" (%), "mix" (% wet). As an insert,
// a little mix; on a reverb bus that strips send to, mix 100 %.
//
// Size and pre-delay glide when changed, so moving them doesn't click.
//
// Bypassed, it stops taking in sound but rings out over the dry signal (what
// is already in the pre-delay still goes in); once the tail has died away it
// sleeps and costs nothing. Switched back on, a tail still ringing carries on.
class ReverbEffect : public Effect
{
public:
    static constexpr int lineCount = 8;
    static constexpr double maxPredelayMs = 200.0;

    ReverbEffect() = default;
    [[nodiscard]] std::string_view type() const override { return "reverb"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    [[nodiscard]] bool ringsOut() const noexcept override { return true; }

private:
    static constexpr int blockFrames = 32;
    // Bypassed, the tail counts as gone below this (-100 dBFS) ...
    static constexpr float quietLevel = 1e-5F;
    // ... for this long: more than the longest pre-delay, so a tail that
    // hasn't started yet isn't taken for silence.
    static constexpr double quietSeconds = 0.5;

    // A delay line read at a fractional position (linear interpolation).
    struct Line
    {
        std::vector<float> buffer;
        std::size_t write = 0;
        void push(float x) noexcept;
        [[nodiscard]] float read(double delay) const noexcept; // samples back, >= 1
    };
    // A Schroeder allpass for diffusion.
    struct Allpass
    {
        std::vector<float> buffer;
        std::size_t at = 0;
        float step(float x) noexcept;
    };

    void updateBlock() noexcept;
    void clear() noexcept;

    std::atomic<float> m_size{50.0F};
    std::atomic<float> m_decay{2.0F};
    std::atomic<float> m_predelay{20.0F};
    std::atomic<float> m_damping{50.0F};
    std::atomic<float> m_width{100.0F};
    std::atomic<float> m_mix{25.0F};

    // Realtime only (sized in prepare()).
    double m_rate = 48000.0;
    Line m_pre;
    std::array<Allpass, 4> m_diffusers;
    std::array<Line, lineCount> m_lines;
    std::array<double, lineCount> m_base{};     // line lengths at size 1, in samples
    std::array<float, lineCount> m_lowpass{};   // damping filter state
    std::array<double, lineCount> m_gain{};     // per-pass gain for the decay
    double m_scale = 1.0;                       // size factor, gliding per sample
    double m_preSamples = 0.0;                  // gliding per sample
    double m_scaleTarget = 1.0;
    double m_preTarget = 0.0;
    double m_sampleGlide = 1.0;                 // per sample, ~100 ms
    float m_mixNow = 0.25F;                     // smoothed, so changes don't step
    float m_widthNow = 1.0F;
    float m_smooth = 1.0F;                      // per sample, ~10 ms
    float m_onNow = 1.0F;                       // 1 = on, 0 = bypassed, ramping
    float m_onStep = 1.0F;                      // per sample, over the chain's crossfade time
    int m_quietFrames = 0;                      // bypassed: how long the tail has been silent
    int m_sleepFrames = 0;                      // after that many, stop
    bool m_asleep = false;                      // bypassed and the tail has gone
    float m_damp = 0.5F;                        // one-pole coefficient
    double m_phase = 0.0;                       // modulation of line 0
    double m_phase2 = 0.0;                      // of line 4, a bit slower
    double m_phaseStep = 0.0;
    double m_modDepth = 0.0;                    // samples
    float m_denormal = 1e-18F;
};

} // namespace pp
