// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/multiband.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "multiband.h"

#include <algorithm>
#include <cmath>
#include <numbers>

namespace pp {

namespace {

constexpr double butterworthQ = std::numbers::sqrt2 / 2.0;
// Crossovers keep at least this ratio apart (about a third of an octave).
constexpr double minSpacing = 1.25;

EqEffect::Coefficients allpass(double freq, double sampleRate)
{
    const double w0 = 2.0 * std::numbers::pi * freq / sampleRate;
    const double cosw = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * butterworthQ);
    const double a0 = 1.0 + alpha;
    return {.b0 = (1.0 - alpha) / a0,
            .b1 = (-2.0 * cosw) / a0,
            .b2 = 1.0,
            .a1 = (-2.0 * cosw) / a0,
            .a2 = (1.0 - alpha) / a0};
}

// One biquad step for one channel (transposed direct form II).
inline double step(const EqEffect::Coefficients &c, std::array<double, 2> &z, double x) noexcept
{
    const double y = (c.b0 * x) + z[0];
    z[0] = (c.b1 * x) - (c.a1 * y) + z[1];
    z[1] = (c.b2 * x) - (c.a2 * y);
    return y;
}

// A Linkwitz-Riley 24 dB/octave filter: the same Butterworth biquad twice.
inline double lr4(const EqEffect::Coefficients &c, std::array<double, 2> &first,
                  std::array<double, 2> &second, double x) noexcept
{
    return step(c, second, step(c, first, x));
}

// "b3Ratio" -> band 2 (0-based) and "Ratio".
bool splitParam(const std::string &name, int &band, std::string_view &field)
{
    if (name.size() < 3 || name[0] != 'b' || name[1] < '1' ||
        name[1] > static_cast<char>('0' + MultibandEffect::bandCount)) {
        return false;
    }
    band = name[1] - '1';
    field = std::string_view(name).substr(2);
    return true;
}

void flushDenormals(std::span<std::array<std::array<double, 2>, maxEffectChannels>> states,
                    std::size_t channels) noexcept
{
    for (auto &state : states) {
        for (std::size_t c = 0; c < channels; ++c) {
            for (double &v : state.at(c)) {
                if (std::abs(v) < 1e-18) {
                    v = 0.0;
                }
            }
        }
    }
}

} // namespace

double MultibandEffect::staticCurve(double inputDb, double thresholdDb, double ratio)
{
    const double over = inputDb - thresholdDb;
    if (2.0 * over < -kneeDb) {
        return inputDb;
    }
    if (2.0 * std::abs(over) <= kneeDb) {
        const double into = over + (kneeDb / 2.0);
        return inputDb + ((1.0 / ratio - 1.0) * into * into / (2.0 * kneeDb));
    }
    return thresholdDb + (over / ratio);
}

MultibandEffect::MultibandEffect()
{
    for (std::size_t i = 0; i < m_crossTarget.size(); ++i) {
        m_crossTarget.at(i) = static_cast<float>(defaultCrossovers.at(i));
    }
}

void MultibandEffect::prepare(double sampleRate, int /*channels*/)
{
    m_rate = sampleRate;
    m_glide = 1.0 - std::exp(-static_cast<double>(blockFrames) / (0.020 * sampleRate));
    m_levelStep = 1.0 - std::exp(-1.0 / (0.005 * sampleRate));
    m_rmsStep = 1.0 - std::exp(-1.0 / (0.010 * sampleRate));
    m_offRelease = std::exp(-1.0 / (0.005 * sampleRate));
    for (std::size_t i = 0; i < m_crossNow.size(); ++i) {
        m_crossNow.at(i) = m_crossTarget.at(i).load();
    }
    m_fresh = true;
    for (int b = 0; b < bandCount; ++b) {
        const auto &t = m_target.at(static_cast<std::size_t>(b));
        auto &s = m_state.at(static_cast<std::size_t>(b));
        s.meanSquare = 0.0;
        s.reductionDb = 0.0;
        s.level = t.on.load() ? std::pow(10.0, t.makeupDb.load() / 20.0) : 1.0;
    }
}

void MultibandEffect::setParam(const std::string &name, double value)
{
    if (name == "x1" || name == "x2" || name == "x3") {
        m_crossTarget.at(static_cast<std::size_t>(name[1] - '1')) =
            static_cast<float>(std::clamp(value, minCrossover, maxCrossover));
        return;
    }
    int index = 0;
    std::string_view field;
    if (!splitParam(name, index, field)) {
        return;
    }
    auto &t = m_target.at(static_cast<std::size_t>(index));
    if (field == "Threshold") {
        t.threshold = static_cast<float>(std::clamp(value, -60.0, 0.0));
    } else if (field == "Ratio") {
        t.ratio = static_cast<float>(std::clamp(value, 1.0, 20.0));
    } else if (field == "Attack") {
        t.attackMs = static_cast<float>(std::clamp(value, 0.1, 200.0));
    } else if (field == "Release") {
        t.releaseMs = static_cast<float>(std::clamp(value, 10.0, 3000.0));
    } else if (field == "Makeup") {
        t.makeupDb = static_cast<float>(std::clamp(value, -12.0, 24.0));
    } else if (field == "On") {
        t.on = value >= 0.5;
    } else if (field == "Solo") {
        t.solo = value >= 0.5;
    }
}

std::size_t MultibandEffect::takeMeters(std::span<float> out)
{
    constexpr auto bands = static_cast<std::size_t>(bandCount);
    if (out.size() < 2 * bands) {
        return 0;
    }
    for (std::size_t b = 0; b < bands; ++b) {
        out[b] = m_target.at(b).meter.exchange(0.0F);
        out[bands + b] = m_target.at(b).levelMeter.exchange(0.0F);
    }
    return 2 * bands;
}

void MultibandEffect::resume() noexcept
{
    for (auto *pair : {&m_midLow, &m_midHigh, &m_band1, &m_band2, &m_band3, &m_band4}) {
        for (auto &state : *pair) {
            state = {};
        }
    }
    m_allpassLow = {};
    m_allpassHigh = {};
    for (auto &s : m_state) {
        s.meanSquare = 0.0;
        s.reductionDb = 0.0;
    }
}

void MultibandEffect::updateCrossovers(double glide) noexcept
{
    bool moved = m_fresh;
    for (std::size_t i = 0; i < m_crossNow.size(); ++i) {
        const double target = m_crossTarget.at(i).load(std::memory_order_relaxed);
        double &now = m_crossNow.at(i);
        if (std::abs(now - target) > now * 1e-4) {
            now = std::exp(std::log(now) + ((std::log(target) - std::log(now)) * glide));
            moved = true;
        } else if (now != target) {
            now = target;
            moved = true;
        }
    }
    if (!moved) {
        return;
    }
    m_fresh = false;
    // Kept in order and apart, and clear of Nyquist.
    const double top = 0.45 * m_rate;
    std::array<double, 3> f{};
    f[0] = std::min(m_crossNow[0], top / (minSpacing * minSpacing));
    f[1] = std::min(std::max(m_crossNow[1], f[0] * minSpacing), top / minSpacing);
    f[2] = std::min(std::max(m_crossNow[2], f[1] * minSpacing), top);
    for (std::size_t i = 0; i < f.size(); ++i) {
        auto band = EqEffect::Band{.on = true,
                                   .type = EqEffect::BandType::HighCut,
                                   .freq = f.at(i),
                                   .gainDb = 0.0,
                                   .q = butterworthQ};
        m_cross.at(i).low = EqEffect::coefficients(band, m_rate);
        band.type = EqEffect::BandType::LowCut;
        m_cross.at(i).high = EqEffect::coefficients(band, m_rate);
        m_cross.at(i).allpass = allpass(f.at(i), m_rate);
    }
}

void MultibandEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const auto count = static_cast<std::size_t>(std::clamp(channelCount, 0, maxEffectChannels));
    const std::span<float *const> planes(channels, count);

    // Per-band settings for this call.
    struct Band
    {
        double threshold;
        double ratio;
        double attack;  // one-pole coefficients
        double release;
        bool on;
        double level; // target: makeup x solo
    };
    std::array<Band, bandCount> bands{};
    // Each solo read once, so a change mid-call can't leave every band unheard.
    std::array<bool, bandCount> solo{};
    for (std::size_t b = 0; b < solo.size(); ++b) {
        solo.at(b) = m_target.at(b).solo.load(std::memory_order_relaxed);
    }
    const bool anySolo = std::ranges::any_of(solo, [](bool s) { return s; });
    for (std::size_t b = 0; b < bands.size(); ++b) {
        const auto &t = m_target.at(b);
        const bool on = t.on.load(std::memory_order_relaxed);
        const bool heard = !anySolo || solo.at(b);
        double level = 0.0; // a band not heard (another is soloed)
        if (heard) {
            level = on ? std::pow(10.0, t.makeupDb.load(std::memory_order_relaxed) / 20.0) : 1.0;
        }
        bands.at(b) = Band{
            .threshold = t.threshold.load(std::memory_order_relaxed),
            .ratio = t.ratio.load(std::memory_order_relaxed),
            .attack = std::exp(-1.0 / (t.attackMs.load(std::memory_order_relaxed) * 0.001 * m_rate)),
            .release =
                std::exp(-1.0 / (t.releaseMs.load(std::memory_order_relaxed) * 0.001 * m_rate)),
            .on = on,
            .level = level,
        };
    }

    std::array<float, bandCount> peakReduction{};
    std::array<double, bandCount> peakSquare{}; // the detectors' loudest
    std::array<std::array<double, maxEffectChannels>, bandCount> split{};
    for (int start = 0; start < frames; start += blockFrames) {
        const int end = std::min(frames, start + blockFrames);
        // Glides keep their 20 ms however short the block (or the quantum) is.
        updateCrossovers(end - start == blockFrames
                             ? m_glide
                             : 1.0 - std::exp(-static_cast<double>(end - start) / (0.020 * m_rate)));
        for (int i = start; i < end; ++i) {
            // Split every channel into the four bands.
            std::array<double, bandCount> loudest{};
            for (std::size_t c = 0; c < count; ++c) {
                // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
                const double x = planes[c][i];
                // The low branch gets the allpass of x3, the high branch that
                // of x1, so all four bands come out with the same phase.
                const double low = step(m_cross[2].allpass, m_allpassLow.at(c),
                                        lr4(m_cross[1].low, m_midLow[0].at(c), m_midLow[1].at(c), x));
                const double high =
                    step(m_cross[0].allpass, m_allpassHigh.at(c),
                         lr4(m_cross[1].high, m_midHigh[0].at(c), m_midHigh[1].at(c), x));
                const std::array<double, bandCount> v{
                    lr4(m_cross[0].low, m_band1[0].at(c), m_band1[1].at(c), low),
                    lr4(m_cross[0].high, m_band2[0].at(c), m_band2[1].at(c), low),
                    lr4(m_cross[2].low, m_band3[0].at(c), m_band3[1].at(c), high),
                    lr4(m_cross[2].high, m_band4[0].at(c), m_band4[1].at(c), high),
                };
                for (std::size_t b = 0; b < bandCount; ++b) {
                    split.at(b).at(c) = v.at(b);
                    loudest.at(b) = std::max(loudest.at(b), std::abs(v.at(b)));
                }
            }
            // Each band's gain, from its loudest channel, applied to all.
            for (std::size_t b = 0; b < bandCount; ++b) {
                const auto &band = bands.at(b);
                auto &s = m_state.at(b);
                const double peak = loudest.at(b);
                s.meanSquare += ((peak * peak) - s.meanSquare) * m_rmsStep;
                double wanted = 0.0;
                if (band.on) {
                    const double level = 10.0 * std::log10(std::max(s.meanSquare, 1e-18));
                    wanted = level - staticCurve(level, band.threshold, band.ratio);
                }
                double k = wanted > s.reductionDb ? band.attack : band.release;
                if (!band.on) {
                    k = m_offRelease; // off means uncompressed, now
                }
                s.reductionDb = wanted + ((s.reductionDb - wanted) * k);
                s.level += (band.level - s.level) * m_levelStep;
                peakReduction.at(b) = std::max(peakReduction.at(b), static_cast<float>(s.reductionDb));
                peakSquare.at(b) = std::max(peakSquare.at(b), s.meanSquare);
            }
            std::array<double, bandCount> gains{};
            for (std::size_t b = 0; b < bandCount; ++b) {
                gains.at(b) = m_state.at(b).level * std::pow(10.0, -m_state.at(b).reductionDb / 20.0);
            }
            for (std::size_t c = 0; c < count; ++c) {
                double sum = 0.0;
                for (std::size_t b = 0; b < bandCount; ++b) {
                    sum += split.at(b).at(c) * gains.at(b);
                }
                // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
                planes[c][i] = static_cast<float>(sum);
            }
        }
    }
    for (auto *pair : {&m_midLow, &m_midHigh, &m_band1, &m_band2, &m_band3, &m_band4}) {
        flushDenormals(*pair, count);
    }
    flushDenormals(std::span(&m_allpassLow, 1), count);
    flushDenormals(std::span(&m_allpassHigh, 1), count);
    // Envelopes out of denormals in silence (and a soloed-away band's level).
    for (auto &s : m_state) {
        if (s.meanSquare < 1e-30) {
            s.meanSquare = 0.0;
        }
        if (std::abs(s.reductionDb) < 1e-9) {
            s.reductionDb = 0.0;
        }
        if (s.level < 1e-9) {
            s.level = 0.0;
        }
    }
    for (std::size_t b = 0; b < bandCount; ++b) {
        // A compare-exchange, so a takeMeters() in between can't lose it.
        auto &meter = m_target.at(b).meter;
        float current = meter.load(std::memory_order_relaxed);
        while (peakReduction.at(b) > current &&
               !meter.compare_exchange_weak(current, peakReduction.at(b),
                                            std::memory_order_relaxed)) {
        }
        const auto above = static_cast<float>(std::max(
            0.0, (10.0 * std::log10(std::max(peakSquare.at(b), 1e-18))) - meterFloorDb));
        auto &level = m_target.at(b).levelMeter;
        current = level.load(std::memory_order_relaxed);
        while (above > current &&
               !level.compare_exchange_weak(current, above, std::memory_order_relaxed)) {
        }
    }
}

} // namespace pp
