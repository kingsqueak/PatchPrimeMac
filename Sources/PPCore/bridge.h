// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Moves stereo audio between two clocks: one producer thread, one consumer thread.
// Device to engine for an input, engine to device for an output.
//
// What the spikes proved, and this keeps:
//  - Rate control uses timestamps, not ring fill alone. Fill only moves in whole
//    blocks, which beat slowly between near-equal clocks.
//  - Start from where the ring really is, and trim the first overshoot.
//  - A saved rate for the device means a lock within seconds.
//  - After a gap (sleep, a device hiccup) the ring is stale: start again.
//  - Neither side ever waits. If a ring runs dry or fills up, only this path suffers.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pp {

class Bridge
{
public:
    // Block sizes in frames. The delay target follows from them.
    Bridge(double sampleRate, int producerBlock, int consumerBlock, double savedPpm);

    // Producer thread. `seconds` is the host time of this block's cycle.
    void write(const float *left, const float *right, int frames, double seconds) noexcept;

    // Consumer thread. Always fills `frames`, with silence if nothing is ready.
    void read(float *left, float *right, int frames, double seconds) noexcept;

    double targetFrames() const { return target_; }
    double ratioPpm() const { return ratioPpm_.load(std::memory_order_relaxed); }
    double position() const { return position_.load(std::memory_order_relaxed); }
    uint64_t underruns() const { return underruns_.load(std::memory_order_relaxed); }
    uint64_t overruns() const { return overruns_.load(std::memory_order_relaxed); }
    uint64_t resyncs() const { return resyncs_.load(std::memory_order_relaxed); }
    bool locked() const { return started_.load(std::memory_order_relaxed); }

private:
    static constexpr int kTaps = 32;
    static constexpr int kPhases = 256;
    static constexpr size_t kRingFrames = 1 << 16;

    size_t fill() const;
    void lock(double position) noexcept;
    double control(double position, double blockSeconds) noexcept;
    int resample(float *left, float *right, int frames, double ratio) noexcept;

    double rate_;
    double target_;
    double savedPpm_;

    std::vector<float> table_;
    std::vector<float> ringL_;
    std::vector<float> ringR_;
    std::atomic<size_t> write_{0};
    std::atomic<size_t> read_{0};
    std::atomic<double> lastProducer_{0};

    // Consumer's own state.
    double frac_ = 0;
    double lastConsumer_ = 0;
    double filtered_ = 0;
    double integral_ = 0;
    double alpha_ = 0;
    double lockedTarget_ = 0;

    std::atomic<bool> started_{false};
    std::atomic<double> ratioPpm_{0};
    std::atomic<double> position_{0};
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> overruns_{0};
    std::atomic<uint64_t> resyncs_{0};
};

} // namespace pp
