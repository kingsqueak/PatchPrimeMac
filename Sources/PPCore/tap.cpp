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
    std::size_t at = writeAt.load(std::memory_order_relaxed);
    const std::size_t r = readAt.load(std::memory_order_acquire);
    std::size_t space = data.size() - (at - r);
    // Silence owed for blocks that didn't fit, first: a few blocks' worth at a time,
    // so catching up never makes one cycle long.
    std::uint64_t debt = owed.load(std::memory_order_relaxed);
    if (debt > 0) {
        const std::size_t zeros = std::min<std::size_t>({std::size_t(debt), space / std::size_t(channels),
                                                          std::size_t(frames) * 8});
        for (std::size_t i = 0; i < zeros * std::size_t(channels); ++i) {
            data[at++ & mask] = 0.f;
        }
        debt -= zeros;
        space -= zeros * std::size_t(channels);
    }
    if (debt > 0 || space < samples) {
        // The disk fell behind: this block becomes silence, owed.
        owed.store(debt + std::uint64_t(frames), std::memory_order_relaxed);
        dropped.fetch_add(std::uint64_t(frames), std::memory_order_relaxed);
        writeAt.store(at, std::memory_order_release);
        return;
    }
    owed.store(0, std::memory_order_relaxed);
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

unsigned long long pp_tap_owed(const PPTap *t) { return t->owed.load(std::memory_order_acquire); }

} // extern "C"
