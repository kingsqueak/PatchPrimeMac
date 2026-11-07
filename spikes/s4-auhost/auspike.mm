// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S4: hosting Audio Units through the C API (AUv2's own), in this process or out
// of process (AudioComponentInstantiate with LoadOutOfProcess: Apple's AUHostingService).
// Renders a 1 kHz tone through one effect offline in 128-frame blocks and reports what
// each block costs. Touches no audio device: nothing is heard.
//
//   auspike <name> [inproc|outproc] [frames] [seconds] [paced] [state] [crash]
//
// paced: blocks at real time on a time-constraint thread, as the engine would.
// state: saves the plugin's state (ClassInfo), restores it, compares.
// crash: kills the hosting process half way, to see what rendering does then.

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <signal.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

static double ticksToMs(uint64_t t)
{
    static mach_timebase_info_data_t tb{};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return double(t) * tb.numer / tb.denom / 1e6;
}

static void makeRealtime(double periodMs)
{
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    const double ticksPerMs = 1e6 * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t p{};
    p.period = uint32_t(periodMs * ticksPerMs);
    p.computation = uint32_t(periodMs * 0.5 * ticksPerMs);
    p.constraint = uint32_t(periodMs * ticksPerMs);
    p.preemptible = 1;
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p,
        THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

struct Feed
{
    std::vector<std::vector<float>> in;
};

static OSStatus feedInput(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 n,
    AudioBufferList *list)
{
    auto *f = static_cast<Feed *>(ref);
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const auto &src = f->in[std::min<size_t>(b, f->in.size() - 1)];
        if (list->mBuffers[b].mData) {
            std::memcpy(list->mBuffers[b].mData, src.data(), n * sizeof(float));
        } else {
            list->mBuffers[b].mData = const_cast<float *>(src.data());
        }
        list->mBuffers[b].mDataByteSize = n * sizeof(float);
    }
    return noErr;
}

static AudioStreamBasicDescription planar(double rate, UInt32 channels)
{
    AudioStreamBasicDescription f{};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        | kAudioFormatFlagsNativeEndian;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4;
    f.mBytesPerPacket = 4;
    return f;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            std::puts("usage: auspike <name> [inproc|outproc] [frames] [seconds] [paced] [state] [crash]");
            return 2;
        }
        const std::string want = argv[1];
        const bool outOfProcess = argc > 2 && std::string(argv[2]) == "outproc";
        const int frames = argc > 3 ? std::atoi(argv[3]) : 128;
        const double seconds = argc > 4 ? std::atof(argv[4]) : 10;
        bool paced = false, testState = false, crash = false;
        for (int i = 5; i < argc; ++i) {
            const std::string a = argv[i];
            paced = paced || a == "paced";
            testState = testState || a == "state";
            crash = crash || a == "crash";
        }
        const double rate = 48000;

        AVAudioUnitComponent *found = nil;
        for (AVAudioUnitComponent *c in [[AVAudioUnitComponentManager sharedAudioUnitComponentManager]
                 componentsPassingTest:^BOOL(AVAudioUnitComponent *c, BOOL *) {
                     const OSType t = c.audioComponentDescription.componentType;
                     return t == kAudioUnitType_Effect || t == kAudioUnitType_MusicEffect;
                 }]) {
            NSString *full = [NSString stringWithFormat:@"%@: %@", c.manufacturerName, c.name];
            if ([full rangeOfString:@(want.c_str()) options:NSCaseInsensitiveSearch].location != NSNotFound) {
                found = c;
                break;
            }
        }
        if (!found) {
            std::printf("no effect matching \"%s\"\n", want.c_str());
            return 1;
        }
        std::printf("%s: %s v%s, %s\n", found.manufacturerName.UTF8String, found.name.UTF8String,
            found.versionString.UTF8String, outOfProcess ? "out of process" : "in process");

        // Load it.
        __block AudioUnit unit = nullptr;
        __block OSStatus loadStatus = noErr;
        dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
        const uint64_t loadStart = mach_absolute_time();
        AudioComponentInstantiate(found.audioComponent,
            outOfProcess ? kAudioComponentInstantiation_LoadOutOfProcess : kAudioComponentInstantiation_LoadInProcess,
            ^(AudioComponentInstance au, OSStatus status) {
                unit = au;
                loadStatus = status;
                dispatch_semaphore_signal(loaded);
            });
        while (dispatch_semaphore_wait(loaded, DISPATCH_TIME_NOW) != 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        if (!unit) {
            std::printf("load failed: %d\n", int(loadStatus));
            return 1;
        }
        std::printf("loaded in %.0f ms\n", ticksToMs(mach_absolute_time() - loadStart));

        // Its channels: Waves names say (m) or (s); ask the unit what it takes.
        UInt32 inChannels = found.name.UTF8String && std::strstr(found.name.UTF8String, "(m") ? 1 : 2;
        UInt32 outChannels = found.name.UTF8String && std::strstr(found.name.UTF8String, "(m)") ? 1 : 2;
        AudioStreamBasicDescription inFmt = planar(rate, inChannels), outFmt = planar(rate, outChannels);
        OSStatus s = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inFmt, sizeof inFmt);
        if (s != noErr) std::printf("input format %u ch refused: %d\n", inChannels, int(s));
        s = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outFmt, sizeof outFmt);
        if (s != noErr) std::printf("output format %u ch refused: %d\n", outChannels, int(s));
        UInt32 maxFrames = UInt32(std::max(frames, 512));
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof maxFrames);
        Feed feed;
        feed.in.assign(inChannels, std::vector<float>(size_t(maxFrames)));
        AURenderCallbackStruct cb{feedInput, &feed};
        s = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
        if (s != noErr) std::printf("render callback refused: %d\n", int(s));
        s = AudioUnitInitialize(unit);
        if (s != noErr) {
            std::printf("initialize failed: %d\n", int(s));
            return 1;
        }
        Float64 latency = 0, tail = 0;
        UInt32 size = sizeof latency;
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
        size = sizeof tail;
        AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size);
        std::printf("%u in, %u out; latency %.2f ms, tail %.2f s; custom view: %s\n", inChannels, outChannels,
            latency * 1000, tail, found.hasCustomView ? "yes" : "no");

        std::vector<std::vector<float>> out(outChannels, std::vector<float>(size_t(maxFrames)));
        auto *outList = static_cast<AudioBufferList *>(calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer) * outChannels));
        const int blocks = int(seconds * rate / frames);
        std::vector<double> costs;
        costs.reserve(size_t(blocks));
        float peak = 0;
        int errors = 0;
        OSStatus firstError = noErr;
        int firstErrorBlock = -1;
        const double periodMs = 1000.0 * frames / rate;
        double phase = 0;
        pid_t hostPid = 0;
        if (crash && outOfProcess) {
            // The hosting process: the newest AUHostingService.
            FILE *p = popen("pgrep -n AUHostingService", "r");
            if (p && fscanf(p, "%d", &hostPid) != 1) hostPid = 0;
            if (p) pclose(p);
            std::printf("hosting process: %d\n", hostPid);
        }
        AudioUnit au = unit; // the render thread's copy
        std::thread worker([&] {
            if (paced) makeRealtime(periodMs);
            AudioTimeStamp ts{};
            ts.mFlags = kAudioTimeStampSampleTimeValid;
            uint64_t next = mach_absolute_time();
            mach_timebase_info_data_t tb{};
            mach_timebase_info(&tb);
            const uint64_t period = uint64_t(periodMs * 1e6 * tb.denom / tb.numer);
            for (int b = 0; b < blocks; ++b) {
                if (crash && hostPid > 0 && b == blocks / 2) kill(hostPid, SIGKILL);
                for (int i = 0; i < frames; ++i) {
                    const float v = float(0.25 * std::sin(phase));
                    phase += 2 * M_PI * 1000 / rate;
                    for (auto &c : feed.in) c[size_t(i)] = v;
                }
                outList->mNumberBuffers = outChannels;
                for (UInt32 c = 0; c < outChannels; ++c) {
                    outList->mBuffers[c].mNumberChannels = 1;
                    outList->mBuffers[c].mData = out[c].data();
                    outList->mBuffers[c].mDataByteSize = UInt32(frames) * sizeof(float);
                }
                AudioUnitRenderActionFlags flags = 0;
                const uint64_t t0 = mach_absolute_time();
                const OSStatus r = AudioUnitRender(au, &flags, &ts, 0, UInt32(frames), outList);
                costs.push_back(ticksToMs(mach_absolute_time() - t0));
                if (r != noErr) {
                    if (errors == 0) {
                        firstError = r;
                        firstErrorBlock = b;
                    }
                    ++errors;
                } else if (b > blocks / 4) {
                    for (UInt32 c = 0; c < outChannels; ++c) {
                        for (int i = 0; i < frames; ++i) peak = std::max(peak, std::fabs(out[c][size_t(i)]));
                    }
                }
                ts.mSampleTime += frames;
                if (paced) {
                    next += period;
                    mach_wait_until(next);
                }
            }
        });
        worker.join();
        std::vector<double> sorted = costs;
        std::sort(sorted.begin(), sorted.end());
        auto at = [&](double q) { return sorted[std::min(sorted.size() - 1, size_t(q * double(sorted.size())))]; };
        double sum = 0;
        for (double c : sorted) sum += c;
        std::printf("%d blocks of %d (%.2f ms)%s: median %.3f ms, p99 %.3f, p99.9 %.3f, max %.3f; average %.1f%% of a block; "
                    "output peak %.1f dBFS\n",
            blocks, frames, periodMs, paced ? ", paced" : "", at(0.5), at(0.99), at(0.999), sorted.back(),
            100 * sum / double(sorted.size()) / periodMs, peak > 0 ? 20 * std::log10(peak) : -999.0);
        int late = 0;
        for (double c : costs) late += c > periodMs * 0.5 ? 1 : 0;
        std::printf("blocks over half their time: %d; render errors: %d", late, errors);
        if (errors) std::printf(" (first %d at block %d, %.2f s in)", int(firstError), firstErrorBlock, firstErrorBlock * periodMs / 1000);
        std::printf("\n");
        if (crash && firstErrorBlock >= 0) {
            double worst = 0;
            for (int b = firstErrorBlock; b < int(costs.size()); ++b) worst = std::max(worst, costs[size_t(b)]);
            std::printf("after the crash: the slowest render call took %.3f ms\n", worst);
        }

        if (testState) {
            CFPropertyListRef state = nullptr;
            size = sizeof state;
            const OSStatus g = AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size);
            if (g != noErr || !state) {
                std::printf("state: couldn't read (%d)\n", int(g));
            } else {
                NSData *data = [NSPropertyListSerialization dataWithPropertyList:(__bridge id)state
                                                                           format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                const OSStatus put = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, sizeof state);
                CFPropertyListRef back = nullptr;
                size = sizeof back;
                AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &back, &size);
                NSData *again = back ? [NSPropertyListSerialization dataWithPropertyList:(__bridge id)back
                                                                                   format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] : nil;
                std::printf("state: %lu bytes; restore %s; read back %s\n", (unsigned long)data.length,
                    put == noErr ? "ok" : "failed", [data isEqualToData:again] ? "identical" : "differs");
                CFRelease(state);
                if (back) CFRelease(back);
            }
        }
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        free(outList);
    }
    return 0;
}
