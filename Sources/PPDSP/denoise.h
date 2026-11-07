// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/denoise.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include "effects.h"

#include <array>
#include <atomic>
#include <string>
#include <vector>

// RNNoise's state (rnnoise.h); only the pointer is needed here.
struct DenoiseState;

namespace pp {

// Noise suppression for voice with RNNoise (a small neural network from
// Xiph.Org): fans, hum, keyboard and room noise are taken out of a mic.
// "amount" (0-100 %) blends the cleaned voice with the original.
//
// RNNoise works on 10 ms frames at 48 kHz, so this adds 10 ms of latency
// (the original is delayed to match for the blend). At any other sample rate
// it passes the audio through unchanged.
class DenoiseEffect : public Effect
{
public:
    static constexpr int frameSize = 480; // 10 ms at 48 kHz
    static constexpr double sampleRate = 48000.0;

    DenoiseEffect() = default;
    ~DenoiseEffect() override;
    DenoiseEffect(const DenoiseEffect &) = delete;
    DenoiseEffect &operator=(const DenoiseEffect &) = delete;
    DenoiseEffect(DenoiseEffect &&) = delete;
    DenoiseEffect &operator=(DenoiseEffect &&) = delete;

    [[nodiscard]] std::string_view type() const override { return "denoise"; }
    void prepare(double rate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;
    void resume() noexcept override;
    // The voice probability RNNoise saw, as a percentage (the largest since
    // the last call).
    std::size_t takeMeters(std::span<float> out) override;
    // One frame, while it works (at 48 kHz; otherwise it passes the sound
    // through as it is).
    [[nodiscard]] int latency() const override { return m_active ? frameSize : 0; }

private:
    struct Channel
    {
        DenoiseState *state = nullptr;
        std::array<float, frameSize> in{};  // being filled (RNNoise scale)
        std::array<float, frameSize> out{}; // cleaned, being played out
        std::array<float, frameSize> dry{}; // the original of `out`
    };

    void release();

    std::atomic<float> m_amount{1.0F}; // 0..1
    std::atomic<float> m_meter{0.0F};
    // Realtime only (made in prepare()).
    std::vector<Channel> m_channels;
    int m_position = 0; // within the current frame
    float m_amountNow = 1.0F; // smoothed (~10 ms)
    float m_smooth = 1.0F;
    bool m_active = false; // false: not at 48 kHz, pass through
};

} // namespace pp
