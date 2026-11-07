// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/denoise.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "denoise.h"

#include <rnnoise.h>

#include <algorithm>
#include <cmath>
#include <span>

namespace pp {

namespace {

// RNNoise expects 16-bit sample values.
constexpr float scale = 32768.0F;

} // namespace

DenoiseEffect::~DenoiseEffect()
{
    release();
}

void DenoiseEffect::release()
{
    for (auto &c : m_channels) {
        if (c.state != nullptr) {
            rnnoise_destroy(c.state);
        }
    }
    m_channels.clear();
}

void DenoiseEffect::prepare(double rate, int channels)
{
    release();
    m_active = std::abs(rate - sampleRate) < 1.0;
    m_position = 0;
    m_amountNow = m_amount.load();
    m_smooth = static_cast<float>(1.0 - std::exp(-1.0 / (0.01 * rate)));
    if (!m_active) {
        return;
    }
    m_channels.resize(static_cast<std::size_t>(std::clamp(channels, 1, maxEffectChannels)));
    for (auto &c : m_channels) {
        c.state = rnnoise_create(nullptr); // the built-in model
    }
    if (std::ranges::any_of(m_channels, [](const Channel &c) { return c.state == nullptr; })) {
        release(); // out of memory: pass through rather than crash
        m_active = false;
    }
}

void DenoiseEffect::resume() noexcept
{
    // Coming back from bypass: forget the audio from before.
    m_position = 0;
    for (auto &c : m_channels) {
        c.in.fill(0.0F);
        c.out.fill(0.0F);
        c.dry.fill(0.0F);
    }
}

void DenoiseEffect::setParam(const std::string &name, double value)
{
    if (name == "amount") {
        m_amount = static_cast<float>(std::clamp(value, 0.0, 100.0) / 100.0);
    }
}

std::size_t DenoiseEffect::takeMeters(std::span<float> out)
{
    if (out.empty()) {
        return 0;
    }
    out[0] = m_meter.exchange(0.0F);
    return 1;
}

void DenoiseEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    if (!m_active) {
        return;
    }
    const std::size_t count =
        std::min(static_cast<std::size_t>(std::max(channelCount, 0)), m_channels.size());
    const std::span<float *const> planes(channels, count);
    const float amountTarget = m_amount.load(std::memory_order_relaxed);
    float voice = 0.0F;
    for (int i = 0; i < frames; ++i) {
        const auto at = static_cast<std::size_t>(m_position);
        m_amountNow += (amountTarget - m_amountNow) * m_smooth;
        const float amount = m_amountNow;
        for (std::size_t c = 0; c < count; ++c) {
            auto &ch = m_channels[c];
            // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            float &sample = planes[c][i];
            ch.in.at(at) = sample * scale;
            sample = (ch.dry.at(at) + ((ch.out.at(at) - ch.dry.at(at)) * amount)) / scale;
        }
        if (++m_position == frameSize) {
            m_position = 0;
            for (std::size_t c = 0; c < count; ++c) {
                auto &ch = m_channels[c];
                ch.dry = ch.in;
                voice = std::max(voice, rnnoise_process_frame(ch.state, ch.out.data(), ch.in.data()));
            }
        }
    }
    float current = m_meter.load(std::memory_order_relaxed);
    while (voice * 100.0F > current &&
           !m_meter.compare_exchange_weak(current, voice * 100.0F, std::memory_order_relaxed)) {
    }
}

} // namespace pp
