// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/eq.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "eq.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <numbers>
#include <span>

namespace pp {

namespace {

// "b3Freq" -> band 2 (0-based), "Freq"; false when it isn't a band parameter.
bool splitParam(const std::string &name, int &band, std::string_view &field)
{
    if (name.size() < 3 || name[0] != 'b' || name[1] < '1' ||
        name[1] > static_cast<char>('0' + EqEffect::bandCount)) {
        return false;
    }
    band = name[1] - '1';
    field = std::string_view(name).substr(2);
    return true;
}

bool near(double a, double b, double tolerance)
{
    return std::abs(a - b) <= tolerance;
}

} // namespace

EqEffect::Band EqEffect::defaultBand(int index)
{
    static constexpr std::array<Band, bandCount> defaults{{
        {.on = true, .type = BandType::LowShelf, .freq = 80.0, .gainDb = 0.0, .q = 0.707},
        {.on = true, .type = BandType::Bell, .freq = 250.0, .gainDb = 0.0, .q = 1.0},
        {.on = true, .type = BandType::Bell, .freq = 1000.0, .gainDb = 0.0, .q = 1.0},
        {.on = true, .type = BandType::Bell, .freq = 3000.0, .gainDb = 0.0, .q = 1.0},
        {.on = true, .type = BandType::Bell, .freq = 6000.0, .gainDb = 0.0, .q = 1.0},
        {.on = true, .type = BandType::HighShelf, .freq = 12000.0, .gainDb = 0.0, .q = 0.707},
    }};
    return defaults.at(static_cast<std::size_t>(std::clamp(index, 0, bandCount - 1)));
}

std::string EqEffect::typeName(BandType type)
{
    switch (type) {
    case BandType::Bell:
        return "Bell";
    case BandType::LowShelf:
        return "Low shelf";
    case BandType::HighShelf:
        return "High shelf";
    case BandType::LowCut:
        return "Low cut";
    case BandType::HighCut:
        return "High cut";
    }
    return "Bell";
}

EqEffect::Coefficients EqEffect::coefficients(const Band &band, double sampleRate)
{
    // Keep clear of Nyquist, where the formulas fall apart.
    const double freq = std::clamp(band.freq, minFreq, std::min(maxFreq, 0.45 * sampleRate));
    const double q = std::clamp(band.q, minQ, maxQ);
    const double gain = std::clamp(band.gainDb, minGain, maxGain);
    const double w0 = 2.0 * std::numbers::pi * freq / sampleRate;
    const double cosw = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * q);
    const double a = std::pow(10.0, gain / 40.0);
    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a0 = 1.0;
    double a1 = 0.0;
    double a2 = 0.0;
    switch (band.type) {
    case BandType::Bell:
        b0 = 1.0 + (alpha * a);
        b1 = -2.0 * cosw;
        b2 = 1.0 - (alpha * a);
        a0 = 1.0 + (alpha / a);
        a1 = -2.0 * cosw;
        a2 = 1.0 - (alpha / a);
        break;
    case BandType::LowShelf: {
        const double s = 2.0 * std::sqrt(a) * alpha;
        b0 = a * ((a + 1.0) - ((a - 1.0) * cosw) + s);
        b1 = 2.0 * a * ((a - 1.0) - ((a + 1.0) * cosw));
        b2 = a * ((a + 1.0) - ((a - 1.0) * cosw) - s);
        a0 = (a + 1.0) + ((a - 1.0) * cosw) + s;
        a1 = -2.0 * ((a - 1.0) + ((a + 1.0) * cosw));
        a2 = (a + 1.0) + ((a - 1.0) * cosw) - s;
        break;
    }
    case BandType::HighShelf: {
        const double s = 2.0 * std::sqrt(a) * alpha;
        b0 = a * ((a + 1.0) + ((a - 1.0) * cosw) + s);
        b1 = -2.0 * a * ((a - 1.0) + ((a + 1.0) * cosw));
        b2 = a * ((a + 1.0) + ((a - 1.0) * cosw) - s);
        a0 = (a + 1.0) - ((a - 1.0) * cosw) + s;
        a1 = 2.0 * ((a - 1.0) - ((a + 1.0) * cosw));
        a2 = (a + 1.0) - ((a - 1.0) * cosw) - s;
        break;
    }
    case BandType::LowCut:
        b0 = (1.0 + cosw) / 2.0;
        b1 = -(1.0 + cosw);
        b2 = (1.0 + cosw) / 2.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosw;
        a2 = 1.0 - alpha;
        break;
    case BandType::HighCut:
        b0 = (1.0 - cosw) / 2.0;
        b1 = 1.0 - cosw;
        b2 = (1.0 - cosw) / 2.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosw;
        a2 = 1.0 - alpha;
        break;
    }
    return {.b0 = b0 / a0, .b1 = b1 / a0, .b2 = b2 / a0, .a1 = a1 / a0, .a2 = a2 / a0};
}

double EqEffect::responseDb(const std::vector<Band> &bands, double freq, double sampleRate)
{
    const double w = 2.0 * std::numbers::pi * freq / sampleRate;
    const std::complex<double> z1 = std::polar(1.0, -w);
    const std::complex<double> z2 = z1 * z1;
    double db = 0.0;
    for (const auto &band : bands) {
        if (!band.on) {
            continue;
        }
        const auto c = coefficients(band, sampleRate);
        const auto h = (c.b0 + (c.b1 * z1) + (c.b2 * z2)) / (1.0 + (c.a1 * z1) + (c.a2 * z2));
        db += 20.0 * std::log10(std::max(std::abs(h), 1e-9));
    }
    return db;
}

EqEffect::EqEffect()
{
    for (int i = 0; i < bandCount; ++i) {
        const auto band = defaultBand(i);
        auto &t = m_target.at(static_cast<std::size_t>(i));
        t.on = band.on;
        t.type = static_cast<int>(band.type);
        t.freq = static_cast<float>(band.freq);
        t.gainDb = static_cast<float>(band.gainDb);
        t.q = static_cast<float>(band.q);
    }
}

void EqEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rate = sampleRate;
    // Glide time constant about 20 ms, applied once per block.
    m_glide = 1.0 - std::exp(-static_cast<double>(blockFrames) / (0.020 * sampleRate));
    m_fadeStep = static_cast<float>(1.0 / std::max(1.0, 0.010 * sampleRate)); // 10 ms
    // Start where the parameters are, with no glide.
    for (int i = 0; i < bandCount; ++i) {
        const auto &t = m_target.at(static_cast<std::size_t>(i));
        auto &s = m_state.at(static_cast<std::size_t>(i));
        s.now = {.on = t.on.load(),
                 .type = static_cast<BandType>(t.type.load()),
                 .freq = t.freq.load(),
                 .gainDb = t.gainDb.load(),
                 .q = t.q.load()};
        s.mix = s.now.on ? 1.0F : 0.0F;
        s.fresh = true;
        s.z = {};
    }
}

void EqEffect::resume() noexcept
{
    for (auto &s : m_state) {
        s.z = {};
    }
}

void EqEffect::setParam(const std::string &name, double value)
{
    int index = 0;
    std::string_view field;
    if (!splitParam(name, index, field)) {
        return;
    }
    auto &t = m_target.at(static_cast<std::size_t>(index));
    if (field == "On") {
        t.on = value >= 0.5;
    } else if (field == "Type") {
        t.type = std::clamp(static_cast<int>(std::lround(value)), 0, bandTypeCount - 1);
    } else if (field == "Freq") {
        t.freq = static_cast<float>(std::clamp(value, minFreq, maxFreq));
    } else if (field == "Gain") {
        t.gainDb = static_cast<float>(std::clamp(value, minGain, maxGain));
    } else if (field == "Q") {
        t.q = static_cast<float>(std::clamp(value, minQ, maxQ));
    }
}

void EqEffect::updateBand(int index) noexcept
{
    const auto &t = m_target.at(static_cast<std::size_t>(index));
    auto &s = m_state.at(static_cast<std::size_t>(index));
    // Glide frequency (on a log scale), gain and Q towards their targets.
    const double freq = t.freq.load(std::memory_order_relaxed);
    const double gain = t.gainDb.load(std::memory_order_relaxed);
    const double q = t.q.load(std::memory_order_relaxed);
    bool moved = false;
    if (!near(s.now.freq, freq, s.now.freq * 1e-4)) {
        s.now.freq = std::exp(std::log(s.now.freq) + ((std::log(freq) - std::log(s.now.freq)) * m_blockGlide));
        moved = true;
    } else {
        s.now.freq = freq;
    }
    if (!near(s.now.gainDb, gain, 1e-3)) {
        s.now.gainDb += (gain - s.now.gainDb) * m_blockGlide;
        moved = true;
    } else {
        s.now.gainDb = gain;
    }
    if (!near(s.now.q, q, 1e-4)) {
        s.now.q = std::exp(std::log(s.now.q) + ((std::log(q) - std::log(s.now.q)) * m_blockGlide));
        moved = true;
    } else {
        s.now.q = q;
    }
    // A type change waits until the band has faded out (see process()).
    const auto type = static_cast<BandType>(t.type.load(std::memory_order_relaxed));
    if (type != s.now.type && s.mix == 0.0F) {
        s.now.type = type;
        s.z = {};
        moved = true;
    }
    if (moved || s.fresh) {
        s.c = coefficients(s.now, m_rate);
        s.fresh = false;
    }
}

void EqEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);
    for (int start = 0; start < frames; start += blockFrames) {
        const int n = std::min(blockFrames, frames - start);
        // Glides keep their 20 ms however short the block (or the quantum) is.
        m_blockGlide = n == blockFrames
                           ? m_glide
                           : 1.0 - std::exp(-static_cast<double>(n) / (0.020 * m_rate));
        for (int b = 0; b < bandCount; ++b) {
            updateBand(b);
            const auto &t = m_target.at(static_cast<std::size_t>(b));
            auto &s = m_state.at(static_cast<std::size_t>(b));
            const auto type = static_cast<BandType>(t.type.load(std::memory_order_relaxed));
            // In while on and of the wanted type; out to switch type.
            const float target =
                t.on.load(std::memory_order_relaxed) && type == s.now.type ? 1.0F : 0.0F;
            if (s.mix == 0.0F && target == 0.0F) {
                continue; // out: not processed
            }
            const auto &c = s.c;
            float mix = s.mix;
            for (int i = start; i < start + n; ++i) {
                mix = target > mix ? std::min(target, mix + m_fadeStep)
                                   : std::max(target, mix - m_fadeStep);
                for (std::size_t ch = 0; ch < count; ++ch) {
                    auto &z = s.z.at(ch);
                    // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
                    float &sample = planes[ch][i];
                    const double x = sample;
                    const double y = (c.b0 * x) + z[0];
                    z[0] = (c.b1 * x) - (c.a1 * y) + z[1];
                    z[1] = (c.b2 * x) - (c.a2 * y);
                    sample = static_cast<float>(x + ((y - x) * mix));
                }
            }
            s.mix = mix;
            if (mix == 0.0F) {
                s.z = {}; // faded out: start clean when it comes back
            }
            // No denormals in the filter state once the input goes quiet.
            for (std::size_t ch = 0; ch < count; ++ch) {
                for (double &v : s.z.at(ch)) {
                    if (std::abs(v) < 1e-18) {
                        v = 0.0;
                    }
                }
            }
        }
    }
}

} // namespace pp
