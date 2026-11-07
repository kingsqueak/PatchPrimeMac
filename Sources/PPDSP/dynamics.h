// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/dynamics.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include "effects.h"

#include <atomic>
#include <span>
#include <string>

namespace pp {

// Gain that opens and closes with attack, hold and release, in dB: shared by
// the gate and the ducker. Realtime only.
class GainRider
{
public:
    void prepare(double sampleRate);
    void reset(double gainDb) { m_gainDb = gainDb; }
    // Times for the coming block, in ms (main or realtime thread; no allocation).
    void setTimes(double attackMs, double holdMs, double releaseMs) noexcept;
    // One sample: rides towards activeDb while `active` (with the attack
    // time), and for the hold time after, then back towards restDb (with the
    // release time). Returns the linear gain.
    double step(bool active, double activeDb, double restDb) noexcept;
    [[nodiscard]] double gainDb() const { return m_gainDb; }

private:
    double m_rate = 48000.0;
    double m_gainDb = 0.0;
    double m_held = 0.0; // samples of hold left
    double m_attack = 0.0; // one-pole coefficients
    double m_release = 0.0;
    double m_holdSamples = 0.0;
};

// A noise gate: below the threshold (with 4 dB of hysteresis) the strip is
// turned down by "range" dB, so breaths, keyboard and room noise between
// words don't reach the mix. Parameters: "threshold" (dB), "range" (dB of
// cut when closed), "attack", "hold", "release" (ms). Channels linked.
class GateEffect : public Effect
{
public:
    static constexpr double hysteresisDb = 4.0;

    GateEffect() = default;
    [[nodiscard]] std::string_view type() const override { return "gate"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // The cut now (dB, positive), the largest since the last call.
    std::size_t takeMeters(std::span<float> out) override;

private:
    std::atomic<float> m_threshold{-50.0F};
    std::atomic<float> m_range{40.0F};
    std::atomic<float> m_attack{1.0F};
    std::atomic<float> m_hold{100.0F};
    std::atomic<float> m_release{150.0F};
    std::atomic<float> m_meter{0.0F};
    // Realtime only.
    GainRider m_rider;
    double m_envelope = 0.0;
    double m_envelopeFall = 0.0; // per sample, ~10 ms
    bool m_open = false;
};

// A ducker: turns this strip down by "depth" dB while another strip (its
// key, chosen in the strip's settings) is above "threshold": music under a
// voice. "attack", "hold", "release" in ms. With no key it does nothing.
class DuckerEffect : public Effect
{
public:
    DuckerEffect() = default;
    [[nodiscard]] std::string_view type() const override { return "ducker"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    // The dip now (dB, positive), the largest since the last call.
    std::size_t takeMeters(std::span<float> out) override;

private:
    std::atomic<float> m_threshold{-35.0F};
    std::atomic<float> m_depth{12.0F};
    std::atomic<float> m_attack{20.0F};
    std::atomic<float> m_hold{250.0F};
    std::atomic<float> m_release{600.0F};
    std::atomic<float> m_meter{0.0F};
    // Realtime only.
    GainRider m_rider;
    double m_meanSquare = 0.0;
    double m_rmsStep = 1.0; // ~10 ms
};

} // namespace pp
