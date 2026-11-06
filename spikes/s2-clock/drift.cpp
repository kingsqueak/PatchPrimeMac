// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S2: passive clock measurement. It reads each device's clock with
// AudioDeviceGetCurrentTime and nothing else: no IOProc, no audio, no property
// changes, so it can't disturb an audio path. A device nobody is running
// reports "not running" and is skipped.
//
// drift [seconds]

#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

namespace {

std::string name(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    CFStringRef value = nullptr;
    UInt32 size = sizeof value;
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &value) != noErr || !value) {
        return "?";
    }
    char buffer[256] = {};
    CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    CFRelease(value);
    return buffer;
}

double nominalRate(AudioObjectID id)
{
    AudioObjectPropertyAddress a{kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    Float64 rate = 0;
    UInt32 size = sizeof rate;
    AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &rate);
    return rate;
}

struct Reading
{
    double seconds;
    double frames;
};

struct Device
{
    AudioObjectID id;
    std::string name;
    double nominal;
    std::vector<Reading> points;
    int resets = 0;
};

} // namespace

int main(int argc, char **argv)
{
    const int seconds = argc > 1 ? std::atoi(argv[1]) : 120;
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    const double secondsPerTick = double(tb.numer) / tb.denom * 1e-9;

    AudioObjectPropertyAddress a{kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioObjectID> ids(size / sizeof(AudioObjectID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());

    std::vector<Device> devices;
    for (const AudioObjectID id : ids) {
        devices.push_back({id, name(id), nominalRate(id), {}, 0});
    }

    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (std::chrono::steady_clock::now() < end) {
        for (Device &d : devices) {
            AudioTimeStamp t{};
            t.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
            if (AudioDeviceGetCurrentTime(d.id, &t) != noErr) {
                continue;
            }
            const Reading p{double(t.mHostTime) * secondsPerTick, t.mSampleTime};
            if (!d.points.empty() && p.frames < d.points.back().frames) {
                ++d.resets; // the device restarted: keep only the newest run
                d.points.clear();
            }
            d.points.push_back(p);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    std::printf("%-30s %8s %8s %12s %12s %7s\n", "device", "rate", "points", "ppm vs host",
        "jitter us", "resets");
    for (const Device &d : devices) {
        const size_t n = d.points.size();
        if (n < 100 || d.nominal <= 0) {
            std::printf("%-30s %8.0f %8zu   not running\n", d.name.c_str(), d.nominal, n);
            continue;
        }
        // Least-squares line, frames against seconds.
        const double x0 = d.points.front().seconds;
        const double y0 = d.points.front().frames;
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        for (const Reading &p : d.points) {
            const double x = p.seconds - x0;
            const double y = p.frames - y0;
            sx += x;
            sy += y;
            sxx += x * x;
            sxy += x * y;
        }
        const double slope = (n * sxy - sx * sy) / (n * sxx - sx * sx);
        const double intercept = (sy - slope * sx) / n;
        double sum = 0;
        for (const Reading &p : d.points) {
            const double fit = intercept + slope * (p.seconds - x0);
            const double error = (p.frames - y0 - fit) / d.nominal;
            sum += error * error;
        }
        std::printf("%-30s %8.0f %8zu %12.2f %12.1f %7d\n", d.name.c_str(), d.nominal, n,
            (slope / d.nominal - 1.0) * 1e6, std::sqrt(sum / n) * 1e6, d.resets);
    }
    return 0;
}
