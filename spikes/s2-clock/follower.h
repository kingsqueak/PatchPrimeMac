// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: what a hardware follower needs. A lock-free ring between two clocks,
// a resampler whose ratio can move while it runs, and a controller that holds
// the ring at its target fill. Nothing in the hot paths allocates or blocks; if
// a ring runs dry or overflows, only that device loses samples.

#pragma once

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pp {

// Single producer, single consumer, mono for the spike.
class Ring
{
public:
    explicit Ring(size_t frames)
        : mask_(frames - 1)
        , data_(frames)
    {
    }

    size_t fill() const
    {
        return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire);
    }

    size_t capacity() const { return mask_ + 1; }

    // Returns frames accepted. Never blocks: extra frames are dropped.
    size_t write(const float *in, size_t frames)
    {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t room = capacity() - (w - read_.load(std::memory_order_acquire));
        const size_t n = frames < room ? frames : room;
        for (size_t i = 0; i < n; ++i) {
            data_[(w + i) & mask_] = in[i];
        }
        write_.store(w + n, std::memory_order_release);
        return n;
    }

    // Read without consuming, for the resampler's history.
    float peek(size_t offset) const
    {
        return data_[(read_.load(std::memory_order_relaxed) + offset) & mask_];
    }

    void consume(size_t frames) { read_.fetch_add(frames, std::memory_order_release); }

private:
    size_t mask_;
    std::vector<float> data_;
    std::atomic<size_t> write_{0};
    std::atomic<size_t> read_{0};
};

// Windowed-sinc polyphase with linear interpolation between phases.
class Resampler
{
public:
    Resampler(int taps, int phases, double cutoff = 0.92)
        : taps_(taps)
        , phases_(phases)
        , table_(size_t(taps) * size_t(phases + 1))
    {
        const double beta = 9.0; // Kaiser window
        const auto bessel = [](double x) {
            double sum = 1, term = 1;
            for (int k = 1; k < 32; ++k) {
                term *= (x / (2 * k)) * (x / (2 * k));
                sum += term;
            }
            return sum;
        };
        const int half = taps / 2;
        for (int p = 0; p <= phases; ++p) {
            const double frac = double(p) / phases;
            double sum = 0;
            for (int t = 0; t < taps; ++t) {
                const double x = double(t - half + 1) - frac;
                const double sinc
                    = std::abs(x) < 1e-12 ? 1.0 : std::sin(M_PI * cutoff * x) / (M_PI * cutoff * x);
                const double r = x / half;
                const double window
                    = std::abs(r) >= 1 ? 0 : bessel(beta * std::sqrt(1 - r * r)) / bessel(beta);
                const double c = cutoff * sinc * window;
                table_[size_t(p) * taps + t] = float(c);
                sum += c;
            }
            for (int t = 0; t < taps; ++t) { // flat at DC at every phase
                table_[size_t(p) * taps + t] = float(table_[size_t(p) * taps + t] / sum);
            }
        }
    }

    int taps() const { return taps_; }

    // Output frames at `ratio` input frames per output frame. Stops if the ring
    // lacks history and returns the frames made; the caller fills with silence.
    int process(Ring &ring, float *out, int frames, double ratio)
    {
        for (int i = 0; i < frames; ++i) {
            if (ring.fill() < size_t(taps_) + 1) {
                return i;
            }
            const double position = frac_ * phases_;
            const int p = int(position);
            const float mix = float(position - p);
            const float *a = &table_[size_t(p) * taps_];
            const float *b = a + taps_;
            float s0 = 0, s1 = 0;
            for (int t = 0; t < taps_; ++t) {
                const float x = ring.peek(size_t(t));
                s0 += a[t] * x;
                s1 += b[t] * x;
            }
            out[i] = s0 + (s1 - s0) * mix;
            frac_ += ratio;
            const int whole = int(frac_);
            frac_ -= whole;
            ring.consume(size_t(whole));
        }
        return frames;
    }

private:
    int taps_;
    int phases_;
    std::vector<float> table_;
    double frac_ = 0;
};

// Holds the ring at a target fill. The fill is averaged over several seconds,
// so block-sized sawtooth and timestamp jitter don't move the ratio.
class RateController
{
public:
    RateController(double targetFrames, double blockSeconds)
        : target_(targetFrames)
        , alpha_(blockSeconds / 2.0)
        , filtered_(targetFrames)
    {
    }

    // Starts from where the ring really is, so that the loop has no step to work
    // off. A saved rate for this device, if there is one, starts the integrator
    // near the answer. `ppm` is relative to the engine clock.
    void lock(double position, double ppm)
    {
        target_ = position;
        filtered_ = position;
        constexpr double kI = 6e-4;
        integral_ = ppm * 1e-6 / kI;
        ratio_ = 1.0 + ppm * 1e-6;
    }

    // Returns the ratio for the next block.
    double update(double fill, double blockSeconds)
    {
        filtered_ += alpha_ * (fill - filtered_);
        const double error = (filtered_ - target_) / 48000.0; // seconds
        integral_ += error * blockSeconds;
        constexpr double kP = 5e-2;
        constexpr double kI = 6e-4;
        constexpr double kLimit = 1e-3; // 1000 ppm: never audible as pitch
        const double trim = kP * error + kI * integral_;
        if (std::abs(trim) >= kLimit) {
            integral_ -= error * blockSeconds; // no windup against the limit
        }
        ratio_ = 1.0 + std::fmax(-kLimit, std::fmin(kLimit, trim));
        return ratio_;
    }

    double ratio() const { return ratio_; }

private:
    double target_;
    double alpha_;
    double filtered_;
    double integral_ = 0;
    double ratio_ = 1.0;
};

} // namespace pp
