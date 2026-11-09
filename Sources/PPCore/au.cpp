// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// An Audio Unit in an effects chain. The helper loads it (out of process, Apple's
// AUHostingService), sets its formats and initialises it; this renders it through
// the chain's external slot (PPExternal).
//
// Each plugin renders on a realtime worker thread of its own, in one of two ways:
// - Pipelined (what the engine uses, pp_au_set_pipeline): the engine queues each block
//   and plays back the plugin's result for the block `depth` blocks earlier, never
//   waiting. A heavy plugin (an AI noise remover, say) then has `depth` whole blocks to
//   answer in, at the cost of that much delay, in this slot only. The worker renders
//   every block in order, so the plugin hears continuous sound; a result that still
//   isn't back in time plays as that block's dry sound, in step. After a gap (the slot
//   bypassed, the engine stopped) it starts afresh, so nothing stale comes out.
// - Synchronous (depth 0): the engine hands it the block and waits at most half a block.
//   If the answer isn't back by then, the block plays dry and the plugin isn't asked
//   again until its worker is free. A heavy plugin misses often, which sounds like
//   ratcheting; hence the pipeline.
// A plugin whose process died mid-call keeps the call waiting 20 ms or more (measured).
// When the process is gone, rendering fails with kAudioComponentErr_InstanceInvalidated:
// the slot goes dry and the helper reloads it.

#include "ppcore.h"
#include "ppdsp.h"

#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <mach/thread_policy.h>
#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <vector>

// One block in the pipeline. The engine writes `in` and `dry` and then queues it; the
// worker renders `in` into `out`; `state` hands it over.
struct Job
{
    enum : int { Free = 0, Queued = 1, Rendering = 2, Done = 3, Abandoned = 4 };
    std::vector<std::vector<float>> in;
    std::vector<std::vector<float>> out;
    std::vector<std::vector<float>> dry; // engine only: what to play if the result is late
    int frames = 0;
    int inChannels = 0;
    OSStatus status = noErr;
    bool submitted = false; // engine only: queued for the worker (else it was busy)
    std::atomic<int> state{Free};
};

struct PPAU
{
    AudioUnit unit = nullptr;
    int inputs = 2;
    int outputs = 2;
    int maxFrames = 4096;
    double rate = 48000;
    PPExternal external{};

    // Shared between the engine thread and the worker, handed over by the semaphores.
    std::vector<std::vector<float>> in;  // the block, copied in by the engine
    std::vector<std::vector<float>> out; // the plugin's output
    int frames = 0;
    int inChannels = 0;
    OSStatus status = noErr;
    semaphore_t go = 0, done = 0;
    std::atomic<bool> busy{false}; // the worker is in a call
    std::atomic<bool> quit{false};
    pthread_t worker{};
    bool owed = false; // engine thread only: a timed-out call will still say it's done

    // Worker only.
    AudioTimeStamp stamp{};
    std::vector<uint8_t> listStorage;
    AudioBufferList *list = nullptr;

    // For diagnosis: render call times on the worker, and blocks the engine played dry.
    std::atomic<double> slowestMs{0};
    std::atomic<uint64_t> calls{0};
    std::atomic<double> firstMs{0};
    std::atomic<uint64_t> late{0};
    // Set from any thread when the system says its process is gone.
    std::atomic<bool> gone{false};

    // The pipeline (depth 0: synchronous). Jobs are used in turn; `created` counts them.
    static constexpr int kJobs = 8;
    int depth = 0;
    std::unique_ptr<Job[]> jobs;
    std::atomic<uint64_t> created{0}; // written by the engine, read by the worker
    uint64_t next = 0;                // worker only: the next job to look at
    int warm = 0;                     // engine only: blocks still to play undelayed
    uint64_t lastCall = 0;            // engine only: mach time of the last block
    // What the render callback feeds the plugin: the block's input.
    std::vector<std::vector<float>> *feedIn = &in;
    int feedChannels = 0;
};

namespace {

double ticksToMs(uint64_t t)
{
    static mach_timebase_info_data_t tb{};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return double(t) * tb.numer / tb.denom / 1e6;
}

OSStatus feed(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
    AudioBufferList *list)
{
    auto *au = static_cast<PPAU *>(ref);
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        // Plugin input b from chain channel b, or the last one there is (mono into stereo).
        const float *src = (*au->feedIn)[size_t(std::min<int>(int(b), au->feedChannels - 1))].data();
        if (list->mBuffers[b].mData) {
            std::memcpy(list->mBuffers[b].mData, src, frames * sizeof(float));
        } else {
            list->mBuffers[b].mData = const_cast<float *>(src);
        }
        list->mBuffers[b].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}

void makeRealtime(double periodMs)
{
    mach_timebase_info_data_t tb{};
    mach_timebase_info(&tb);
    const double ticksPerMs = 1e6 * tb.denom / tb.numer;
    thread_time_constraint_policy_data_t p{};
    p.period = uint32_t(periodMs * ticksPerMs);
    p.computation = uint32_t(std::min(periodMs * 0.5, 1.0) * ticksPerMs);
    p.constraint = uint32_t(periodMs * ticksPerMs);
    p.preemptible = 1;
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p,
        THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

// One render call on the worker, timed for diagnosis.
OSStatus renderOnce(PPAU *au, int frames)
{
    if (au->depth == 0) {
        au->list->mNumberBuffers = UInt32(au->outputs);
        for (int c = 0; c < au->outputs; ++c) {
            au->list->mBuffers[c].mNumberChannels = 1;
            au->list->mBuffers[c].mData = au->out[size_t(c)].data();
            au->list->mBuffers[c].mDataByteSize = UInt32(frames) * sizeof(float);
        }
    }
    AudioUnitRenderActionFlags flags = 0;
    const uint64_t t0 = mach_absolute_time();
    const OSStatus status = AudioUnitRender(au->unit, &flags, &au->stamp, 0, UInt32(frames), au->list);
    const double ms = ticksToMs(mach_absolute_time() - t0);
    if (au->calls.fetch_add(1, std::memory_order_relaxed) == 0) au->firstMs.store(ms, std::memory_order_relaxed);
    if (ms > au->slowestMs.load(std::memory_order_relaxed)) au->slowestMs.store(ms, std::memory_order_relaxed);
    au->stamp.mSampleTime += frames;
    return status;
}

// The pipelined worker's turn: every queued job, in order.
void drainJobs(PPAU *au)
{
    while (au->next < au->created.load(std::memory_order_acquire)) {
        Job &j = au->jobs[au->next % PPAU::kJobs];
        int s = Job::Queued;
        if (j.state.compare_exchange_strong(s, Job::Rendering, std::memory_order_acq_rel)) {
            au->list->mNumberBuffers = UInt32(au->outputs);
            for (int c = 0; c < au->outputs; ++c) {
                au->list->mBuffers[c].mNumberChannels = 1;
                au->list->mBuffers[c].mData = j.out[size_t(c)].data();
                au->list->mBuffers[c].mDataByteSize = UInt32(j.frames) * sizeof(float);
            }
            au->feedIn = &j.in;
            au->feedChannels = j.inChannels;
            j.status = renderOnce(au, j.frames);
            int r = Job::Rendering;
            if (!j.state.compare_exchange_strong(r, Job::Done, std::memory_order_acq_rel)) {
                j.state.store(Job::Free, std::memory_order_release); // given up on meanwhile
            }
        } else if (s == Job::Abandoned) {
            j.state.store(Job::Free, std::memory_order_release); // given up on before its turn
        } else if (s != Job::Free) {
            break; // can't be: rendering or done belongs to an earlier pass
        }
        ++au->next; // Free: the engine couldn't queue it (this worker was that far behind)
    }
}

void *work(void *context)
{
    auto *au = static_cast<PPAU *>(context);
    pthread_setname_np("PatchPrimeMac plugin");
    makeRealtime(1000.0 * 128 / au->rate);
    while (true) {
        semaphore_wait(au->go);
        if (au->quit.load()) {
            break;
        }
        if (au->depth > 0) {
            drainJobs(au);
            continue;
        }
        au->feedIn = &au->in; // renderOnce points the output at au->out
        au->feedChannels = au->inChannels;
        au->status = renderOnce(au, au->frames);
        au->busy.store(false, std::memory_order_release);
        semaphore_signal(au->done);
    }
    return nullptr;
}


// Gives up on every job not yet played (after a gap), and plays the next `depth` blocks
// undelayed while the pipeline fills again.
void restartPipeline(PPAU *au)
{
    for (int k = 0; k < PPAU::kJobs; ++k) {
        Job &j = au->jobs[k];
        if (!j.submitted) {
            continue;
        }
        j.submitted = false;
        int s = Job::Queued;
        if (!j.state.compare_exchange_strong(s, Job::Abandoned) && s == Job::Rendering) {
            s = Job::Rendering;
            if (!j.state.compare_exchange_strong(s, Job::Abandoned) && s == Job::Done) {
                j.state.store(Job::Free, std::memory_order_release);
            }
        } else if (s == Job::Done) {
            j.state.store(Job::Free, std::memory_order_release);
        }
    }
    au->warm = au->depth;
}

// [RT] Pipelined: queue this block, play the one `depth` blocks back.
int renderPipelined(PPAU *au, float *const *planes, int channels, int frames)
{
    const uint64_t now = mach_absolute_time();
    // A gap of more than 8 blocks (or 50 ms): bypassed, or the engine stopped. Start afresh.
    const double gapMs = std::max(50.0, 8000.0 * frames / au->rate);
    if (au->lastCall != 0 && ticksToMs(now - au->lastCall) > gapMs) {
        restartPipeline(au);
    }
    au->lastCall = now;
    const int chans = std::min(channels, 2);
    const uint64_t n = au->created.load(std::memory_order_relaxed);
    // Queue this block, unless its job is still in use (the worker that far behind).
    Job &in = au->jobs[n % PPAU::kJobs];
    if (in.submitted) {
        // Never played back (can't be, short of a pipeline deeper than its jobs): free it.
        restartPipeline(au);
    }
    for (int c = 0; c < chans; ++c) {
        std::memcpy(in.dry[size_t(c)].data(), planes[c], size_t(frames) * sizeof(float));
    }
    in.frames = frames;
    in.inChannels = chans;
    if (in.state.load(std::memory_order_acquire) == Job::Free) {
        for (int c = 0; c < chans; ++c) {
            std::memcpy(in.in[size_t(c)].data(), planes[c], size_t(frames) * sizeof(float));
        }
        in.submitted = true;
        in.state.store(Job::Queued, std::memory_order_release);
    } else {
        in.submitted = false;
        au->late.fetch_add(1, std::memory_order_relaxed);
    }
    au->created.store(n + 1, std::memory_order_release);
    semaphore_signal(au->go);
    if (au->warm > 0) {
        --au->warm; // filling: this block plays undelayed and dry
        return 0;
    }
    // Play back the block `depth` blocks ago: the plugin's result, or its dry sound in step.
    Job &out = au->jobs[(n + PPAU::kJobs - uint64_t(au->depth)) % PPAU::kJobs];
    const int playFrames = std::min(frames, out.frames);
    int s = out.state.load(std::memory_order_acquire);
    if (out.submitted && s == Job::Done) {
        if (out.status == kAudioComponentErr_InstanceInvalidated) {
            out.submitted = false;
            out.state.store(Job::Free, std::memory_order_release);
            return 1; // its process is gone
        }
        if (out.status == noErr) {
            for (int c = 0; c < channels; ++c) {
                const auto &src = out.out[size_t(std::min(c, au->outputs - 1))];
                std::memcpy(planes[c], src.data(), size_t(playFrames) * sizeof(float));
            }
        } else {
            for (int c = 0; c < channels; ++c) {
                std::memcpy(planes[c], out.dry[size_t(std::min(c, out.inChannels - 1))].data(), size_t(playFrames) * sizeof(float));
            }
        }
        out.submitted = false;
        out.state.store(Job::Free, std::memory_order_release);
        return 0;
    }
    // Not back in time (or never queued): its dry sound, so the timing holds.
    for (int c = 0; c < channels; ++c) {
        std::memcpy(planes[c], out.dry[size_t(std::min(c, std::max(1, out.inChannels) - 1))].data(), size_t(playFrames) * sizeof(float));
    }
    if (out.submitted) {
        au->late.fetch_add(1, std::memory_order_relaxed);
        out.submitted = false;
        s = Job::Queued;
        if (!out.state.compare_exchange_strong(s, Job::Abandoned) && s == Job::Rendering) {
            s = Job::Rendering;
            if (!out.state.compare_exchange_strong(s, Job::Abandoned) && s == Job::Done) {
                out.state.store(Job::Free, std::memory_order_release);
            }
        }
    }
    return 0;
}

int render(void *context, float *const *planes, int channels, int frames)
{
    auto *au = static_cast<PPAU *>(context);
    if (au->gone.load(std::memory_order_relaxed)) {
        return 1;
    }
    if (frames > au->maxFrames || channels < 1) {
        return 0; // can't happen with the engine's blocks; leave the sound as it is
    }
    if (au->depth > 0) {
        return renderPipelined(au, planes, channels, frames);
    }
    if (au->busy.load(std::memory_order_acquire)) {
        au->late.fetch_add(1, std::memory_order_relaxed);
        return 0; // still in an earlier call: dry, and don't wait
    }
    if (au->owed) {
        // That earlier call has finished since: take its signal so it isn't read as this one's.
        mach_timespec_t now{0, 0};
        semaphore_timedwait(au->done, now);
        au->owed = false;
        if (au->status == kAudioComponentErr_InstanceInvalidated) {
            return 1;
        }
    }
    for (int c = 0; c < std::min(channels, 2); ++c) {
        std::memcpy(au->in[size_t(c)].data(), planes[c], size_t(frames) * sizeof(float));
    }
    au->frames = frames;
    au->inChannels = std::min(channels, 2);
    au->busy.store(true, std::memory_order_release);
    semaphore_signal(au->go);
    // At most half a block, and never less than a quarter of a millisecond.
    const double waitMs = std::max(0.25, 500.0 * frames / au->rate);
    mach_timespec_t limit{0, int(waitMs * 1e6)};
    if (semaphore_timedwait(au->done, limit) != KERN_SUCCESS) {
        au->owed = true;
        au->late.fetch_add(1, std::memory_order_relaxed);
        return 0; // dry this block
    }
    if (au->status == kAudioComponentErr_InstanceInvalidated) {
        return 1; // its process is gone
    }
    if (au->status != noErr) {
        return 0; // a passing failure: keep the dry sound this block
    }
    // Plugin output c to chain channel c; a mono plugin on a stereo chain feeds both.
    for (int c = 0; c < channels; ++c) {
        const auto &src = au->out[size_t(std::min(c, au->outputs - 1))];
        std::memcpy(planes[c], src.data(), size_t(frames) * sizeof(float));
    }
    return 0;
}

} // namespace

extern "C" {

PPAU *pp_au_create(void *audioUnit, int inputs, int outputs, int maxFrames, int latencySamples, double sampleRate)
{
    auto *au = new PPAU;
    au->unit = static_cast<AudioUnit>(audioUnit);
    au->inputs = std::max(1, inputs);
    au->outputs = std::max(1, outputs);
    au->maxFrames = std::max(16, maxFrames);
    au->rate = sampleRate > 0 ? sampleRate : 48000;
    au->in.assign(2, std::vector<float>(size_t(au->maxFrames)));
    au->out.assign(size_t(au->outputs), std::vector<float>(size_t(au->maxFrames)));
    au->listStorage.resize(sizeof(AudioBufferList) + sizeof(AudioBuffer) * size_t(au->outputs));
    au->list = reinterpret_cast<AudioBufferList *>(au->listStorage.data());
    au->stamp.mFlags = kAudioTimeStampSampleTimeValid;
    AURenderCallbackStruct cb{feed, au};
    AudioUnitSetProperty(au->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    semaphore_create(mach_task_self(), &au->go, SYNC_POLICY_FIFO, 0);
    semaphore_create(mach_task_self(), &au->done, SYNC_POLICY_FIFO, 0);
    pthread_create(&au->worker, nullptr, work, au);
    au->external.context = au;
    au->external.process = render;
    au->external.latency = latencySamples;
    return au;
}

const PPExternal *pp_au_external(PPAU *au) { return &au->external; }

void pp_au_set_pipeline(PPAU *au, int depth, int blockFrames)
{
    if (depth <= 0 || au->depth > 0) {
        return;
    }
    au->depth = std::min(depth, PPAU::kJobs - 2);
    au->jobs.reset(new Job[PPAU::kJobs]);
    for (int k = 0; k < PPAU::kJobs; ++k) {
        Job &j = au->jobs[k];
        j.in.assign(2, std::vector<float>(size_t(au->maxFrames)));
        j.dry.assign(2, std::vector<float>(size_t(au->maxFrames)));
        j.out.assign(size_t(au->outputs), std::vector<float>(size_t(au->maxFrames)));
    }
    au->warm = au->depth;
    au->external.latency += au->depth * std::max(1, blockFrames);
}

void pp_au_destroy(PPAU *au)
{
    // Its worker may still be in a call to a dead process; that ends by itself.
    au->quit.store(true);
    semaphore_signal(au->go);
    pthread_join(au->worker, nullptr);
    semaphore_destroy(mach_task_self(), au->go);
    semaphore_destroy(mach_task_self(), au->done);
    delete au;
}

void pp_au_mark_gone(PPAU *au) { au->gone.store(true, std::memory_order_relaxed); }

void pp_au_timing(const PPAU *au, double *firstMs, double *slowestMs, unsigned long long *calls)
{
    *firstMs = au->firstMs.load();
    *slowestMs = au->slowestMs.load();
    *calls = au->calls.load();
}

unsigned long long pp_au_late(const PPAU *au) { return au->late.load(); }

} // extern "C"
