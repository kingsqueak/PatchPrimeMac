// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/delay.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "delay.h"

#include <algorithm>
#include <cmath>
#include <span>

namespace pp {

void DelayEffect::prepare(double sampleRate, int channels)
{
    m_rate = sampleRate;
    const auto size = static_cast<std::size_t>(std::ceil(maxMs * 0.001 * sampleRate)) + 1;
    m_lines.assign(static_cast<std::size_t>(std::clamp(channels, 1, maxEffectChannels)),
                   std::vector<float>(size, 0.0F));
    m_fadeLength = std::max<std::size_t>(1, static_cast<std::size_t>(fadeSeconds * sampleRate));
    m_delay = static_cast<std::size_t>(std::lround(m_timeMs.load() * 0.001 * sampleRate));
    m_next = m_delay;
    m_fadeLeft = 0;
    m_write = 0;
}

void DelayEffect::resume() noexcept
{
    for (auto &line : m_lines) {
        std::ranges::fill(line, 0.0F);
    }
}

void DelayEffect::setParam(const std::string &name, double value)
{
    if (name == "time") {
        m_timeMs = static_cast<float>(std::clamp(value, 0.0, maxMs));
    }
}

void DelayEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    if (m_lines.empty()) {
        return;
    }
    const std::size_t count =
        std::min(static_cast<std::size_t>(std::max(channelCount, 0)), m_lines.size());
    const std::span<float *const> planes(channels, count);
    const std::size_t size = m_lines.front().size();
    const auto wanted = std::min(
        size - 1, static_cast<std::size_t>(
                      std::lround(m_timeMs.load(std::memory_order_relaxed) * 0.001 * m_rate)));
    for (int i = 0; i < frames; ++i) {
        // A new time starts a crossfade (once the previous one is done).
        if (m_fadeLeft == 0 && wanted != m_delay) {
            m_next = wanted;
            m_fadeLeft = m_fadeLength;
        }
        const float toNext =
            m_fadeLeft == 0
                ? 0.0F
                : 1.0F - (static_cast<float>(m_fadeLeft) / static_cast<float>(m_fadeLength));
        for (std::size_t c = 0; c < count; ++c) {
            auto &line = m_lines[c];
            // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            float &sample = planes[c][i];
            line[m_write] = sample;
            const float now = line[(m_write + size - m_delay) % size];
            if (m_fadeLeft == 0) {
                sample = now;
            } else {
                const float next = line[(m_write + size - m_next) % size];
                sample = now + ((next - now) * toNext);
            }
        }
        if (m_fadeLeft > 0) {
            --m_fadeLeft;
            if (m_fadeLeft == 0) {
                m_delay = m_next;
            }
        }
        m_write = (m_write + 1) % size;
    }
}

} // namespace pp
