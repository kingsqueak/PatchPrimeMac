// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/loudness.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include "effects.h"
#include "eq.h"

#include <array>
#include <atomic>
#include <span>
#include <string>

namespace pp {

// The ITU-R BS.1770 "K" weighting (a high shelf around 1.7 kHz and a high
// pass around 38 Hz) for a sample rate: what loudness in LUFS is measured
// through. Coefficients as in libebur128, valid at any rate.
struct KWeighting
{
    EqEffect::Coefficients shelf;
    EqEffect::Coefficients highPass;
    static KWeighting forRate(double sampleRate);
};

// LUFS from the summed mean square of the K-weighted channels.
double lufsFromMeanSquare(double meanSquare);

// True peak (ITU-R BS.1770-4 Annex 2) of one channel: each sample
// interpolated four times over with the standard 48-tap filter; process()
// gives the largest of the four (absolute, linear). The interpolated values
// come about `delay` samples late.
class TruePeakDetector
{
public:
    static constexpr int taps = 12; // per phase
    static constexpr int delay = 6;

    void reset() noexcept { m_history.fill(0.0F); }
    float process(float sample) noexcept;

private:
    std::array<float, taps> m_history{}; // newest first
};

// A broadcast leveler: rides the strip's gain slowly towards a target
// loudness, like a radio station's AGC, so quiet and loud sources come out
// alike. Loudness is K-weighted (LUFS) over about a second.
//
// Parameters: "target" (LUFS), "maxBoost" and "maxCut" (dB), "speed" (s: how
// long a change takes), "freeze" (LUFS: below this the gain holds still, so
// silence, breaths and room noise aren't turned up). The freeze listens to a
// fast (25 ms) reading, so the gain stops the moment a source goes quiet,
// not once the slow reading has caught up; the slow reading holds too, so
// sound coming back isn't measured against the silence.
class LevelerEffect : public Effect
{
public:
    LevelerEffect() = default;
    [[nodiscard]] std::string_view type() const override { return "leveler"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // [gain now (dB, + = boost), loudness now (LUFS)].
    std::size_t takeMeters(std::span<float> out) override;

private:
    std::atomic<float> m_target{-18.0F};
    std::atomic<float> m_maxBoost{12.0F};
    std::atomic<float> m_maxCut{12.0F};
    std::atomic<float> m_speed{5.0F};
    std::atomic<float> m_freeze{-50.0F};
    std::atomic<float> m_gainMeter{0.0F};
    std::atomic<float> m_loudnessMeter{-70.0F};
    // Realtime only.
    KWeighting m_weighting;
    std::array<std::array<double, 2>, maxEffectChannels> m_shelfState{};
    std::array<std::array<double, 2>, maxEffectChannels> m_passState{};
    double m_meanSquare = 0.0;
    double m_window = 1.0; // one-pole step for the ~1 s loudness window
    double m_fastSquare = 0.0;
    double m_fastWindow = 1.0; // ~25 ms, for the freeze
    double m_gainDb = 0.0;
    double m_rate = 48000.0;
};

// A safety limiter: no sample leaves above the "ceiling" (dBFS). It looks
// 1.5 ms ahead (that much latency, plus the true-peak detector's few
// samples), so the gain is already down when a peak arrives, then recovers
// over "release" (ms). Channels linked. With "truePeak" on, the ceiling is in
// dBTP: peaks between samples (as a DAC or a lossy encoder makes them) are
// held under it too.
class LimiterEffect : public Effect
{
public:
    static constexpr double lookaheadSeconds = 0.0015;
    static constexpr int maxLookahead = 1024; // samples: 1.5 ms up to 384 kHz and then some

    LimiterEffect() = default;
    [[nodiscard]] std::string_view type() const override { return "limiter"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    void resume() noexcept override;
    // The lookahead, in both modes.
    [[nodiscard]] int latency() const override { return m_length - 1; }
    // The gain reduction (dB, positive), the largest since the last call.
    std::size_t takeMeters(std::span<float> out) override;

private:
    std::atomic<float> m_ceiling{-1.0F};
    std::atomic<float> m_release{100.0F};
    std::atomic<bool> m_truePeak{false};
    std::atomic<float> m_meter{0.0F};
    std::array<TruePeakDetector, maxEffectChannels> m_detectors{}; // realtime only
    // Realtime only.
    int m_length = 1;                                  // lookahead in samples
    int m_at = 0;                                      // ring position
    std::array<std::array<float, maxLookahead>, maxEffectChannels> m_delay{};
    std::array<double, maxLookahead> m_needed{};       // gain each sample needs
    std::array<double, maxLookahead> m_smoothed{};     // released gain, for the average
    double m_min = 1.0;   // lowest needed gain in the window
    int m_minAge = 0;     // samples since m_min entered
    double m_released = 1.0;
    double m_sum = 0.0;   // of m_smoothed over the window
    double m_rate = 48000.0;
};

} // namespace pp
