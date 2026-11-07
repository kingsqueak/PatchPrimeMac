// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/reverb.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "reverb.h"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <span>

namespace pp {

namespace {

// Line lengths in ms at size factor 1: spread out and not multiples of each
// other, so their echoes don't pile up on the same moments.
constexpr std::array<double, ReverbEffect::lineCount> lineMs{29.7, 37.1, 41.1, 43.7,
                                                             53.3, 59.9, 67.1, 79.3};
// Diffuser lengths in samples at 44.1 kHz (Schroeder/Freeverb style).
constexpr std::array<double, 4> diffuserSamples{142.0, 107.0, 379.0, 277.0};
constexpr float diffusion = 0.7F;
constexpr double minScale = 0.3; // size 0 %
constexpr double maxScale = 1.7; // size 100 %
// How each line feeds left and right: different signs decorrelate them.
constexpr std::array<float, ReverbEffect::lineCount> toLeft{1, -1, 1, -1, 1, -1, 1, -1};
constexpr std::array<float, ReverbEffect::lineCount> toRight{1, 1, -1, -1, 1, 1, -1, -1};
constexpr float outputGain = 0.35F;

double scaleFor(double sizePercent)
{
    return minScale + ((maxScale - minScale) * std::clamp(sizePercent, 0.0, 100.0) / 100.0);
}

} // namespace

// --- Line, Allpass ---------------------------------------------------------------

void ReverbEffect::Line::push(float x) noexcept
{
    buffer[write] = x;
    write = (write + 1) % buffer.size();
}

float ReverbEffect::Line::read(double delay) const noexcept
{
    const std::size_t size = buffer.size();
    delay = std::clamp(delay, 1.0, static_cast<double>(size - 1));
    const auto whole = static_cast<std::size_t>(delay);
    const auto fraction = static_cast<float>(delay - static_cast<double>(whole));
    const std::size_t newer = (write + size - whole) % size;
    const std::size_t older = (newer + size - 1) % size;
    return (buffer[newer] * (1.0F - fraction)) + (buffer[older] * fraction);
}

float ReverbEffect::Allpass::step(float x) noexcept
{
    const float delayed = buffer[at];
    const float y = delayed - (diffusion * x);
    buffer[at] = x + (diffusion * y);
    at = (at + 1) % buffer.size();
    return y;
}

// --- ReverbEffect ------------------------------------------------------------------

void ReverbEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rate = sampleRate;
    m_modDepth = 0.00015 * sampleRate; // about 7 samples at 48 kHz
    m_phaseStep = 2.0 * std::numbers::pi * 0.5 / sampleRate;
    for (std::size_t i = 0; i < m_lines.size(); ++i) {
        m_base.at(i) = lineMs.at(i) * 0.001 * sampleRate;
        m_lines.at(i).buffer.assign(
            // The modulation adds up to twice its depth.
            static_cast<std::size_t>(std::ceil((m_base.at(i) * maxScale) + (2.0 * m_modDepth) + 4.0)),
            0.0F);
    }
    for (std::size_t i = 0; i < m_diffusers.size(); ++i) {
        m_diffusers.at(i).buffer.assign(
            static_cast<std::size_t>(std::max(1.0, std::round(diffuserSamples.at(i) * sampleRate / 44100.0))),
            0.0F);
    }
    m_pre.buffer.assign(static_cast<std::size_t>(std::ceil(maxPredelayMs * 0.001 * sampleRate)) + 4,
                        0.0F);
    m_scale = m_scaleTarget = scaleFor(m_size.load());
    m_preSamples = m_preTarget = m_predelay.load() * 0.001 * sampleRate;
    m_sampleGlide = 1.0 - std::exp(-1.0 / (0.1 * sampleRate));
    m_smooth = static_cast<float>(1.0 - std::exp(-1.0 / (0.01 * sampleRate)));
    m_mixNow = m_mix.load() / 100.0F;
    m_widthNow = m_width.load() / 100.0F;
    const bool on = enabled.load();
    m_onNow = on ? 1.0F : 0.0F;
    m_onStep = static_cast<float>(1.0 / std::max(1.0, EffectChain::crossfadeSeconds * sampleRate));
    m_quietFrames = 0;
    m_sleepFrames = static_cast<int>(quietSeconds * sampleRate);
    m_asleep = !on;
    clear();
    updateBlock();
}

void ReverbEffect::clear() noexcept
{
    for (auto &line : m_lines) {
        std::ranges::fill(line.buffer, 0.0F);
        line.write = 0;
    }
    for (auto &allpass : m_diffusers) {
        std::ranges::fill(allpass.buffer, 0.0F);
        allpass.at = 0;
    }
    std::ranges::fill(m_pre.buffer, 0.0F);
    m_pre.write = 0;
    m_lowpass.fill(0.0F);
}

void ReverbEffect::setParam(const std::string &name, double value)
{
    if (name == "size") {
        m_size = static_cast<float>(std::clamp(value, 0.0, 100.0));
    } else if (name == "decay") {
        m_decay = static_cast<float>(std::clamp(value, 0.2, 10.0));
    } else if (name == "predelay") {
        m_predelay = static_cast<float>(std::clamp(value, 0.0, maxPredelayMs));
    } else if (name == "damping") {
        m_damping = static_cast<float>(std::clamp(value, 0.0, 100.0));
    } else if (name == "width") {
        m_width = static_cast<float>(std::clamp(value, 0.0, 100.0));
    } else if (name == "mix") {
        m_mix = static_cast<float>(std::clamp(value, 0.0, 100.0));
    }
}

void ReverbEffect::updateBlock() noexcept
{
    // Size and pre-delay glide sample by sample (in process()), so the read
    // positions never jump.
    m_scaleTarget = scaleFor(m_size.load(std::memory_order_relaxed));
    m_preTarget = m_predelay.load(std::memory_order_relaxed) * 0.001 * m_rate;
    // Each pass through a line loses its share of 60 dB per decay time.
    const double decay = m_decay.load(std::memory_order_relaxed);
    for (std::size_t i = 0; i < m_lines.size(); ++i) {
        const double length = m_base.at(i) * m_scale;
        m_gain.at(i) = std::pow(10.0, -3.0 * length / (decay * m_rate));
    }
    // Damping: the lines' low-pass from 20 kHz (0 %) down to 1.5 kHz (100 %).
    const double damping = m_damping.load(std::memory_order_relaxed) / 100.0;
    const double cutoff = std::min(20000.0 * std::pow(1500.0 / 20000.0, damping), 0.45 * m_rate);
    m_damp = static_cast<float>(1.0 - std::exp(-2.0 * std::numbers::pi * cutoff / m_rate));
}

void ReverbEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    if (count == 0) {
        return;
    }
    const bool on = enabled.load(std::memory_order_relaxed);
    if (m_asleep) {
        if (!on) {
            return; // the dry signal, untouched
        }
        m_asleep = false;
        m_quietFrames = 0;
    }
    const std::span<float *const> planes(channels, count);
    const float onTarget = on ? 1.0F : 0.0F;
    float peak = 0.0F;
    const auto mixTarget = m_mix.load(std::memory_order_relaxed) / 100.0F;
    const auto widthTarget = m_width.load(std::memory_order_relaxed) / 100.0F;
    const float inScale = 1.0F / static_cast<float>(count);
    for (int start = 0; start < frames; start += blockFrames) {
        updateBlock();
        const int end = std::min(frames, start + blockFrames);
        for (int i = start; i < end; ++i) {
            float in = 0.0F;
            for (float *plane : planes) {
                in += plane[i]; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            }
            m_onNow = onTarget > m_onNow ? std::min(onTarget, m_onNow + m_onStep)
                                         : std::max(onTarget, m_onNow - m_onStep);
            m_pre.push(in * inScale * m_onNow);
            m_scale += (m_scaleTarget - m_scale) * m_sampleGlide;
            m_preSamples += (m_preTarget - m_preSamples) * m_sampleGlide;
            m_mixNow += (mixTarget - m_mixNow) * m_smooth;
            m_widthNow += (widthTarget - m_widthNow) * m_smooth;
            // (The tiny alternating offset keeps the diffusers out of denormals.)
            float x = m_pre.read(std::max(1.0, m_preSamples)) + m_denormal;
            for (auto &allpass : m_diffusers) {
                x = allpass.step(x);
            }

            // Read the lines (two of them slowly wandering), damp, decay, mix.
            m_phase += m_phaseStep;
            if (m_phase > 2.0 * std::numbers::pi) {
                m_phase -= 2.0 * std::numbers::pi;
            }
            m_phase2 += m_phaseStep * 0.7;
            if (m_phase2 > 2.0 * std::numbers::pi) {
                m_phase2 -= 2.0 * std::numbers::pi;
            }
            std::array<float, lineCount> out{};
            std::array<float, lineCount> fed{};
            float sum = 0.0F;
            for (std::size_t l = 0; l < out.size(); ++l) {
                double length = m_base.at(l) * m_scale;
                if (l == 0) {
                    length += m_modDepth * (1.0 + std::sin(m_phase));
                } else if (l == 4) {
                    length += m_modDepth * (1.0 + std::cos(m_phase2));
                }
                out.at(l) = m_lines.at(l).read(length);
                m_lowpass.at(l) += m_damp * (out.at(l) - m_lowpass.at(l));
                fed.at(l) = static_cast<float>(m_gain.at(l)) * m_lowpass.at(l);
                sum += fed.at(l);
            }
            // Householder feedback: lossless, every line feeds every other.
            const float spread = sum * (2.0F / static_cast<float>(lineCount));
            float left = 0.0F;
            float right = 0.0F;
            for (std::size_t l = 0; l < out.size(); ++l) {
                m_lines.at(l).push(fed.at(l) - spread + x + m_denormal);
                left += out.at(l) * toLeft.at(l);
                right += out.at(l) * toRight.at(l);
            }
            m_denormal = -m_denormal; // keeps the lines out of denormals without a DC offset
            left *= outputGain;
            right *= outputGain;
            // Width: from mono (0 %) to the full spread.
            const float mid = (left + right) * 0.5F;
            const float side = (left - right) * 0.5F * m_widthNow;
            left = mid + side;
            right = mid - side;
            peak = std::max({peak, std::abs(left), std::abs(right)});

            for (std::size_t c = 0; c < count; ++c) {
                float wet = 0.5F * (left + right); // one channel: both sides
                if (count > 1) {
                    wet = c % 2 == 0 ? left : right;
                }
                // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
                float &sample = planes[c][i];
                // On: dry and wet by the mix. Bypassed: all the dry, and the tail.
                sample = (sample * (1.0F - (m_mixNow * m_onNow))) + (wet * m_mixNow);
            }
        }
    }
    if (on || m_onNow > 0.0F || peak >= quietLevel) {
        m_quietFrames = 0;
    } else {
        m_quietFrames += frames;
        if (m_quietFrames >= m_sleepFrames) {
            clear();
            m_asleep = true;
        }
    }
    // Damping filters out of denormals once the tail is gone.
    for (float &v : m_lowpass) {
        if (std::abs(v) < 1e-20F) {
            v = 0.0F;
        }
    }
}

} // namespace pp
