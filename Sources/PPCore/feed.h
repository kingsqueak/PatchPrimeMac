// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The player's feed: stereo audio a reader thread decodes ahead, which the mixer's
// audio thread plays into one strip, bus or output. Private to PPCore; see ppcore.h.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

struct PPFeed
{
    explicit PPFeed(std::size_t capacityFrames);

    // [RT] The next frames into left and right: added to them, or in place of them.
    // Silence while paused (keeping its place), or where nothing is queued yet.
    void play(float *left, float *right, int frames, bool replace) noexcept;

    std::vector<float> data; // interleaved stereo
    std::size_t mask = 0;
    std::atomic<std::size_t> writeAt{0};
    std::atomic<std::size_t> readAt{0};
    std::atomic<bool> paused{false};
    std::atomic<float> gain{1.f};
    float gainNow = 1.f; // audio thread: glides to gain
    std::atomic<bool> ended{false}; // nothing more will be queued
    std::atomic<std::uint64_t> played{0};
    // Seeking: the reader asks for what's queued to be dropped, and waits until it is.
    std::atomic<std::uint32_t> flushAsked{0};
    std::atomic<std::uint32_t> flushDone{0};
};
