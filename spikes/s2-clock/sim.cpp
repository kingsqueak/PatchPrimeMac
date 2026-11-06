// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: offline tests of the follower. No audio devices are touched.
//  1. Resampler quality and cost at several filter sizes, by distortion of a
//     997 Hz tone at a drifting ratio, and CPU per channel.
//  2. Clock tracking: a simulated device with drift, jitter and different block
//     sizes feeds the ring. Does it settle, hold, and survive sudden changes?

#include "follower.h"

#include <chrono>
#include <cstdio>
#include <random>
#include <vector>

using namespace pp;

namespace {

constexpr double kRate = 48000;

// Residual after least-squares removal of the tone, in dB relative to the tone.
double residualDb(const std::vector<float> &x, double hz)
{
    // Three-parameter fit per short window, so slow phase movement from the
    // moving ratio isn't counted as distortion.
    const size_t window = 4800;
    double signal = 0, noise = 0;
    for (size_t start = 0; start + window <= x.size(); start += window) {
        double frequency = hz;
        double bestNoise = 1e30, bestSignal = 0;
        for (int step = -8; step <= 8; ++step) {
            frequency = hz * (1 + step * 1e-6);
            double ss = 0, cc = 0, sc = 0, xs = 0, xc = 0;
            for (size_t i = 0; i < window; ++i) {
                const double w = 2 * M_PI * frequency * double(i) / kRate;
                const double s = std::sin(w), c = std::cos(w);
                ss += s * s;
                cc += c * c;
                sc += s * c;
                xs += x[start + i] * s;
                xc += x[start + i] * c;
            }
            const double det = ss * cc - sc * sc;
            const double a = (xs * cc - xc * sc) / det;
            const double b = (xc * ss - xs * sc) / det;
            double n = 0, t = 0;
            for (size_t i = 0; i < window; ++i) {
                const double w = 2 * M_PI * frequency * double(i) / kRate;
                const double fit = a * std::sin(w) + b * std::cos(w);
                const double e = x[start + i] - fit;
                n += e * e;
                t += fit * fit;
            }
            if (n < bestNoise) {
                bestNoise = n;
                bestSignal = t;
            }
        }
        signal += bestSignal;
        noise += bestNoise;
    }
    return 10 * std::log10(noise / signal);
}

double tone(int taps, double hz)
{
    Resampler resampler(taps, 256);
    Ring ring(1 << 17);
    const size_t total = size_t(kRate) * 2;
    std::vector<float> in(4096), out, block(128);
    out.reserve(total);
    double phase = 0;
    while (out.size() < total) {
        while (ring.fill() < 8192) {
            for (float &v : in) {
                v = 0.5f * float(std::sin(phase));
                phase += 2 * M_PI * hz / kRate;
            }
            ring.write(in.data(), in.size());
        }
        const int n = resampler.process(ring, block.data(), 128, 1.00004);
        out.insert(out.end(), block.begin(), block.begin() + n);
    }
    std::vector<float> settled(out.begin() + 4800, out.end());
    return residualDb(settled, hz * 1.00004);
}

void quality()
{
    std::puts("resampler: distortion of a -6 dBFS 997 Hz tone at 1 + 40 ppm, and cost");
    std::puts("  taps  phases   residual dB   % of one core per channel");
    for (const int taps : {8, 16, 24, 32, 48}) {
        constexpr int kPhases = 256;
        Resampler resampler(taps, kPhases);
        Ring ring(1 << 17);
        const size_t total = size_t(kRate) * 4;
        std::vector<float> in(4096);
        std::vector<float> out;
        out.reserve(total);
        std::vector<float> block(128);
        double phase = 0;
        double spent = 0;
        size_t produced = 0;
        while (produced < total) {
            while (ring.fill() < 8192) {
                for (float &v : in) {
                    v = 0.5f * float(std::sin(phase));
                    phase += 2 * M_PI * 997.0 / kRate;
                }
                ring.write(in.data(), in.size());
            }
            const auto t0 = std::chrono::steady_clock::now();
            const int n = resampler.process(ring, block.data(), 128, 1.00004);
            spent += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            out.insert(out.end(), block.begin(), block.begin() + n);
            produced += size_t(n);
        }
        std::vector<float> settled(out.begin() + 4800, out.end());
        std::printf("  %4d  %6d   %11.1f   %6.3f\n", taps, kPhases, residualDb(settled, 997.0 * 1.00004),
            100 * spent / (double(produced) / kRate));
    }
}

struct Event
{
    double at;
    double ppm;
    const char *what;
};

void track(double startPpm, int deviceBlock, const std::vector<Event> &events, int minutes,
    double blocksOfMargin = 2.0)
{
    constexpr int kEngineBlock = 128;
    // Position counts frames still on their way, so this is the real delay.
    const double kTarget = blocksOfMargin * deviceBlock + kEngineBlock + 32;
    Ring ring(1 << 15);
    Resampler resampler(16, 256);
    RateController controller(kTarget, kEngineBlock / kRate);
    std::mt19937 random(1);
    std::normal_distribution<double> jitter(0, 1); // frames of arrival jitter

    double ppm = startPpm;
    double deviceClock = 0; // input frames due, at the device's own rate
    double delivered = 0;
    std::vector<float> in(size_t(deviceBlock) * 4, 0.1f);
    std::vector<float> out(kEngineBlock);
    size_t underruns = 0, overruns = 0;
    double minFill = 1e9, maxFill = 0, settleAt = -1;
    double lastBad = 0;
    bool started = false;

    const double blockSeconds = kEngineBlock / kRate;
    const auto blocks = size_t(minutes * 60.0 / blockSeconds);
    size_t nextEvent = 0;
    std::printf("device %+.1f ppm, %d-frame blocks, engine %d, target %.0f frames (%.1f ms), %d min\n",
        startPpm, deviceBlock, kEngineBlock, kTarget, kTarget / 48.0, minutes);
    for (size_t b = 0; b < blocks; ++b) {
        const double now = double(b) * blockSeconds;
        if (nextEvent < events.size() && now >= events[nextEvent].at) {
            ppm = events[nextEvent].ppm;
            std::printf("  t=%.0fs %s, now %+.1f ppm\n", now, events[nextEvent].what, ppm);
            ++nextEvent;
            lastBad = now;
        }
        deviceClock += kEngineBlock * (1 + ppm * 1e-6);
        // The device delivers whole blocks, a little early or late.
        while (delivered + deviceBlock <= deviceClock + 8 * jitter(random)) {
            if (ring.write(in.data(), size_t(deviceBlock)) < size_t(deviceBlock)) {
                ++overruns;
            }
            delivered += deviceBlock;
        }
        // Ring fill only moves in whole device blocks, which beats slowly against
        // the engine's. So the controller gets a continuous position: frames in the
        // ring, plus how far the device has run since its last block, as its
        // timestamps report it. Those are noisy, hence the jitter here.
        const double fill = double(ring.fill());
        const double position = fill + (deviceClock - delivered) + 8 * jitter(random);
        if (now > 10) {
            minFill = std::min(minFill, fill);
            maxFill = std::max(maxFill, fill);
        }
        if (!started) { // silence until the ring holds its target
            started = fill >= kTarget;
            continue;
        }
        const double ratio = controller.update(position, blockSeconds);
        if (resampler.process(ring, out.data(), kEngineBlock, ratio) < kEngineBlock) {
            ++underruns;
        }
        const double wanted = 1 + ppm * 1e-6;
        if (std::abs(ratio - wanted) * 1e6 > 2) {
            lastBad = now;
        } else if (settleAt < 0 && now - lastBad > 5) {
            settleAt = now;
        }
    }
    std::printf("  ratio %+.2f ppm (true %+.2f), settled by %.0f s, last off by >2 ppm at %.0f s\n",
        (controller.ratio() - 1) * 1e6, ppm, settleAt, lastBad);
    std::printf("  fill %.0f..%.0f (target %.0f), underruns %zu, overruns %zu\n", minFill, maxFill,
        kTarget, underruns, overruns);
}

} // namespace

int main()
{
    quality();
    std::puts("(tone at 997 Hz; see below for 15 kHz)");
    for (const int taps : {8, 16, 32, 48}) {
        std::printf("  %d taps at 15 kHz: %.1f dB, at 19 kHz: %.1f dB\n", taps, tone(taps, 15000),
            tone(taps, 19000));
    }
    const std::vector<Event> changes{
        {60, -30, "device warms up"}, {120, +200, "clock changes sharply"}};
    for (const int block : {128, 512, 1024}) {
        for (const double margin : {1.5, 2.0, 3.0}) {
            track(+37.0, block, changes, 5, margin);
        }
    }
    track(+37.0, 128, {}, 30, 2.0);
}
