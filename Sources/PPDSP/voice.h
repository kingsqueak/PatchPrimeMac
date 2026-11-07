// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/voice.h, commit 458e957).
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

// Voice tools: a compressor that's one knob unless asked for more, a
// split-band de-esser and a downward expander. Channels linked in all three.

// A single-band compressor for speech. "amount" (0-100 %) sets everything
// at once: threshold from -10 to -35 dB, ratio from 1:1 to 6:1, 5 ms
// attack, 120 ms release and makeup gain to match, so 0 % is no change at
// all. With "advanced" on, "threshold" (dB), "ratio" (n:1), "attack",
// "release" (ms) and "makeup" (dB) are used instead. The knee is soft (6 dB).
class CompressorEffect : public Effect
{
public:
    struct Settings
    {
        double threshold = -20.0;
        double ratio = 3.0;
        double attack = 5.0;
        double release = 120.0;
        double makeup = 0.0;
    };
    // What the knob stands for at amount (0-100 %).
    static Settings fromAmount(double amount);

    [[nodiscard]] std::string_view type() const override { return "compressor"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // [gain reduction (dB, positive, the largest since the last call),
    //  the threshold in use (dB)].
    std::size_t takeMeters(std::span<float> out) override;
    void resume() noexcept override;

private:
    std::atomic<float> m_amount{40.0F};
    std::atomic<bool> m_advanced{false};
    std::atomic<float> m_threshold{-20.0F};
    std::atomic<float> m_ratio{3.0F};
    std::atomic<float> m_attack{5.0F};
    std::atomic<float> m_release{120.0F};
    std::atomic<float> m_makeup{0.0F};
    std::atomic<float> m_meter{0.0F};
    std::atomic<float> m_inUse{-20.0F};
    // Realtime only.
    double m_rate = 48000.0;
    double m_envelope = 0.0;
    double m_envelopeFall = 0.0; // ~10 ms
    double m_reductionDb = 0.0;
    double m_makeupNow = 1.0; // linear, glides
    double m_glide = 1.0;     // per sample, ~20 ms
};

// A split-band de-esser. The sound is split at "frequency" (Hz) into a low
// part and what's left over (the two add back up to the input exactly);
// while the level above the frequency (through a highpass) is over
// "threshold" (dB), only the upper part is turned down, at 4:1 and by up to
// "range" dB, so the "s" softens and the rest of the voice doesn't move.
// "listen" plays only what it watches, to find the frequency.
class DeEsserEffect : public Effect
{
public:
    static constexpr double ratio = 4.0;

    [[nodiscard]] std::string_view type() const override { return "deesser"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // The cut (dB, positive), the largest since the last call.
    std::size_t takeMeters(std::span<float> out) override;
    void resume() noexcept override;

private:
    std::atomic<float> m_frequency{6000.0F};
    std::atomic<float> m_threshold{-30.0F};
    std::atomic<float> m_range{10.0F};
    std::atomic<bool> m_listen{false};
    std::atomic<float> m_meter{0.0F};
    // Realtime only.
    double m_rate = 48000.0;
    double m_designed = 0.0; // the frequency the filter was made for
    EqEffect::Coefficients m_filter; // the split's lowpass
    EqEffect::Coefficients m_detect; // the watched highpass
    std::array<std::array<double, 2>, maxEffectChannels> m_z{};
    std::array<std::array<double, 2>, maxEffectChannels> m_zDetect{};
    std::array<double, maxEffectChannels> m_high{};    // this sample's upper part per channel
    std::array<double, maxEffectChannels> m_watched{}; // and its highpassed sound
    double m_envelope = 0.0;
    double m_envelopeFall = 0.0; // ~30 ms
    double m_cutDb = 0.0;
    double m_attack = 0.0;  // ~1 ms
    double m_release = 0.0; // ~60 ms
};

// A downward expander: below "threshold" (dB) the sound is turned down
// "ratio" times as fast as it falls (1:2 means 10 dB under comes out 20 dB
// under), by at most "range" dB. Gentler than a gate on breaths and room
// sound between words. "attack" (opening) and "release" (closing) in ms.
class ExpanderEffect : public Effect
{
public:
    [[nodiscard]] std::string_view type() const override { return "expander"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // The cut (dB, positive), the largest since the last call.
    std::size_t takeMeters(std::span<float> out) override;

private:
    std::atomic<float> m_threshold{-45.0F};
    std::atomic<float> m_ratio{2.0F};
    std::atomic<float> m_range{20.0F};
    std::atomic<float> m_attack{2.0F};
    std::atomic<float> m_release{150.0F};
    std::atomic<float> m_meter{0.0F};
    // Realtime only.
    double m_rate = 48000.0;
    double m_envelope = 0.0;
    double m_envelopeFall = 0.0; // ~20 ms
    double m_cutDb = 0.0;
};

} // namespace pp
