// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/dynamics.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "dynamics.h"

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

} // namespace

// --- GainRider -----------------------------------------------------------------

void GainRider::prepare(double sampleRate)
{
    m_rate = sampleRate;
    m_held = 0.0;
}

void GainRider::setTimes(double attackMs, double holdMs, double releaseMs) noexcept
{
    m_attack = coefficient(attackMs, m_rate);
    m_release = coefficient(releaseMs, m_rate);
    m_holdSamples = holdMs * 0.001 * m_rate;
}

double GainRider::step(bool active, double activeDb, double restDb) noexcept
{
    if (active) {
        m_held = m_holdSamples;
    } else if (m_held > 0.0) {
        m_held -= 1.0;
        active = true;
    }
    const double target = active ? activeDb : restDb;
    const double k = active ? m_attack : m_release;
    m_gainDb = target + ((m_gainDb - target) * k);
    return std::pow(10.0, m_gainDb / 20.0);
}

// --- GateEffect ------------------------------------------------------------------

void GateEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rider.prepare(sampleRate);
    m_rider.reset(-m_range.load()); // starts closed, so nothing pops through
    m_envelope = 0.0;
    m_envelopeFall = coefficient(10.0, sampleRate);
    m_open = false;
}

void GateEffect::setParam(const std::string &name, double value)
{
    if (name == "threshold") {
        m_threshold = static_cast<float>(std::clamp(value, -80.0, 0.0));
    } else if (name == "range") {
        m_range = static_cast<float>(std::clamp(value, 0.0, 80.0));
    } else if (name == "attack") {
        m_attack = static_cast<float>(std::clamp(value, 0.1, 50.0));
    } else if (name == "hold") {
        m_hold = static_cast<float>(std::clamp(value, 0.0, 1000.0));
    } else if (name == "release") {
        m_release = static_cast<float>(std::clamp(value, 5.0, 2000.0));
    }
}

std::size_t GateEffect::takeMeters(std::span<float> out)
{
    if (out.empty()) {
        return 0;
    }
    out[0] = m_meter.exchange(0.0F);
    return 1;
}

void GateEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);
    const double threshold = m_threshold.load(std::memory_order_relaxed);
    const double range = m_range.load(std::memory_order_relaxed);
    m_rider.setTimes(m_attack.load(std::memory_order_relaxed),
                     m_hold.load(std::memory_order_relaxed),
                     m_release.load(std::memory_order_relaxed));
    double cut = 0.0;
    for (int i = 0; i < frames; ++i) {
        double peak = 0.0;
        for (float *plane : planes) {
            // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            peak = std::max(peak, static_cast<double>(std::abs(plane[i])));
        }
        m_envelope = std::max(peak, m_envelope * m_envelopeFall);
        const double level = 20.0 * std::log10(std::max(m_envelope, 1e-9));
        // Opens at the threshold, closes a little below it.
        m_open = m_open ? level > threshold - hysteresisDb : level > threshold;
        const auto gain =
            static_cast<float>(m_rider.step(m_open, 0.0, -range));
        for (float *plane : planes) {
            plane[i] *= gain; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        }
        cut = std::max(cut, -m_rider.gainDb());
    }
    if (m_envelope < 1e-20) {
        m_envelope = 0.0; // out of denormals in silence
    }
    raise(m_meter, static_cast<float>(cut));
}

// --- DuckerEffect ----------------------------------------------------------------

void DuckerEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rider.prepare(sampleRate);
    m_rider.reset(0.0);
    m_meanSquare = 0.0;
    m_rmsStep = 1.0 - coefficient(10.0, sampleRate);
}

void DuckerEffect::setParam(const std::string &name, double value)
{
    if (name == "threshold") {
        m_threshold = static_cast<float>(std::clamp(value, -60.0, 0.0));
    } else if (name == "depth") {
        m_depth = static_cast<float>(std::clamp(value, 0.0, 40.0));
    } else if (name == "attack") {
        m_attack = static_cast<float>(std::clamp(value, 1.0, 500.0));
    } else if (name == "hold") {
        m_hold = static_cast<float>(std::clamp(value, 0.0, 2000.0));
    } else if (name == "release") {
        m_release = static_cast<float>(std::clamp(value, 50.0, 5000.0));
    }
}

std::size_t DuckerEffect::takeMeters(std::span<float> out)
{
    if (out.empty()) {
        return 0;
    }
    out[0] = m_meter.exchange(0.0F);
    return 1;
}

void DuckerEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);
    const float *keySignal = key();
    const double threshold = m_threshold.load(std::memory_order_relaxed);
    const double depth = m_depth.load(std::memory_order_relaxed);
    m_rider.setTimes(m_attack.load(std::memory_order_relaxed),
                     m_hold.load(std::memory_order_relaxed),
                     m_release.load(std::memory_order_relaxed));
    double dip = 0.0;
    for (int i = 0; i < frames; ++i) {
        // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        const double k = keySignal != nullptr ? keySignal[i] : 0.0;
        m_meanSquare += ((k * k) - m_meanSquare) * m_rmsStep;
        const double level = 10.0 * std::log10(std::max(m_meanSquare, 1e-18));
        const auto gain =
            static_cast<float>(m_rider.step(level > threshold, -depth, 0.0));
        for (float *plane : planes) {
            plane[i] *= gain; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        }
        dip = std::max(dip, -m_rider.gainDb());
    }
    if (m_meanSquare < 1e-30) {
        m_meanSquare = 0.0; // out of denormals while the key is quiet
    }
    raise(m_meter, static_cast<float>(dip));
}

} // namespace pp
