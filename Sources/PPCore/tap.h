// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// A recording tap: what the mixer hands a recording, block by block, through a
// lock-free queue a writer thread empties. Private to PPCore; see ppcore.h.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

struct PPTap
{
    PPTap(int channels, std::size_t capacitySamples);

    // [RT] Queues a block (left and right; a mono tap keeps only the left) if this
    // block is inside the tap's window.
    void push(const float *left, const float *right, int frames, std::uint64_t block) noexcept;

    int channels;
    std::vector<float> data;
    std::size_t mask = 0;
    std::atomic<std::size_t> writeAt{0};
    std::atomic<std::size_t> readAt{0};

    // The blocks it records: from start until stop (not included).
    std::atomic<std::uint64_t> start{UINT64_MAX};
    std::atomic<std::uint64_t> stop{UINT64_MAX};
    // A strip's recording: after its effects and fader (true) or before them.
    std::atomic<bool> processed{false};
    // Set by the audio thread once a block at or past stop has come by, or by the
    // control thread when the mixer is gone: nothing more will be queued.
    std::atomic<bool> finished{false};
    std::atomic<std::uint64_t> dropped{0};
    // Frames that didn't fit (the disk fell behind), owed as silence: queued before
    // anything newer as room comes, so the recording keeps its time against the
    // other tracks of a take. Whatever is still owed at the end, the writer adds.
    std::atomic<std::uint64_t> owed{0};
};
