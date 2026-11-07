// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/multiband.h, commit 458e957).
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

// A 4-band compressor. Three crossovers ("x1" < "x2" < "x3", Hz) split the
// signal into four bands with Linkwitz-Riley 24 dB/octave filters, arranged
// so the bands add back up to the input (flat, only phase-shifted) when
// nothing is compressing:
//
//   in ─┬─ LR4 low  @x2 ─ allpass @x3 ─┬─ LR4 low  @x1 ─ band 1
//       │                              └─ LR4 high @x1 ─ band 2
//       └─ LR4 high @x2 ─ allpass @x1 ─┬─ LR4 low  @x3 ─ band 3
//                                      └─ LR4 high @x3 ─ band 4
//
// Each band has its own compressor, working on the band's RMS level (10 ms),
// with the channels linked (the loudest channel sets the gain for all, so
// the stereo image holds): "b<n>Threshold"
// (dB), "b<n>Ratio" (n:1), "b<n>Attack" and "b<n>Release" (ms), "b<n>Makeup"
// (dB), "b<n>On" (off = the band passes uncompressed) and "b<n>Solo" (when
// any band is soloed, only soloed bands are heard). The knee is soft (6 dB).
//
// Crossovers glide; on/off, solo and makeup changes fade (5 ms).
class MultibandEffect : public Effect
{
public:
    static constexpr int bandCount = 4;
    static constexpr double minCrossover = 30.0;
    static constexpr double maxCrossover = 16000.0;
    static constexpr std::array<double, 3> defaultCrossovers{120.0, 1000.0, 6000.0};
    static constexpr double kneeDb = 6.0;

    // The gain a compressor with threshold, ratio and the soft knee gives a
    // level (all dB): what the output level is for an input level.
    static double staticCurve(double inputDb, double thresholdDb, double ratio);

    MultibandEffect();
    [[nodiscard]] std::string_view type() const override { return "multiband"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // Since the last call: each band's largest gain reduction (dB,
    // positive), then each band's loudest detector level (what the
    // threshold is compared with) as dB above meterFloorDb (0 = at or
    // below it): 2 x bandCount values.
    std::size_t takeMeters(std::span<float> out) override;
    static constexpr double meterFloorDb = -80.0;
    // Back from bypass: filter memory and gain reduction are from before.
    void resume() noexcept override;

private:
    static constexpr int blockFrames = 32;

    // A biquad's state per channel (transposed direct form II).
    using State = std::array<std::array<double, 2>, maxEffectChannels>;
    struct Crossover
    {
        EqEffect::Coefficients low;
        EqEffect::Coefficients high;
        EqEffect::Coefficients allpass;
    };
    struct BandTarget
    {
        std::atomic<float> threshold{-20.0F};
        std::atomic<float> ratio{2.0F};
        std::atomic<float> attackMs{10.0F};
        std::atomic<float> releaseMs{150.0F};
        std::atomic<float> makeupDb{0.0F};
        std::atomic<bool> on{true};
        std::atomic<bool> solo{false};
        std::atomic<float> meter{0.0F};      // realtime writes, main thread takes
        std::atomic<float> levelMeter{0.0F}; // the same, dB above meterFloorDb
    };
    struct BandState // realtime only
    {
        double meanSquare = 0.0;  // the level detector
        double reductionDb = 0.0; // smoothed gain reduction
        double level = 1.0;       // smoothed makeup x on x solo, linear
    };

    void updateCrossovers(double glide) noexcept;

    std::array<std::atomic<float>, 3> m_crossTarget{};
    std::array<BandTarget, bandCount> m_target;
    // Realtime only.
    std::array<double, 3> m_crossNow{};
    std::array<Crossover, 3> m_cross{};
    bool m_fresh = true;
    // Filter states: the x2 split (low and high, two stages each), the two
    // allpasses, then the x1 and x3 splits (two stages each, low and high).
    std::array<State, 2> m_midLow{};
    std::array<State, 2> m_midHigh{};
    State m_allpassLow{};  // @x3 on the low branch
    State m_allpassHigh{}; // @x1 on the high branch
    std::array<State, 2> m_band1{};
    std::array<State, 2> m_band2{};
    std::array<State, 2> m_band3{};
    std::array<State, 2> m_band4{};
    std::array<BandState, bandCount> m_state{};
    double m_rate = 48000.0;
    double m_glide = 1.0;
    double m_levelStep = 1.0; // one-pole coefficient per sample, ~5 ms
    double m_rmsStep = 1.0;   // the level detector's, ~10 ms
    double m_offRelease = 0.0; // a band turned off lets go of its reduction in ~5 ms
};

} // namespace pp
