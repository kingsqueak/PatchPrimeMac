// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris

#include "feed.h"

#include "include/ppcore.h"

#include <algorithm>
#include <bit>

PPFeed::PPFeed(std::size_t capacityFrames)
{
    const std::size_t size = std::bit_ceil(std::max<std::size_t>(capacityFrames, 1024) * 2);
    data.assign(size, 0.f);
    mask = size - 1;
}

void PPFeed::play(float *left, float *right, int frames, bool replace) noexcept
{
    const std::uint32_t asked = flushAsked.load(std::memory_order_acquire);
    if (asked != flushDone.load(std::memory_order_relaxed)) {
        readAt.store(writeAt.load(std::memory_order_acquire), std::memory_order_release);
        played.store(0, std::memory_order_relaxed);
        flushDone.store(asked, std::memory_order_release);
    }
    std::size_t r = readAt.load(std::memory_order_relaxed);
    const std::size_t w = writeAt.load(std::memory_order_acquire);
    const int have = paused.load(std::memory_order_relaxed) ? 0 : int(std::min<std::size_t>((w - r) / 2, std::size_t(frames)));
    const float target = gain.load(std::memory_order_relaxed);
    const float step = (target - gainNow) / float(std::max(frames, 1));
    for (int f = 0; f < frames; ++f) {
        float l = 0.f, rr = 0.f;
        if (f < have) {
            const float g = gainNow + step * float(f);
            l = data[r++ & mask] * g;
            rr = data[r++ & mask] * g;
        }
        if (replace) {
            left[f] = l;
            right[f] = rr;
        } else {
            left[f] += l;
            right[f] += rr;
        }
    }
    gainNow = target;
    readAt.store(r, std::memory_order_release);
    played.fetch_add(std::uint64_t(have), std::memory_order_relaxed);
}

extern "C" {

PPFeed *pp_feed_create(int capacityFrames) { return new PPFeed(std::size_t(std::max(capacityFrames, 1024))); }

void pp_feed_destroy(PPFeed *f) { delete f; }

int pp_feed_space(const PPFeed *f)
{
    const std::size_t used = f->writeAt.load(std::memory_order_relaxed) - f->readAt.load(std::memory_order_acquire);
    return int((f->data.size() - used) / 2);
}

int pp_feed_write(PPFeed *f, const float *stereo, int frames)
{
    const int n = std::min(frames, pp_feed_space(f));
    std::size_t w = f->writeAt.load(std::memory_order_relaxed);
    for (int i = 0; i < 2 * n; ++i) {
        f->data[w++ & f->mask] = stereo[i];
    }
    f->writeAt.store(w, std::memory_order_release);
    return n;
}

void pp_feed_set_paused(PPFeed *f, int paused) { f->paused.store(paused != 0, std::memory_order_relaxed); }

void pp_feed_set_gain(PPFeed *f, float g) { f->gain.store(std::max(0.f, g), std::memory_order_relaxed); }

void pp_feed_end(PPFeed *f) { f->ended.store(true, std::memory_order_release); }

int pp_feed_finished(const PPFeed *f)
{
    return f->ended.load(std::memory_order_acquire)
        && f->readAt.load(std::memory_order_acquire) == f->writeAt.load(std::memory_order_acquire) ? 1 : 0;
}

unsigned long long pp_feed_played(const PPFeed *f) { return f->played.load(std::memory_order_relaxed); }

unsigned int pp_feed_flush(PPFeed *f)
{
    f->ended.store(false, std::memory_order_release);
    return f->flushAsked.fetch_add(1, std::memory_order_acq_rel) + 1;
}

int pp_feed_flushed(const PPFeed *f, unsigned int ticket)
{
    return f->flushDone.load(std::memory_order_acquire) == ticket ? 1 : 0;
}

} // extern "C"
