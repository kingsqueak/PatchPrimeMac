// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "bridge.h"
#include "ppcore.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace pp {

namespace {
constexpr double kP = 5e-2;  // per second of error
constexpr double kI = 6e-4;  // per second squared
constexpr double kLimit = 1e-3; // 1000 ppm, never audible as pitch
constexpr double kGapSeconds = 0.1;
constexpr double kStallSeconds = 0.25;

double besselI0(double x)
{
    double sum = 1, term = 1;
    for (int k = 1; k < 32; ++k) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}
} // namespace

Bridge::Bridge(double sampleRate, int producerBlock, int consumerBlock, double savedPpm)
    : rate_(sampleRate)
    , target_(2.0 * producerBlock + consumerBlock + kTaps)
    , savedPpm_(savedPpm)
    , table_(size_t(kTaps) * size_t(kPhases + 1))
    , ringL_(kRingFrames)
    , ringR_(kRingFrames)
{
    // Windowed sinc, flat at DC at every phase.
    constexpr double kBeta = 9.0;
    constexpr double kCutoff = 0.92;
    const int half = kTaps / 2;
    for (int p = 0; p <= kPhases; ++p) {
        const double frac = double(p) / kPhases;
        double sum = 0;
        std::vector<double> row(kTaps);
        for (int t = 0; t < kTaps; ++t) {
            const double x = double(t - half + 1) - frac;
            const double sinc = std::abs(x) < 1e-12
                ? 1.0
                : std::sin(M_PI * kCutoff * x) / (M_PI * kCutoff * x);
            const double r = x / half;
            const double window
                = std::abs(r) >= 1 ? 0 : besselI0(kBeta * std::sqrt(1 - r * r)) / besselI0(kBeta);
            row[size_t(t)] = kCutoff * sinc * window;
            sum += row[size_t(t)];
        }
        for (int t = 0; t < kTaps; ++t) {
            table_[size_t(p) * kTaps + size_t(t)] = float(row[size_t(t)] / sum);
        }
    }
    alpha_ = double(consumerBlock) / sampleRate / 2.0; // a 2 s average of position
}

size_t Bridge::fill() const
{
    return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire);
}

void Bridge::write(const float *left, const float *right, int frames, double seconds) noexcept
{
    const size_t w = write_.load(std::memory_order_relaxed);
    const size_t room = kRingFrames - (w - read_.load(std::memory_order_acquire));
    const size_t n = std::min(size_t(frames), room);
    if (n < size_t(frames)) {
        overruns_.fetch_add(1, std::memory_order_relaxed);
    }
    for (size_t i = 0; i < n; ++i) {
        ringL_[(w + i) & (kRingFrames - 1)] = left[i];
        ringR_[(w + i) & (kRingFrames - 1)] = right[i];
    }
    write_.store(w + n, std::memory_order_release);
    lastProducer_.store(seconds, std::memory_order_release);
}

void Bridge::lock(double position) noexcept
{
    lockedTarget_ = position;
    filtered_ = position;
    const double ppm = ratioPpm_.load(std::memory_order_relaxed);
    integral_ = (ppm != 0 ? ppm : savedPpm_) * 1e-6 / kI;
    frac_ = 0;
}

double Bridge::control(double position, double blockSeconds) noexcept
{
    filtered_ += alpha_ * (position - filtered_);
    const double error = (filtered_ - lockedTarget_) / rate_;
    integral_ += error * blockSeconds;
    const double trim = kP * error + kI * integral_;
    if (std::abs(trim) >= kLimit) {
        integral_ -= error * blockSeconds; // no windup against the limit
    }
    return 1.0 + std::fmax(-kLimit, std::fmin(kLimit, trim));
}

int Bridge::resample(float *left, float *right, int frames, double ratio) noexcept
{
    size_t r = read_.load(std::memory_order_relaxed);
    const size_t available = write_.load(std::memory_order_acquire) - r;
    size_t used = 0;
    int made = 0;
    const size_t mask = kRingFrames - 1;
    for (; made < frames; ++made) {
        if (available - used < size_t(kTaps) + 1) {
            break;
        }
        const double position = frac_ * kPhases;
        const int p = int(position);
        const float mix = float(position - p);
        const float *a = &table_[size_t(p) * kTaps];
        const float *b = a + kTaps;
        float l0 = 0, l1 = 0, r0 = 0, r1 = 0;
        for (int t = 0; t < kTaps; ++t) {
            const size_t at = (r + used + size_t(t)) & mask;
            const float x = ringL_[at];
            const float y = ringR_[at];
            l0 += a[t] * x;
            l1 += b[t] * x;
            r0 += a[t] * y;
            r1 += b[t] * y;
        }
        left[made] = l0 + (l1 - l0) * mix;
        right[made] = r0 + (r1 - r0) * mix;
        frac_ += ratio;
        const int whole = int(frac_);
        frac_ -= whole;
        used += size_t(whole);
    }
    read_.store(r + used, std::memory_order_release);
    return made;
}

void Bridge::read(float *left, float *right, int frames, double seconds) noexcept
{
    const auto silence = [&](int from) {
        std::memset(left + from, 0, size_t(frames - from) * sizeof(float));
        std::memset(right + from, 0, size_t(frames - from) * sizeof(float));
    };
    bool started = started_.load(std::memory_order_relaxed);
    if (lastConsumer_ > 0 && seconds - lastConsumer_ > kGapSeconds && started) {
        started = false; // this side stopped and came back: the ring is stale
        resyncs_.fetch_add(1, std::memory_order_relaxed);
    }
    lastConsumer_ = seconds;

    const double producer = lastProducer_.load(std::memory_order_acquire);
    if (producer == 0) {
        silence(0);
        return;
    }
    if (seconds - producer > kStallSeconds) { // the other side has stopped
        if (started) {
            started = false;
            resyncs_.fetch_add(1, std::memory_order_relaxed);
            started_.store(false, std::memory_order_relaxed);
        }
        silence(0);
        return;
    }
    const double since = (seconds - producer) * rate_;
    const double level = double(fill());
    if (!started) {
        if (level < target_) {
            started_.store(false, std::memory_order_relaxed);
            silence(0);
            return;
        }
        read_.fetch_add(size_t(level - target_), std::memory_order_release);
        lock(target_ + since);
        started_.store(true, std::memory_order_relaxed);
    }
    if (fill() < size_t(frames) + size_t(kTaps) + 2) {
        // Dry. The rate means nothing while the ring is empty, and a controller fed
        // this position winds up, so stop steering until audio returns.
        underruns_.fetch_add(1, std::memory_order_relaxed);
        silence(0);
        return;
    }
    const double position = double(fill()) + since;
    const double ratio = control(position, frames / rate_);
    const int made = resample(left, right, frames, ratio);
    if (made < frames) {
        underruns_.fetch_add(1, std::memory_order_relaxed);
        silence(made);
    }
    ratioPpm_.store((ratio - 1) * 1e6, std::memory_order_relaxed);
    position_.store(position, std::memory_order_relaxed);
}

} // namespace pp

// For the offline tests.
extern "C" {

struct PPBridge
{
    pp::Bridge b;
};

PPBridge *pp_bridge_create(double rate, int producerBlock, int consumerBlock, double savedPpm)
{
    return new PPBridge{pp::Bridge(rate, producerBlock, consumerBlock, savedPpm)};
}
void pp_bridge_destroy(PPBridge *b) { delete b; }
void pp_bridge_write(PPBridge *b, const float *l, const float *r, int frames, double seconds)
{
    b->b.write(l, r, frames, seconds);
}
void pp_bridge_read(PPBridge *b, float *l, float *r, int frames, double seconds)
{
    b->b.read(l, r, frames, seconds);
}
double pp_bridge_ratio_ppm(const PPBridge *b) { return b->b.ratioPpm(); }
double pp_bridge_position(const PPBridge *b) { return b->b.position(); }
double pp_bridge_target(const PPBridge *b) { return b->b.targetFrames(); }
unsigned long long pp_bridge_underruns(const PPBridge *b) { return b->b.underruns(); }
unsigned long long pp_bridge_overruns(const PPBridge *b) { return b->b.overruns(); }
unsigned long long pp_bridge_resyncs(const PPBridge *b) { return b->b.resyncs(); }

} // extern "C"
