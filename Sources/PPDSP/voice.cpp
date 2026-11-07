// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/voice.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "voice.h"

#include "multiband.h"

#include <algorithm>
#include <cmath>

namespace pp {

namespace {

// One-pole coefficient for a time constant in ms.
double coefficient(double ms, double sampleRate)
{
    return std::exp(-1.0 / (std::max(ms, 0.01) * 0.001 * sampleRate));
}

// Raises a meter to value; a compare-exchange, so a takeMeters() on the
// main thread in between can't lose it.
void raise(std::atomic<float> &meter, float value)
{
    float current = meter.load(std::memory_order_relaxed);
    while (value > current &&
           !meter.compare_exchange_weak(current, value, std::memory_order_relaxed)) {
    }
}

double toDb(double level)
{
    return 20.0 * std::log10(std::max(level, 1e-9));
}

// The loudest of the channels at sample i.
double linkedPeak(std::span<float *const> planes, int i)
{
    double peak = 0.0;
    for (const float *plane : planes) {
        // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        peak = std::max(peak, static_cast<double>(std::abs(plane[i])));
    }
    return peak;
}

} // namespace

// --- CompressorEffect -------------------------------------------------------------

CompressorEffect::Settings CompressorEffect::fromAmount(double amount)
{
    const double a = std::clamp(amount, 0.0, 100.0) / 100.0;
    Settings s;
    s.threshold = -10.0 - (25.0 * a);
    s.ratio = 1.0 + (5.0 * a);
    s.attack = 5.0;
    s.release = 120.0;
    // Half of what a full-scale peak loses: speech comes back up about as
    // loud as before, only steadier.
    s.makeup = 0.5 * -s.threshold * (1.0 - (1.0 / s.ratio));
    return s;
}

void CompressorEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rate = sampleRate;
    m_glide = 1.0 - coefficient(20.0, sampleRate);
    m_envelopeFall = coefficient(10.0, sampleRate);
    m_envelope = 0.0;
    m_reductionDb = 0.0;
    const double makeup = m_advanced ? m_makeup.load() : fromAmount(m_amount).makeup;
    m_makeupNow = std::pow(10.0, makeup / 20.0);
}

void CompressorEffect::resume() noexcept
{
    m_envelope = 0.0;
    m_reductionDb = 0.0;
}

void CompressorEffect::setParam(const std::string &name, double value)
{
    if (name == "amount") {
        m_amount = static_cast<float>(std::clamp(value, 0.0, 100.0));
    } else if (name == "advanced") {
        m_advanced = value >= 0.5;
    } else if (name == "threshold") {
        m_threshold = static_cast<float>(std::clamp(value, -60.0, 0.0));
    } else if (name == "ratio") {
        m_ratio = static_cast<float>(std::clamp(value, 1.0, 20.0));
    } else if (name == "attack") {
        m_attack = static_cast<float>(std::clamp(value, 0.1, 200.0));
    } else if (name == "release") {
        m_release = static_cast<float>(std::clamp(value, 10.0, 3000.0));
    } else if (name == "makeup") {
        m_makeup = static_cast<float>(std::clamp(value, -12.0, 24.0));
    }
}

std::size_t CompressorEffect::takeMeters(std::span<float> out)
{
    if (out.size() < 2) {
        return 0;
    }
    out[0] = m_meter.exchange(0.0F);
    out[1] = m_inUse.load();
    return 2;
}

void CompressorEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);
    Settings s;
    if (m_advanced.load(std::memory_order_relaxed)) {
        s = {.threshold = m_threshold.load(std::memory_order_relaxed),
             .ratio = m_ratio.load(std::memory_order_relaxed),
             .attack = m_attack.load(std::memory_order_relaxed),
             .release = m_release.load(std::memory_order_relaxed),
             .makeup = m_makeup.load(std::memory_order_relaxed)};
    } else {
        s = fromAmount(m_amount.load(std::memory_order_relaxed));
    }
    m_inUse.store(static_cast<float>(s.threshold), std::memory_order_relaxed);
    const double attack = coefficient(s.attack, m_rate);
    const double release = coefficient(s.release, m_rate);
    const double makeup = std::pow(10.0, s.makeup / 20.0);
    double most = 0.0;
    for (int i = 0; i < frames; ++i) {
        // The level holds each peak and falls away over ~10 ms, so the
        // dips inside every cycle don't read as quiet.
        m_envelope = std::max(linkedPeak(planes, i), m_envelope * m_envelopeFall);
        const double level = toDb(m_envelope);
        const double wanted = level - MultibandEffect::staticCurve(level, s.threshold, s.ratio);
        const double k = wanted > m_reductionDb ? attack : release;
        m_reductionDb = wanted + ((m_reductionDb - wanted) * k);
        m_makeupNow += (makeup - m_makeupNow) * m_glide;
        const auto gain = static_cast<float>(std::pow(10.0, -m_reductionDb / 20.0) * m_makeupNow);
        for (float *plane : planes) {
            plane[i] *= gain; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        }
        most = std::max(most, m_reductionDb);
    }
    if (m_envelope < 1e-20) {
        m_envelope = 0.0; // out of denormals in silence
    }
    raise(m_meter, static_cast<float>(most));
}

// --- DeEsserEffect ------------------------------------------------------------------

void DeEsserEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rate = sampleRate;
    m_designed = 0.0;
    m_envelopeFall = coefficient(30.0, sampleRate);
    m_attack = coefficient(1.0, sampleRate);
    m_release = coefficient(60.0, sampleRate);
    resume();
}

void DeEsserEffect::resume() noexcept
{
    m_z = {};
    m_zDetect = {};
    m_envelope = 0.0;
    m_cutDb = 0.0;
}

void DeEsserEffect::setParam(const std::string &name, double value)
{
    if (name == "frequency") {
        m_frequency = static_cast<float>(std::clamp(value, 2000.0, 12000.0));
    } else if (name == "threshold") {
        m_threshold = static_cast<float>(std::clamp(value, -60.0, 0.0));
    } else if (name == "range") {
        m_range = static_cast<float>(std::clamp(value, 0.0, 24.0));
    } else if (name == "listen") {
        m_listen = value >= 0.5;
    }
}

std::size_t DeEsserEffect::takeMeters(std::span<float> out)
{
    if (out.empty()) {
        return 0;
    }
    out[0] = m_meter.exchange(0.0F);
    return 1;
}

void DeEsserEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);
    if (const double freq = m_frequency.load(std::memory_order_relaxed); freq != m_designed) {
        m_filter = EqEffect::coefficients(
            {.on = true, .type = EqEffect::BandType::HighCut, .freq = freq, .gainDb = 0.0, .q = 0.707},
            m_rate);
        m_detect = EqEffect::coefficients(
            {.on = true, .type = EqEffect::BandType::LowCut, .freq = freq, .gainDb = 0.0, .q = 0.707},
            m_rate);
        m_designed = freq;
    }
    const double threshold = m_threshold.load(std::memory_order_relaxed);
    const double range = m_range.load(std::memory_order_relaxed);
    const bool listen = m_listen.load(std::memory_order_relaxed);
    // A biquad step (transposed direct form II).
    const auto run = [](const EqEffect::Coefficients &c, std::array<double, 2> &z, double x) {
        const double y = (c.b0 * x) + z[0];
        z[0] = (c.b1 * x) - (c.a1 * y) + z[1];
        z[1] = (c.b2 * x) - (c.a2 * y);
        return y;
    };
    double most = 0.0;
    for (int i = 0; i < frames; ++i) {
        double peak = 0.0;
        for (std::size_t ch = 0; ch < count; ++ch) {
            // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            const double x = planes[ch][i];
            // What's turned down: the input less its low part, so the two
            // always add back up to the input exactly.
            m_high.at(ch) = x - run(m_filter, m_z.at(ch), x);
            // What's watched (and heard with Listen): a true highpass, so
            // a loud low voice doesn't set it off.
            const double watched = run(m_detect, m_zDetect.at(ch), x);
            m_watched.at(ch) = watched;
            peak = std::max(peak, std::abs(watched));
        }
        m_envelope = std::max(peak, m_envelope * m_envelopeFall);
        const double over = toDb(m_envelope) - threshold;
        const double wanted = std::clamp(over * (1.0 - (1.0 / ratio)), 0.0, range);
        const double k = wanted > m_cutDb ? m_attack : m_release;
        m_cutDb = wanted + ((m_cutDb - wanted) * k);
        // The high part is taken out by as much as it's turned down.
        const double takeOut = 1.0 - std::pow(10.0, -m_cutDb / 20.0);
        for (std::size_t ch = 0; ch < count; ++ch) {
            // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            float &sample = planes[ch][i];
            sample = static_cast<float>(listen ? m_watched.at(ch) : sample - (takeOut * m_high.at(ch)));
        }
        most = std::max(most, m_cutDb);
    }
    if (m_envelope < 1e-20) {
        m_envelope = 0.0; // out of denormals in silence
    }
    for (std::size_t ch = 0; ch < count; ++ch) {
        for (auto *state : {&m_z.at(ch), &m_zDetect.at(ch)}) {
            for (double &z : *state) {
                if (std::abs(z) < 1e-30) {
                    z = 0.0;
                }
            }
        }
    }
    raise(m_meter, static_cast<float>(most));
}

// --- ExpanderEffect ---------------------------------------------------------------

void ExpanderEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rate = sampleRate;
    m_envelope = 0.0;
    m_envelopeFall = coefficient(20.0, sampleRate);
    m_cutDb = m_range.load(); // starts closed, so nothing pops through
}

void ExpanderEffect::setParam(const std::string &name, double value)
{
    if (name == "threshold") {
        m_threshold = static_cast<float>(std::clamp(value, -80.0, 0.0));
    } else if (name == "ratio") {
        m_ratio = static_cast<float>(std::clamp(value, 1.0, 8.0));
    } else if (name == "range") {
        m_range = static_cast<float>(std::clamp(value, 0.0, 60.0));
    } else if (name == "attack") {
        m_attack = static_cast<float>(std::clamp(value, 0.1, 50.0));
    } else if (name == "release") {
        m_release = static_cast<float>(std::clamp(value, 10.0, 2000.0));
    }
}

std::size_t ExpanderEffect::takeMeters(std::span<float> out)
{
    if (out.empty()) {
        return 0;
    }
    out[0] = m_meter.exchange(0.0F);
    return 1;
}

void ExpanderEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);
    const double threshold = m_threshold.load(std::memory_order_relaxed);
    const double ratio = m_ratio.load(std::memory_order_relaxed);
    const double range = m_range.load(std::memory_order_relaxed);
    const double attack = coefficient(m_attack.load(std::memory_order_relaxed), m_rate);
    const double release = coefficient(m_release.load(std::memory_order_relaxed), m_rate);
    double most = 0.0;
    for (int i = 0; i < frames; ++i) {
        m_envelope = std::max(linkedPeak(planes, i), m_envelope * m_envelopeFall);
        const double under = threshold - toDb(m_envelope);
        const double wanted = std::clamp(under * (ratio - 1.0), 0.0, range);
        // Less cut is opening (attack); more is closing (release).
        const double k = wanted < m_cutDb ? attack : release;
        m_cutDb = wanted + ((m_cutDb - wanted) * k);
        const auto gain = static_cast<float>(std::pow(10.0, -m_cutDb / 20.0));
        for (float *plane : planes) {
            plane[i] *= gain; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        }
        most = std::max(most, m_cutDb);
    }
    if (m_envelope < 1e-20) {
        m_envelope = 0.0; // out of denormals in silence
    }
    raise(m_meter, static_cast<float>(most));
}

} // namespace pp
