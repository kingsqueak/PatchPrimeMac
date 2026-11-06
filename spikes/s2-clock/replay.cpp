// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: replays real device timestamps (from measure) through the follower
// and rate controller, with the engine on an ideal host clock, as it would be
// on the driver. No audio devices are touched.
//
// replay <csv> [blocks of margin]

#include "follower.h"

#include <mach/mach_time.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace pp;

namespace {

struct Cycle
{
    double seconds;
    double sample;
    int frames;
};

} // namespace

int main(int argc, char **argv)
{
    if (argc < 2) {
        return 2;
    }
    const double margin = argc > 2 ? std::atof(argv[2]) : 2.0;
    const double savedPpm = argc > 3 ? std::atof(argv[3]) : 0.0;
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    const double secondsPerTick = double(tb.numer) / tb.denom * 1e-9;

    FILE *f = std::fopen(argv[1], "r");
    if (!f) {
        return 1;
    }
    std::vector<Cycle> cycles;
    unsigned long long host;
    double sample;
    int frames;
    while (std::fscanf(f, "%llu,%lf,%d", &host, &sample, &frames) == 3) {
        cycles.push_back({double(host) * secondsPerTick, sample, frames});
    }
    std::fclose(f);

    constexpr int kEngineBlock = 128;
    constexpr double kRate = 48000;
    const double blockSeconds = kEngineBlock / kRate;
    const int deviceBlock = cycles[0].frames;
    const double target = margin * deviceBlock + kEngineBlock + 32;

    // Direct line for the true rate, to judge the controller against.
    const double trueRatio = (cycles.back().sample - cycles.front().sample)
        / (cycles.back().seconds - cycles.front().seconds) / kRate;

    Ring ring(1 << 16);
    Resampler resampler(32, 256);
    RateController controller(target, blockSeconds);
    std::vector<float> in(size_t(deviceBlock), 0.1f);
    std::vector<float> out(kEngineBlock);

    size_t next = 0, written = 0, underruns = 0, overruns = 0;
    bool started = false;
    double startedAt = 0, minFill = 1e12, maxFill = 0;
    double sumRatio = 0, sumSquare = 0, count = 0, maxOff = 0;
    const double t0 = cycles.front().seconds;
    const double settleSeconds = argc > 4 ? std::atof(argv[4]) : 120;
    const double end = cycles.back().seconds;
    for (double t = t0; t < end; t += blockSeconds) {
        while (next < cycles.size() && cycles[next].seconds <= t) {
            if (ring.write(in.data(), size_t(cycles[next].frames))
                < size_t(cycles[next].frames)) {
                ++overruns;
            }
            written += size_t(cycles[next].frames);
            ++next;
        }
        const double fill = double(ring.fill());
        if (next == 0) {
            continue;
        }
        // Frames the device has run past its last reported cycle, from its stamp.
        const double since = (t - cycles[next - 1].seconds) * kRate;
        const double position = fill + since;
        if (!started) {
            if (fill < target) {
                continue;
            }
            // Devices deliver whole blocks, so the first fill overshoots. Trim to
            // the target so the overshoot doesn't become permanent latency.
            ring.consume(size_t(fill - target));
            controller.lock(target + since, savedPpm);
            started = true;
            startedAt = t;
        }
        const double ratio = controller.update(double(ring.fill()) + since, blockSeconds);
        if (resampler.process(ring, out.data(), kEngineBlock, ratio) < kEngineBlock) {
            ++underruns;
        }
        if (t - startedAt > settleSeconds) { // judge after it has settled
            minFill = std::min(minFill, fill);
            maxFill = std::max(maxFill, fill);
            const double ppm = (ratio - trueRatio) * 1e6;
            sumRatio += ppm;
            sumSquare += ppm * ppm;
            maxOff = std::max(maxOff, std::abs(ppm));
            count += 1;
        }
    }
    std::printf("  margin %.1f blocks, target %.0f frames (%.1f ms): true rate %+.2f ppm\n", margin,
        target, target / 48.0, (trueRatio - 1) * 1e6);
    std::printf("    after settling: ratio error mean %+.2f, rms %.2f, max %.2f ppm; fill %.0f..%.0f;"
                " underruns %zu, overruns %zu\n",
        sumRatio / count, std::sqrt(sumSquare / count), maxOff, minFill, maxFill, underruns, overruns);
    return 0;
}
