// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "tap.h"

#include "include/ppcore.h"

#include <algorithm>
#include <bit>

PPTap::PPTap(int channels, std::size_t capacitySamples)
    : channels(channels == 1 ? 1 : 2)
{
    const std::size_t size = std::bit_ceil(std::max<std::size_t>(capacitySamples, 1024));
    data.assign(size, 0.f);
    mask = size - 1;
}

void PPTap::push(const float *left, const float *right, int frames, std::uint64_t block) noexcept
{
    if (finished.load(std::memory_order_relaxed)) {
        return;
    }
    if (block >= stop.load(std::memory_order_acquire)) {
        finished.store(true, std::memory_order_release);
        return;
    }
    if (block < start.load(std::memory_order_acquire) || frames <= 0) {
        return;
    }
    const std::size_t samples = std::size_t(frames) * std::size_t(channels);
    const std::size_t w = writeAt.load(std::memory_order_relaxed);
    const std::size_t r = readAt.load(std::memory_order_acquire);
    if (data.size() - (w - r) < samples) {
        dropped.fetch_add(std::uint64_t(frames), std::memory_order_relaxed); // the disk fell behind
        return;
    }
    std::size_t at = w;
    for (int f = 0; f < frames; ++f) {
        data[at++ & mask] = left[f];
        if (channels == 2) {
            data[at++ & mask] = right[f];
        }
    }
    writeAt.store(at, std::memory_order_release);
}

extern "C" {

PPTap *pp_tap_create(int channels, int capacityFrames)
{
    return new PPTap(channels, std::size_t(std::max(capacityFrames, 1024)) * std::size_t(channels == 1 ? 1 : 2));
}

void pp_tap_destroy(PPTap *t) { delete t; }

void pp_tap_set_window(PPTap *t, unsigned long long start, unsigned long long stop)
{
    t->start.store(start, std::memory_order_release);
    t->stop.store(stop, std::memory_order_release);
}

void pp_tap_stop_at(PPTap *t, unsigned long long stop) { t->stop.store(stop, std::memory_order_release); }

void pp_tap_set_processed(PPTap *t, int processed) { t->processed.store(processed != 0, std::memory_order_relaxed); }

void pp_tap_end(PPTap *t) { t->finished.store(true, std::memory_order_release); }

int pp_tap_channels(const PPTap *t) { return t->channels; }

int pp_tap_read(PPTap *t, float *out, int maxFrames)
{
    const std::size_t r = t->readAt.load(std::memory_order_relaxed);
    const std::size_t w = t->writeAt.load(std::memory_order_acquire);
    const std::size_t frames = std::min((w - r) / std::size_t(t->channels), std::size_t(std::max(maxFrames, 0)));
    const std::size_t samples = frames * std::size_t(t->channels);
    for (std::size_t i = 0; i < samples; ++i) {
        out[i] = t->data[(r + i) & t->mask];
    }
    t->readAt.store(r + samples, std::memory_order_release);
    return int(frames);
}

int pp_tap_finished(const PPTap *t)
{
    return t->finished.load(std::memory_order_acquire)
        && t->readAt.load(std::memory_order_acquire) == t->writeAt.load(std::memory_order_acquire) ? 1 : 0;
}

unsigned long long pp_tap_dropped(const PPTap *t) { return t->dropped.load(std::memory_order_relaxed); }

} // extern "C"
