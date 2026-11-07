// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/delay.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include "effects.h"

#include <atomic>
#include <string>
#include <vector>

namespace pp {

// A plain delay, to line up outputs whose devices add different latency
// (Bluetooth headphones, an HDMI TV): delay the faster ones by "time" (ms).
// Changing the time crossfades from the old to the new over 20 ms, so it
// doesn't click.
class DelayEffect : public Effect
{
public:
    static constexpr double maxMs = 1000.0;
    static constexpr double fadeSeconds = 0.020;

    DelayEffect() = default;
    [[nodiscard]] std::string_view type() const override { return "delay"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    void resume() noexcept override;

private:
    std::atomic<float> m_timeMs{0.0F};
    // Realtime only (sized in prepare()).
    std::vector<std::vector<float>> m_lines; // per channel
    std::size_t m_write = 0;
    std::size_t m_delay = 0;    // samples, the one playing
    std::size_t m_next = 0;     // samples, fading in
    std::size_t m_fadeLeft = 0; // samples of the crossfade left
    std::size_t m_fadeLength = 1;
    double m_rate = 48000.0;
};

} // namespace pp
