// Copied from Patch Prime (kingsqueak/patch-prime, engine/src/effects.h, commit 458e957).
// Fixes that matter to both are carried across by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace pp {

// Built-in effects and the chain that runs them, for a strip's processing
// node. Everything here is plain C++ (no PipeWire), so it's unit tested.
//
// Threads: prepare() and parameter setters run on the main thread; process()
// runs on PipeWire's realtime thread and must not allocate, lock or throw.
// Parameters cross over as atomics.

constexpr int maxEffectChannels = 32;
constexpr int maxEffectFrames = 8192; // PipeWire's largest quantum

class Effect
{
public:
    Effect() = default;
    virtual ~Effect() = default;
    Effect(const Effect &) = delete;
    Effect &operator=(const Effect &) = delete;
    Effect(Effect &&) = delete;
    Effect &operator=(Effect &&) = delete;

    // The type name makeEffect() knows it by.
    [[nodiscard]] virtual std::string_view type() const = 0;
    // Main thread, before the effect runs: may allocate.
    virtual void prepare(double sampleRate, int channels) = 0;
    // Realtime: processes planar audio in place.
    virtual void process(float *const *channels, int channelCount, int frames) noexcept = 0;
    // Main thread: sets a parameter by name; unknown names are ignored. Runs
    // while process() may be running on the realtime thread (chains are
    // updated in place), so it must only store into atomics.
    virtual void setParam(const std::string &name, double value) = 0;

    // Realtime: the effect runs again after being fully bypassed (skipped);
    // forget what it held from before (buffered audio, filter memory).
    virtual void resume() noexcept {}
    // Realtime, instead of process() while it's fully bypassed: a block went
    // by without it (a plugin still has its parameter changes to deliver).
    virtual void bypassed(int /*frames*/) noexcept {}
    // True for an effect that takes care of its own bypass, to let what it
    // holds ring out (a reverb's tail): the chain keeps calling process(),
    // which reads `enabled` itself, passes the dry signal when it's off and
    // doesn't crossfade. resume() and bypassed() aren't called for it.
    [[nodiscard]] virtual bool ringsOut() const noexcept { return false; }

    // Main thread: the effect's meters since the last call (gain reduction
    // per band, say) into out; returns how many it wrote. Most have none.
    virtual std::size_t takeMeters(std::span<float> /*out*/) { return 0; }

    // Main thread, once prepared: how many samples late its output comes
    // (noise suppression's frame, a limiter's lookahead, what a plugin
    // reports), whether or not it's on. A delay set on purpose (the Delay
    // effect) isn't latency: 0. A plugin's may change while it runs.
    [[nodiscard]] virtual int latency() const { return 0; }

    // Effects driven by another strip's sound (a ducker) read it here: the
    // key signal for the current process() call, mono, or null when there's
    // none. Set by the chain on the realtime thread just before process().
    void setKey(const float *key) noexcept { m_key = key; }

    // On or bypassed. A change crossfades (see EffectChain).
    std::atomic<bool> enabled{true}; // NOLINT(cppcoreguidelines-non-private-member-variables-in-classes): an atomic flag shared with the realtime thread

protected:
    [[nodiscard]] const float *key() const noexcept { return m_key; }

private:
    const float *m_key = nullptr;
};

// A level trim: "gainDb" from -24 to +24 dB, smoothed so moving it doesn't
// zipper.
class GainEffect : public Effect
{
public:
    static constexpr double minDb = -24.0;
    static constexpr double maxDb = 24.0;

    [[nodiscard]] std::string_view type() const override { return "gain"; }
    void prepare(double sampleRate, int channels) override;
    void process(float *const *channels, int channelCount, int frames) noexcept override;
    void setParam(const std::string &name, double value) override;

private:
    std::atomic<float> m_target{1.0F}; // linear
    float m_current = 1.0F;            // realtime only
    float m_smoothing = 0.0F;          // per-sample coefficient
};

// The built-in effect types by name ("gain"); nullptr for an unknown type.
std::unique_ptr<Effect> makeEffect(const std::string &type);
// Every built-in type, in the order a menu lists them, and its display name.
std::vector<std::string> effectTypes();
std::string effectLabel(const std::string &type);
// Names and parameter ranges, for the UI and validation. Every parameter is
// a number; the kind says how to show and edit it.
enum class ParamKind : std::uint8_t
{
    Linear,
    Log,    // a frequency, say: shown on a log scale
    Choice, // a whole number indexing options
    Toggle, // 0 or 1
};
std::string paramKindName(ParamKind kind); // "linear", "log", "choice", "toggle"
struct ParamInfo
{
    std::string name;
    std::string label;
    std::string unit; // "dB", "Hz", "ms", "" ...
    double minimum = 0.0;
    double maximum = 0.0;
    double initial = 0.0;
    ParamKind kind = ParamKind::Linear;
    std::vector<std::string> options; // Choice: a label per value
};
// A value made valid for a parameter: clamped, and whole for a choice or toggle.
double validParam(const ParamInfo &info, double value);
std::vector<ParamInfo> effectParams(const std::string &type);
// Whether a type listens to another strip (its "key", see EffectSettings).
bool effectTakesKey(const std::string &type);
// Effects one strip may have.
constexpr std::size_t maxEffectsPerStrip = 8;

// The level going into and coming out of one effect in a chain, for its
// meters: linear peak since the last take and RMS (~300 ms), per channel
// group. Mono has one group; otherwise the first and second half of the
// channels are a group each (left and right). A chain with a key input
// (see Effect::setKey) also has the key's level, the same for every effect.
struct EffectLevels
{
    static constexpr std::size_t maxGroups = 2;
    std::size_t groups = 0;
    std::array<float, maxGroups> inPeak{};
    std::array<float, maxGroups> inRms{};
    std::array<float, maxGroups> outPeak{};
    std::array<float, maxGroups> outRms{};
    bool hasKey = false;
    float keyPeak = 0.0F;
    float keyRms = 0.0F;
};

// Effects in order. Each one's bypass crossfades between its dry input and
// its output over crossfadeSeconds, so switching never clicks; a fully
// bypassed effect isn't processed at all (except one that rings out, see
// Effect::ringsOut, which does this itself). The level is measured before the
// first effect and after each one (see takeLevels()).
class EffectChain
{
public:
    static constexpr double crossfadeSeconds = 0.010;
    static constexpr double rmsSeconds = 0.3;

    EffectChain(std::vector<std::unique_ptr<Effect>> effects, double sampleRate, int channels);

    [[nodiscard]] int channels() const { return m_channels; }
    [[nodiscard]] std::size_t size() const { return m_effects.size(); }
    [[nodiscard]] Effect &at(std::size_t index) { return *m_effects.at(index); }
    // Main thread: the latency of the effects that are on, together (samples).
    [[nodiscard]] int latency() const;

    // Realtime. key: the strip's key input (mono, frames long), or null.
    // measure: also measure the levels (only while someone looks at them).
    void process(float *const *channels, int frames, const float *key = nullptr,
                 bool measure = false) noexcept;

    // Main thread: each effect's input and output levels, in chain order.
    // Peaks are since the last call (an effect's output is the next one's
    // input, so they're all taken together).
    [[nodiscard]] std::vector<EffectLevels> takeLevels();

private:
    struct Slot
    {
        float mix = 1.0F; // 0 = bypassed, 1 = on; realtime only
    };
    // Where the level is measured: before the first effect, after each one.
    struct Point
    {
        std::array<std::atomic<float>, EffectLevels::maxGroups> peak{};
        std::array<std::atomic<float>, EffectLevels::maxGroups> rms{};
        std::array<double, EffectLevels::maxGroups> meanSquare{}; // realtime only
    };

    static void measureAt(Point &point, std::span<const float *const> planes, int frames,
                          double rmsStep, std::size_t groups) noexcept;

    std::vector<std::unique_ptr<Effect>> m_effects;
    std::vector<Slot> m_slots;
    std::vector<Point> m_points; // one more than effects
    Point m_keyPoint;                 // the key input's level (group 0)
    std::atomic<bool> m_keyed{false}; // a key came with the last process()
    std::vector<std::vector<float>> m_dry; // per channel, maxEffectFrames
    int m_channels = 0;
    std::size_t m_groups = 1;
    double m_rate = 48000.0;
    float m_step = 1.0F; // crossfade change per sample
};

// What a strip's processing node runs each cycle: copies its input to its
// output and runs the current chain on it. The chain is swapped with
// setChain() from the main thread without locking the realtime thread; the
// old one is handed back by collect() once the realtime thread is past it.
class Processor
{
public:
    Processor() = default;
    ~Processor();
    Processor(const Processor &) = delete;
    Processor &operator=(const Processor &) = delete;
    Processor(Processor &&) = delete;
    Processor &operator=(Processor &&) = delete;

    // Main thread. nullptr: pass audio through unchanged.
    void setChain(std::unique_ptr<EffectChain> chain);
    // The current chain, for parameter changes (main thread; may be null).
    [[nodiscard]] EffectChain *chain() const { return m_chain.load(); }
    // Main thread: deletes chains the realtime thread can no longer be using.
    void collect();
    // Whether the chain measures its levels (see EffectChain::takeLevels);
    // off by default, since nothing needs them unless an effects window is open.
    void setMetering(bool on) { m_metering.store(on, std::memory_order_relaxed); }
    [[nodiscard]] bool isMetering() const { return m_metering.load(std::memory_order_relaxed); }

    // Realtime: in and out are planar, channel by channel; in may equal out.
    // Non-finite input samples are replaced with silence before the chain.
    // Any length: blocks longer than maxEffectFrames are processed in parts.
    // key: the key input (mono), or null.
    void process(const float *const *in, float *const *out, int channelCount, int frames,
                 const float *key = nullptr) noexcept;

private:
    std::atomic<EffectChain *> m_chain{nullptr};
    std::atomic<std::uint64_t> m_cycle{0}; // bumped at the end of every process()
    std::atomic<bool> m_inProcess{false};
    std::atomic<bool> m_metering{false};
    struct Retired
    {
        std::unique_ptr<EffectChain> chain;
        std::uint64_t cycle = 0; // m_cycle when it was swapped out
    };
    std::vector<Retired> m_retired;
};

} // namespace pp
