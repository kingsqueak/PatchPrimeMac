// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/eq.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include "effects.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

namespace pp {

// A 6-band parametric EQ: each band a biquad (RBJ "Audio EQ Cookbook") that
// is a bell, a low or high shelf, or a 12 dB/octave low or high cut.
//
// Parameters per band n (1-6): "b<n>On" (0/1), "b<n>Type" (a BandType),
// "b<n>Freq" (Hz), "b<n>Gain" (dB; bells and shelves), "b<n>Q".
//
// Frequency, gain and Q glide to new values (about 20 ms) instead of
// jumping; switching a band on or off, or changing its type, fades the band
// out and back in. All of that happens on the realtime thread without
// allocating: coefficients are recomputed there, every 32 samples while a
// band moves.
class EqEffect : public Effect
{
public:
    static constexpr int bandCount = 6;
    enum class BandType : std::uint8_t
    {
        Bell,
        LowShelf,
        HighShelf,
        LowCut,
        HighCut,
    };
    static constexpr int bandTypeCount = 5;
    static constexpr double minFreq = 20.0;
    static constexpr double maxFreq = 20000.0;
    static constexpr double minGain = -24.0;
    static constexpr double maxGain = 24.0;
    static constexpr double minQ = 0.1;
    static constexpr double maxQ = 10.0;

    struct Band
    {
        bool on = true;
        BandType type = BandType::Bell;
        double freq = 1000.0;
        double gainDb = 0.0;
        double q = 1.0;
    };
    // The bands a new EQ starts with: low shelf 80 Hz, bells at 250 Hz,
    // 1 kHz, 3 kHz and 6 kHz, high shelf 12 kHz; all flat.
    static Band defaultBand(int index);

    // Normalised biquad coefficients (a0 = 1).
    struct Coefficients
    {
        double b0 = 1.0;
        double b1 = 0.0;
        double b2 = 0.0;
        double a1 = 0.0;
        double a2 = 0.0;
    };
    static Coefficients coefficients(const Band &band, double sampleRate);
    // The magnitude in dB of a set of bands at freq (for drawing the curve).
    static double responseDb(const std::vector<Band> &bands, double freq, double sampleRate);

    static std::string typeName(BandType type); // "Bell", "Low shelf", ...

    EqEffect();
    [[nodiscard]] std::string_view type() const override { return "eq"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // Back from bypass: the bands' filter memory is from before; drop it.
    void resume() noexcept override;

private:
    static constexpr int blockFrames = 32; // coefficient update interval while moving

    struct Target
    {
        std::atomic<bool> on{true};
        std::atomic<int> type{0};
        std::atomic<float> freq{1000.0F};
        std::atomic<float> gainDb{0.0F};
        std::atomic<float> q{1.0F};
    };
    // Realtime only.
    struct State
    {
        Band now;           // the parameters the coefficients were made from
        float mix = 1.0F;   // 0 = band out, 1 = in
        bool fresh = true;  // coefficients need computing
        Coefficients c;
        std::array<std::array<double, 2>, maxEffectChannels> z{}; // per channel
    };

    void updateBand(int index) noexcept;

    std::array<Target, bandCount> m_target;
    std::array<State, bandCount> m_state;
    double m_rate = 48000.0;
    double m_glide = 1.0;     // per full block, one-pole
    double m_blockGlide = 1.0; // for the block being processed (shorter at the end)
    float m_fadeStep = 1.0F;  // per sample, for on/off and type changes
};

} // namespace pp
