// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/effects.cpp, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "effects.h"

#include "delay.h"
#include "dynamics.h"
#ifdef PATCHPRIME_HAVE_RNNOISE
#include "denoise.h"
#endif
#include "eq.h"
#include "loudness.h"
#include "multiband.h"
#include "reverb.h"
#include "voice.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <span>

namespace pp {

namespace {

float dbToGain(double db)
{
    return static_cast<float>(std::pow(10.0, db / 20.0));
}

// Raises a meter to value; a compare-exchange, so a take on the main thread
// in between can't lose it.
void raise(std::atomic<float> &meter, float value)
{
    float current = meter.load(std::memory_order_relaxed);
    while (value > current &&
           !meter.compare_exchange_weak(current, value, std::memory_order_relaxed)) {
    }
}

} // namespace

// --- GainEffect --------------------------------------------------------------

void GainEffect::prepare(double sampleRate, int /*channels*/)
{
    // About 20 ms to settle on a new level.
    m_smoothing = static_cast<float>(1.0 - std::exp(-1.0 / (0.005 * sampleRate)));
    m_current = m_target.load();
}

void GainEffect::process(float *const *channels, int channelCount, int frames) noexcept
{
    const float target = m_target.load(std::memory_order_relaxed);
    const std::span<float *const> planes(channels, static_cast<std::size_t>(channelCount));
    float current = m_current;
    for (int i = 0; i < frames; ++i) {
        current += (target - current) * m_smoothing;
        for (float *plane : planes) {
            plane[i] *= current; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
        }
    }
    m_current = current;
}

void GainEffect::setParam(const std::string &name, double value)
{
    if (name == "gainDb") {
        m_target.store(dbToGain(std::clamp(value, minDb, maxDb)));
    }
}

std::unique_ptr<Effect> makeEffect(const std::string &type)
{
    if (type == "gain") {
        return std::make_unique<GainEffect>();
    }
    if (type == "eq") {
        return std::make_unique<EqEffect>();
    }
    if (type == "multiband") {
        return std::make_unique<MultibandEffect>();
    }
    if (type == "compressor") {
        return std::make_unique<CompressorEffect>();
    }
    if (type == "deesser") {
        return std::make_unique<DeEsserEffect>();
    }
    if (type == "gate") {
        return std::make_unique<GateEffect>();
    }
    if (type == "expander") {
        return std::make_unique<ExpanderEffect>();
    }
    if (type == "leveler") {
        return std::make_unique<LevelerEffect>();
    }
    if (type == "reverb") {
        return std::make_unique<ReverbEffect>();
    }
    if (type == "delay") {
        return std::make_unique<DelayEffect>();
    }
    if (type == "limiter") {
        return std::make_unique<LimiterEffect>();
    }
#ifdef PATCHPRIME_HAVE_RNNOISE
    if (type == "denoise") {
        return std::make_unique<DenoiseEffect>();
    }
#endif
    if (type == "ducker") {
        return std::make_unique<DuckerEffect>();
    }
    return nullptr;
}

std::string paramKindName(ParamKind kind)
{
    switch (kind) {
    case ParamKind::Linear:
        return "linear";
    case ParamKind::Log:
        return "log";
    case ParamKind::Choice:
        return "choice";
    case ParamKind::Toggle:
        return "toggle";
    }
    return "linear";
}

double validParam(const ParamInfo &info, double value)
{
    if (!std::isfinite(value)) {
        value = info.initial;
    }
    value = std::clamp(value, info.minimum, info.maximum);
    if (info.kind == ParamKind::Choice || info.kind == ParamKind::Toggle) {
        value = std::round(value);
    }
    return value;
}

std::vector<std::string> effectTypes()
{
    std::vector<std::string> types{"eq", "compressor", "deesser", "multiband", "gate", "expander", "ducker"};
#ifdef PATCHPRIME_HAVE_RNNOISE
    types.emplace_back("denoise");
#endif
    types.emplace_back("leveler");
    types.emplace_back("limiter");
    types.emplace_back("reverb");
    types.emplace_back("delay");
    types.emplace_back("gain");
    return types;
}

std::string effectLabel(const std::string &type)
{
    if (type == "gain") {
        return "Gain";
    }
    if (type == "eq") {
        return "Parametric EQ";
    }
    if (type == "multiband") {
        return "Multiband compressor";
    }
    if (type == "compressor") {
        return "Compressor";
    }
    if (type == "deesser") {
        return "De-esser";
    }
    if (type == "gate") {
        return "Noise gate";
    }
    if (type == "expander") {
        return "Expander";
    }
    if (type == "ducker") {
        return "Ducker";
    }
    if (type == "denoise") {
        return "Noise suppression";
    }
    if (type == "leveler") {
        return "Broadcast leveler";
    }
    if (type == "reverb") {
        return "Reverb";
    }
    if (type == "delay") {
        return "Delay (line up outputs)";
    }
    if (type == "limiter") {
        return "Safety limiter";
    }
    return type;
}

std::vector<ParamInfo> effectParams(const std::string &type)
{
    const auto param = [](std::string name, std::string label, std::string unit, double minimum,
                          double maximum, double initial, ParamKind kind = ParamKind::Linear,
                          std::vector<std::string> options = {}) {
        return ParamInfo{.name = std::move(name),
                         .label = std::move(label),
                         .unit = std::move(unit),
                         .minimum = minimum,
                         .maximum = maximum,
                         .initial = initial,
                         .kind = kind,
                         .options = std::move(options)};
    };
    if (type == "gain") {
        return {param("gainDb", "Gain", "dB", GainEffect::minDb, GainEffect::maxDb, 0.0)};
    }
    if (type == "eq") {
        std::vector<std::string> types;
        types.reserve(EqEffect::bandTypeCount);
        for (int t = 0; t < EqEffect::bandTypeCount; ++t) {
            types.push_back(EqEffect::typeName(static_cast<EqEffect::BandType>(t)));
        }
        std::vector<ParamInfo> params;
        for (int b = 0; b < EqEffect::bandCount; ++b) {
            const auto band = EqEffect::defaultBand(b);
            const auto prefix = "b" + std::to_string(b + 1);
            const auto label = "Band " + std::to_string(b + 1) + " ";
            params.push_back(param(prefix + "On", label + "on", "", 0.0, 1.0, band.on ? 1.0 : 0.0,
                                   ParamKind::Toggle));
            params.push_back(param(prefix + "Type", label + "type", "", 0.0,
                                   EqEffect::bandTypeCount - 1.0, static_cast<double>(band.type),
                                   ParamKind::Choice, types));
            params.push_back(param(prefix + "Freq", label + "frequency", "Hz", EqEffect::minFreq,
                                   EqEffect::maxFreq, band.freq, ParamKind::Log));
            params.push_back(param(prefix + "Gain", label + "gain", "dB", EqEffect::minGain,
                                   EqEffect::maxGain, band.gainDb));
            params.push_back(param(prefix + "Q", label + "Q", "", EqEffect::minQ, EqEffect::maxQ,
                                   band.q, ParamKind::Log));
        }
        return params;
    }
    if (type == "gate") {
        return {param("threshold", "Threshold", "dB", -80.0, 0.0, -50.0),
                param("range", "Range", "dB", 0.0, 80.0, 40.0),
                param("attack", "Attack", "ms", 0.1, 50.0, 1.0, ParamKind::Log),
                param("hold", "Hold", "ms", 0.0, 1000.0, 100.0),
                param("release", "Release", "ms", 5.0, 2000.0, 150.0, ParamKind::Log)};
    }
    if (type == "compressor") {
        const auto knob = CompressorEffect::fromAmount(40.0);
        return {param("amount", "Amount", "%", 0.0, 100.0, 40.0),
                param("advanced", "Advanced", "", 0.0, 1.0, 0.0, ParamKind::Toggle),
                param("threshold", "Threshold", "dB", -60.0, 0.0, knob.threshold),
                param("ratio", "Ratio", ":1", 1.0, 20.0, knob.ratio, ParamKind::Log),
                param("attack", "Attack", "ms", 0.1, 200.0, knob.attack, ParamKind::Log),
                param("release", "Release", "ms", 10.0, 3000.0, knob.release, ParamKind::Log),
                param("makeup", "Makeup", "dB", -12.0, 24.0, knob.makeup)};
    }
    if (type == "deesser") {
        return {param("frequency", "Frequency", "Hz", 2000.0, 12000.0, 6000.0, ParamKind::Log),
                param("threshold", "Threshold", "dB", -60.0, 0.0, -30.0),
                param("range", "Range", "dB", 0.0, 24.0, 10.0),
                param("listen", "Listen", "", 0.0, 1.0, 0.0, ParamKind::Toggle)};
    }
    if (type == "expander") {
        return {param("threshold", "Threshold", "dB", -80.0, 0.0, -45.0),
                param("ratio", "Ratio", "1:", 1.0, 8.0, 2.0, ParamKind::Log),
                param("range", "Range", "dB", 0.0, 60.0, 20.0),
                param("attack", "Attack", "ms", 0.1, 50.0, 2.0, ParamKind::Log),
                param("release", "Release", "ms", 10.0, 2000.0, 150.0, ParamKind::Log)};
    }
    if (type == "leveler") {
        return {param("target", "Target", "LUFS", -36.0, -6.0, -18.0),
                param("maxBoost", "Max boost", "dB", 0.0, 35.0, 12.0),
                param("maxCut", "Max cut", "dB", 0.0, 24.0, 12.0),
                param("speed", "Speed", "s", 0.5, 30.0, 5.0, ParamKind::Log),
                param("freeze", "Freeze below", "LUFS", -70.0, -20.0, -50.0)};
    }
    if (type == "delay") {
        return {param("time", "Time", "ms", 0.0, DelayEffect::maxMs, 0.0)};
    }
    if (type == "reverb") {
        return {param("size", "Size", "%", 0.0, 100.0, 50.0),
                param("decay", "Decay", "s", 0.2, 10.0, 2.0, ParamKind::Log),
                param("predelay", "Pre-delay", "ms", 0.0, ReverbEffect::maxPredelayMs, 20.0),
                param("damping", "Damping", "%", 0.0, 100.0, 50.0),
                param("width", "Width", "%", 0.0, 100.0, 100.0),
                param("mix", "Mix (wet)", "%", 0.0, 100.0, 25.0)};
    }
    if (type == "limiter") {
        return {param("ceiling", "Ceiling", "dB", -24.0, 0.0, -1.0),
                param("release", "Release", "ms", 5.0, 2000.0, 100.0, ParamKind::Log),
                param("truePeak", "True peak", "", 0.0, 1.0, 0.0, ParamKind::Toggle)};
    }
    if (type == "ducker") {
        return {param("threshold", "Threshold", "dB", -60.0, 0.0, -35.0),
                param("depth", "Depth", "dB", 0.0, 40.0, 12.0),
                param("attack", "Attack", "ms", 1.0, 500.0, 20.0, ParamKind::Log),
                param("hold", "Hold", "ms", 0.0, 2000.0, 250.0),
                param("release", "Release", "ms", 50.0, 5000.0, 600.0, ParamKind::Log)};
    }
#ifdef PATCHPRIME_HAVE_RNNOISE
    if (type == "denoise") {
        return {param("amount", "Amount", "%", 0.0, 100.0, 100.0)};
    }
#endif
    if (type == "multiband") {
        std::vector<ParamInfo> params;
        params.reserve(3 + (7 * MultibandEffect::bandCount));
        for (std::size_t x = 0; x < MultibandEffect::defaultCrossovers.size(); ++x) {
            params.push_back(param("x" + std::to_string(x + 1),
                                   "Crossover " + std::to_string(x + 1), "Hz",
                                   MultibandEffect::minCrossover, MultibandEffect::maxCrossover,
                                   MultibandEffect::defaultCrossovers.at(x), ParamKind::Log));
        }
        for (int b = 1; b <= MultibandEffect::bandCount; ++b) {
            const auto prefix = "b" + std::to_string(b);
            const auto label = "Band " + std::to_string(b) + " ";
            params.push_back(param(prefix + "On", label + "on", "", 0.0, 1.0, 1.0, ParamKind::Toggle));
            params.push_back(
                param(prefix + "Solo", label + "solo", "", 0.0, 1.0, 0.0, ParamKind::Toggle));
            params.push_back(param(prefix + "Threshold", label + "threshold", "dB", -60.0, 0.0, -20.0));
            params.push_back(
                param(prefix + "Ratio", label + "ratio", ":1", 1.0, 20.0, 2.0, ParamKind::Log));
            params.push_back(
                param(prefix + "Attack", label + "attack", "ms", 0.1, 200.0, 10.0, ParamKind::Log));
            params.push_back(param(prefix + "Release", label + "release", "ms", 10.0, 3000.0, 150.0,
                                   ParamKind::Log));
            params.push_back(param(prefix + "Makeup", label + "makeup", "dB", -12.0, 24.0, 0.0));
        }
        return params;
    }
    return {};
}

bool effectTakesKey(const std::string &type)
{
    return type == "ducker";
}

// --- EffectChain --------------------------------------------------------------

EffectChain::EffectChain(std::vector<std::unique_ptr<Effect>> effects, double sampleRate,
                         int channels)
    : m_effects(std::move(effects)), m_points(m_effects.size() + 1),
      m_channels(std::clamp(channels, 1, maxEffectChannels)),
      m_groups(m_channels == 1 ? 1 : EffectLevels::maxGroups), m_rate(sampleRate)
{
    m_slots.resize(m_effects.size());
    for (std::size_t i = 0; i < m_effects.size(); ++i) {
        m_effects[i]->prepare(sampleRate, m_channels);
        m_slots[i].mix = m_effects[i]->enabled.load() ? 1.0F : 0.0F;
    }
    m_dry.assign(static_cast<std::size_t>(m_channels),
                 std::vector<float>(static_cast<std::size_t>(maxEffectFrames)));
    m_step = static_cast<float>(1.0 / std::max(1.0, crossfadeSeconds * sampleRate));
}

void EffectChain::process(float *const *channels, int frames, const float *key,
                          bool measure) noexcept
{
    frames = std::min(frames, maxEffectFrames);
    const auto count = static_cast<std::size_t>(m_channels);
    const std::span<float *const> planes(channels, count);
    const std::span<const float *const> levels(channels, count);
    const double rmsStep =
        measure ? 1.0 - std::exp(-static_cast<double>(frames) / (rmsSeconds * std::max(m_rate, 1.0)))
                : 0.0;
    if (measure) {
        measureAt(m_points.front(), levels, frames, rmsStep, m_groups);
        if (key != nullptr) {
            const std::array<const float *, 1> keyPlane{key};
            measureAt(m_keyPoint, keyPlane, frames, rmsStep, 1);
        }
        m_keyed.store(key != nullptr, std::memory_order_relaxed);
    }
    for (std::size_t e = 0; e < m_effects.size(); ++e) {
        Effect &effect = *m_effects[e];
        effect.setKey(key);
        if (effect.ringsOut()) {
            effect.process(channels, m_channels, frames);
            if (measure) {
                measureAt(m_points[e + 1], levels, frames, rmsStep, m_groups);
            }
            continue;
        }
        float &mix = m_slots[e].mix;
        const float target = effect.enabled.load(std::memory_order_relaxed) ? 1.0F : 0.0F;
        if (mix == 0.0F && target == 0.0F) {
            // Bypassed: not processed at all, and its output is its input.
            effect.bypassed(frames);
            if (measure) {
                measureAt(m_points[e + 1], levels, frames, rmsStep, m_groups);
            }
            continue;
        }
        if (mix == 0.0F) {
            effect.resume(); // coming back from bypass
        }
        if (mix == 1.0F && target == 1.0F) {
            effect.process(channels, m_channels, frames);
            if (measure) {
                measureAt(m_points[e + 1], levels, frames, rmsStep, m_groups);
            }
            continue;
        }
        // Switching: process, then crossfade from the dry signal.
        for (std::size_t c = 0; c < count; ++c) {
            std::memcpy(m_dry[c].data(), planes[c],
                        static_cast<std::size_t>(frames) * sizeof(float));
        }
        effect.process(channels, m_channels, frames);
        float m = mix;
        for (int i = 0; i < frames; ++i) {
            m = target > m ? std::min(target, m + m_step) : std::max(target, m - m_step);
            for (std::size_t c = 0; c < count; ++c) {
                // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
                float &wet = planes[c][i];
                const float dry = m_dry[c][static_cast<std::size_t>(i)];
                wet = dry + ((wet - dry) * m);
            }
        }
        mix = m;
        if (measure) {
            measureAt(m_points[e + 1], levels, frames, rmsStep, m_groups);
        }
    }
}

int EffectChain::latency() const
{
    int total = 0;
    for (const auto &effect : m_effects) {
        if (effect->enabled.load(std::memory_order_relaxed)) {
            total += effect->latency();
        }
    }
    return total;
}

void EffectChain::measureAt(Point &point, std::span<const float *const> planes, int frames,
                            double rmsStep, std::size_t groups) noexcept
{
    if (frames <= 0) {
        return;
    }
    const std::size_t half = groups == 1 ? planes.size() : planes.size() / 2;
    for (std::size_t g = 0; g < groups; ++g) {
        const auto group = g == 0 ? planes.first(half) : planes.subspan(half);
        float peak = 0.0F;
        double sum = 0.0;
        for (const float *plane : group) {
            for (const float sample : std::span(plane, static_cast<std::size_t>(frames))) {
                const float level = std::abs(sample);
                peak = std::max(peak, level);
                sum += static_cast<double>(level) * level;
            }
        }
        const double mean = sum / static_cast<double>(frames * std::ssize(group));
        double &meanSquare = point.meanSquare.at(g);
        meanSquare += (mean - meanSquare) * rmsStep;
        if (meanSquare < 1e-20) {
            meanSquare = 0.0; // out of denormals in silence
        }
        raise(point.peak.at(g), peak);
        point.rms.at(g).store(static_cast<float>(std::sqrt(meanSquare)), std::memory_order_relaxed);
    }
}

std::vector<EffectLevels> EffectChain::takeLevels()
{
    std::vector<EffectLevels> out(m_effects.size());
    std::array<float, EffectLevels::maxGroups> peak{};
    std::array<float, EffectLevels::maxGroups> rms{};
    for (std::size_t p = 0; p < m_points.size(); ++p) {
        for (std::size_t g = 0; g < m_groups; ++g) {
            peak.at(g) = m_points[p].peak.at(g).exchange(0.0F, std::memory_order_relaxed);
            rms.at(g) = m_points[p].rms.at(g).load(std::memory_order_relaxed);
        }
        if (p < out.size()) {
            out[p].groups = m_groups;
            out[p].inPeak = peak;
            out[p].inRms = rms;
        }
        if (p > 0) {
            out[p - 1].outPeak = peak;
            out[p - 1].outRms = rms;
        }
    }
    if (m_keyed.load(std::memory_order_relaxed)) {
        const float keyPeak = m_keyPoint.peak[0].exchange(0.0F, std::memory_order_relaxed);
        const float keyRms = m_keyPoint.rms[0].load(std::memory_order_relaxed);
        for (auto &levels : out) {
            levels.hasKey = true;
            levels.keyPeak = keyPeak;
            levels.keyRms = keyRms;
        }
    }
    return out;
}

// --- Processor -----------------------------------------------------------------

Processor::~Processor()
{
    delete m_chain.exchange(nullptr);
}

void Processor::setChain(std::unique_ptr<EffectChain> chain)
{
    // Swap first, then look whether the realtime thread is inside process():
    // it marks that before reading the chain, so if it isn't, it can't be
    // holding the old one.
    EffectChain *old = m_chain.exchange(chain.release());
    if (old == nullptr) {
        return;
    }
    if (!m_inProcess.load()) {
        delete old;
        return;
    }
    m_retired.push_back({.chain = std::unique_ptr<EffectChain>(old), .cycle = m_cycle.load()});
}

void Processor::collect()
{
    const auto cycle = m_cycle.load();
    std::erase_if(m_retired, [cycle](const Retired &r) { return cycle > r.cycle; });
}

void Processor::process(const float *const *in, float *const *out, int channelCount, int frames,
                        const float *key) noexcept
{
    m_inProcess.store(true);
    frames = std::max(frames, 0);
    const auto count = static_cast<std::size_t>(std::max(channelCount, 0));
    const std::span<const float *const> inputs(in, count);
    const std::span<float *const> outputs(out, count);
    for (std::size_t c = 0; c < count; ++c) {
        if (outputs[c] == nullptr) {
            continue;
        }
        if (inputs[c] == nullptr) {
            std::memset(outputs[c], 0, static_cast<std::size_t>(frames) * sizeof(float));
        } else if (inputs[c] != outputs[c]) {
            std::memcpy(outputs[c], inputs[c], static_cast<std::size_t>(frames) * sizeof(float));
        }
        // A broken sample (NaN or infinity) from an app would stick in the
        // effects' filters and envelopes for good: it comes in as silence.
        for (float &sample : std::span(outputs[c], static_cast<std::size_t>(frames))) {
            if (!std::isfinite(sample)) {
                sample = 0.0F;
            }
        }
    }
    EffectChain *chain = m_chain.load();
    const bool complete = std::ranges::all_of(outputs, [](const float *p) { return p != nullptr; });
    if (chain != nullptr && complete && chain->channels() == channelCount) {
        std::array<float *, maxEffectChannels> part{};
        for (int start = 0; start < frames; start += maxEffectFrames) {
            for (std::size_t c = 0; c < count && c < part.size(); ++c) {
                part.at(c) = outputs[c] + start; // NOLINT(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            }
            // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-pointer-arithmetic)
            chain->process(part.data(), std::min(maxEffectFrames, frames - start),
                           key != nullptr ? key + start : nullptr,
                           m_metering.load(std::memory_order_relaxed));
        }
    }
    m_cycle.fetch_add(1);
    m_inProcess.store(false);
}

} // namespace pp
