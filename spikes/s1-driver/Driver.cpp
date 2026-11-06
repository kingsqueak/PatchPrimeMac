// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S1: a throwaway test driver. It answers:
//  - does coreaudiod load this when ad-hoc signed, with SIP on?
//  - can one hidden engine device and many visible devices share one clock?
//  - can a device be added or removed while the others are running?
// Nothing here is product code. No DSP, no persistence.
//
// Audio layout: 16 stereo slots in rings addressed by sample time. Slot N is
// channels 2N, 2N+1 of the hidden engine device. A visible output device
// ("apps play here") writes its slot, and the engine reads it. The engine
// writes a slot, and a visible input device ("apps record here") reads it.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <array>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <sstream>
#include <string>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kSlots = 16;
constexpr UInt32 kEngineChannels = kSlots * 2;
constexpr UInt32 kPeriodFrames = 16384;
constexpr UInt32 kRingFrames = 65536; // power of two, a multiple of the period
constexpr UInt32 kClockDomain = 0x50504D43; // 'PPMC': every device reports this
constexpr AudioObjectPropertySelector kCommandProperty = 'ppcm';
constexpr AudioObjectPropertySelector kRateProperty = 'pprt';
const char *const kEngineUID = "PatchPrimeMacSpike.Engine";

// One timeline for every device. Rebased when the rate changes, so that the
// timeline stays continuous. Readers use a seqlock, because several device IO
// threads call this at once and must not take a lock.
class SharedClock
{
public:
    SharedClock()
    {
        mach_timebase_info_data_t tb{};
        mach_timebase_info(&tb);
        hostPerSecond_ = 1e9 * double(tb.denom) / double(tb.numer);
        nominalTicksPerPeriod_ = hostPerSecond_ * kPeriodFrames / kSampleRate;
        ticksPerPeriod_.store(nominalTicksPerPeriod_);
        anchorHost_.store(mach_absolute_time());
    }

    void zeroTimeStamp(Float64 *sampleTime, UInt64 *hostTime) const
    {
        UInt64 anchorHost, anchorPeriod;
        double ticks;
        UInt32 seq;
        do {
            seq = seq_.load(std::memory_order_acquire);
            anchorHost = anchorHost_.load(std::memory_order_relaxed);
            anchorPeriod = anchorPeriod_.load(std::memory_order_relaxed);
            ticks = ticksPerPeriod_.load(std::memory_order_relaxed);
        } while ((seq & 1) != 0 || seq != seq_.load(std::memory_order_acquire));

        const double elapsed = double(mach_absolute_time()) - double(anchorHost);
        const auto periods = SInt64(elapsed / ticks);
        // Just after a rebase, "now" can be a moment before the new anchor.
        const SInt64 stepped = elapsed < 0 ? periods - 1 : periods;
        *sampleTime = double(SInt64(anchorPeriod) + stepped) * kPeriodFrames;
        *hostTime = UInt64(double(anchorHost) + double(stepped) * ticks);
    }

    // Called off the IO threads only. The next period starts at the new rate.
    void setRatePpm(double ppm)
    {
        std::lock_guard lock(writer_);
        const double oldTicks = ticksPerPeriod_.load();
        const UInt64 oldAnchor = anchorHost_.load();
        const UInt64 oldPeriod = anchorPeriod_.load();
        const double done = (double(mach_absolute_time()) - double(oldAnchor)) / oldTicks;
        if (done < 0) {
            // The last change hasn't started yet. Moving the anchor again would push
            // it further into the future each time, and a rate change then pivots
            // the whole timeline around that distant point. Just change the rate
            // it will start with; "now" is under a period from the anchor, so the
            // difference is far too small to matter.
            seq_.fetch_add(1, std::memory_order_acq_rel);
            ticksPerPeriod_.store(nominalTicksPerPeriod_ / (1.0 + ppm * 1e-6));
            seq_.fetch_add(1, std::memory_order_acq_rel);
            ppm_ = ppm;
            return;
        }
        const auto next = UInt64(done) + 1;

        seq_.fetch_add(1, std::memory_order_acq_rel);
        anchorHost_.store(UInt64(double(oldAnchor) + double(next) * oldTicks));
        anchorPeriod_.store(oldPeriod + next);
        // A faster device means fewer host ticks per period.
        ticksPerPeriod_.store(nominalTicksPerPeriod_ / (1.0 + ppm * 1e-6));
        seq_.fetch_add(1, std::memory_order_acq_rel);
        ppm_ = ppm;
    }

    double ratePpm() const
    {
        std::lock_guard lock(writer_);
        return ppm_;
    }

private:
    double hostPerSecond_ = 0;
    double nominalTicksPerPeriod_ = 0;
    std::atomic<UInt32> seq_{0};
    std::atomic<UInt64> anchorHost_{0};
    std::atomic<UInt64> anchorPeriod_{0};
    std::atomic<double> ticksPerPeriod_{0};
    mutable std::mutex writer_;
    double ppm_ = 0;
};

SharedClock &sharedClock()
{
    static SharedClock clock;
    return clock;
}

// Stereo rings addressed by sample time, one set each way.
struct Rings
{
    std::array<std::array<float, kRingFrames * 2>, kSlots> toEngine{};
    std::array<std::array<float, kRingFrames * 2>, kSlots> fromEngine{};
};

Rings &rings()
{
    static auto *r = new Rings(); // static storage is zeroed; never freed
    return *r;
}

inline UInt32 ringIndex(Float64 sampleTime)
{
    return UInt32(SInt64(sampleTime)) & (kRingFrames - 1);
}

class SpikeDevice final : public aspl::Device
{
public:
    using aspl::Device::Device;

protected:
    OSStatus GetZeroTimeStampImpl(UInt32, Float64 *outSampleTime, UInt64 *outHostTime,
        UInt64 *outSeed) override
    {
        sharedClock().zeroTimeStamp(outSampleTime, outHostTime);
        *outSeed = 1;
        return kAudioHardwareNoError;
    }
};

// A visible device on one slot.
class SlotHandler final : public aspl::IORequestHandler
{
public:
    explicit SlotHandler(UInt32 slot)
        : slot_(slot)
    {
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream> &, Float64, Float64 timestamp,
        const void *bytes, UInt32 bytesCount) override
    {
        auto &ring = rings().toEngine[slot_];
        const auto *in = static_cast<const float *>(bytes);
        const UInt32 frames = bytesCount / (2 * sizeof(float));
        UInt32 at = ringIndex(timestamp);
        for (UInt32 f = 0; f < frames; ++f) {
            ring[at * 2] = in[f * 2];
            ring[at * 2 + 1] = in[f * 2 + 1];
            at = (at + 1) & (kRingFrames - 1);
        }
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client> &,
        const std::shared_ptr<aspl::Stream> &, Float64, Float64 timestamp, void *bytes,
        UInt32 bytesCount) override
    {
        const auto &ring = rings().fromEngine[slot_];
        auto *out = static_cast<float *>(bytes);
        const UInt32 frames = bytesCount / (2 * sizeof(float));
        UInt32 at = ringIndex(timestamp);
        for (UInt32 f = 0; f < frames; ++f) {
            out[f * 2] = ring[at * 2];
            out[f * 2 + 1] = ring[at * 2 + 1];
            at = (at + 1) & (kRingFrames - 1);
        }
    }

private:
    UInt32 slot_;
};

// The hidden device: every slot, both ways.
class EngineHandler final : public aspl::IORequestHandler
{
public:
    void OnReadClientInput(const std::shared_ptr<aspl::Client> &,
        const std::shared_ptr<aspl::Stream> &, Float64, Float64 timestamp, void *bytes,
        UInt32 bytesCount) override
    {
        auto *out = static_cast<float *>(bytes);
        const UInt32 frames = bytesCount / (kEngineChannels * sizeof(float));
        UInt32 at = ringIndex(timestamp);
        for (UInt32 f = 0; f < frames; ++f) {
            for (UInt32 s = 0; s < kSlots; ++s) {
                auto &ring = rings().toEngine[s];
                *out++ = ring[at * 2];
                *out++ = ring[at * 2 + 1];
                // Single reader: clear behind it, so a slot nobody writes is silent.
                ring[at * 2] = 0;
                ring[at * 2 + 1] = 0;
            }
            at = (at + 1) & (kRingFrames - 1);
        }
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream> &, Float64, Float64 timestamp,
        const void *bytes, UInt32 bytesCount) override
    {
        const auto *in = static_cast<const float *>(bytes);
        const UInt32 frames = bytesCount / (kEngineChannels * sizeof(float));
        UInt32 at = ringIndex(timestamp);
        for (UInt32 f = 0; f < frames; ++f) {
            for (UInt32 s = 0; s < kSlots; ++s) {
                auto &ring = rings().fromEngine[s];
                ring[at * 2] = *in++;
                ring[at * 2 + 1] = *in++;
            }
            at = (at + 1) & (kRingFrames - 1);
        }
    }
};

AudioStreamBasicDescription floatFormat(UInt32 channels)
{
    AudioStreamBasicDescription f{};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        | kAudioFormatFlagIsPacked;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = channels;
    f.mBytesPerFrame = channels * sizeof(float);
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = f.mBytesPerFrame;
    return f;
}

aspl::DeviceParameters deviceParams(const std::string &name, const std::string &uid,
    UInt32 channels, bool canBeDefault = false)
{
    aspl::DeviceParameters p;
    p.Name = name;
    p.Manufacturer = "PatchPrimeMac spike";
    p.DeviceUID = uid;
    p.ModelUID = "PatchPrimeMacSpike";
    p.SampleRate = kSampleRate;
    p.ChannelCount = channels;
    p.ZeroTimeStampPeriod = kPeriodFrames;
    p.ClockDomain = kClockDomain;
    // Only a device added as "defout" may become the default, and only a test that
    // asks for it does that. The driver never makes itself the default.
    p.CanBeDefault = canBeDefault;
    p.CanBeDefaultForSystemSounds = false;
    return p;
}

class SpikePlugin
{
public:
    SpikePlugin()
        : context_(std::make_shared<aspl::Context>())
        , plugin_(std::make_shared<aspl::Plugin>(context_))
    {
        engine_ = std::make_shared<SpikeDevice>(context_,
            deviceParams("PatchPrimeMac Spike Engine", kEngineUID, kEngineChannels));
        aspl::StreamParameters in;
        in.Direction = aspl::Direction::Input;
        in.Format = floatFormat(kEngineChannels);
        aspl::StreamParameters out;
        out.Direction = aspl::Direction::Output;
        out.Format = floatFormat(kEngineChannels);
        engine_->AddStreamAsync(in);
        engine_->AddStreamAsync(out);
        engine_->SetIOHandler(std::make_shared<EngineHandler>());
        engine_->SetIsHidden(true);

        engine_->RegisterCustomProperty(kCommandProperty, *this, &SpikePlugin::lastResult,
            &SpikePlugin::command);
        engine_->RegisterCustomProperty(kRateProperty, *this, &SpikePlugin::rate,
            &SpikePlugin::setRate);

        plugin_->AddDevice(engine_);
        driver_ = std::make_shared<aspl::Driver>(context_, plugin_);
    }

    std::shared_ptr<aspl::Driver> driver() const { return driver_; }

private:
    // "add <slot> <out|defout|in> <name...>" or "remove <slot>"
    void command(CFStringRef value)
    {
        char buffer[256] = {};
        CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
        std::istringstream words{std::string(buffer)};
        std::string verb;
        UInt32 slot = kSlots;
        words >> verb >> slot;

        std::lock_guard lock(mutex_);
        if (slot >= kSlots) {
            result_ = "error: bad slot";
            return;
        }
        if (verb == "add") {
            std::string direction;
            words >> direction;
            std::string name;
            std::getline(words >> std::ws, name);
            const bool canBeDefault = direction == "defout";
            const bool output = direction == "out" || canBeDefault;
            if (devices_.count(slot) != 0 || name.empty()
                || (!output && direction != "in")) {
                result_ = "error: bad add";
                return;
            }
            auto device = std::make_shared<SpikeDevice>(context_,
                deviceParams(name, "PatchPrimeMacSpike.Slot" + std::to_string(slot), 2, canBeDefault));
            aspl::StreamParameters p;
            p.Direction = output ? aspl::Direction::Output : aspl::Direction::Input;
            p.Format = floatFormat(2);
            device->AddStreamAsync(p);
            device->SetIOHandler(std::make_shared<SlotHandler>(slot));
            plugin_->AddDevice(device);
            devices_[slot] = device;
            result_ = "ok";
        } else if (verb == "remove") {
            const auto it = devices_.find(slot);
            if (it == devices_.end()) {
                result_ = "error: no such slot";
                return;
            }
            plugin_->RemoveDevice(it->second);
            devices_.erase(it);
            result_ = "ok";
        } else {
            result_ = "error: bad command";
        }
    }

    CFStringRef lastResult() const
    {
        std::lock_guard lock(mutex_);
        return CFStringCreateWithCString(nullptr, result_.c_str(), kCFStringEncodingUTF8);
    }

    // The rate correction, as text in ppm. Set off the IO threads.
    void setRate(CFStringRef value)
    {
        sharedClock().setRatePpm(CFStringGetDoubleValue(value));
    }

    CFStringRef rate() const
    {
        const std::string text = std::to_string(sharedClock().ratePpm());
        return CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
    }

    std::shared_ptr<aspl::Context> context_;
    std::shared_ptr<aspl::Plugin> plugin_;
    std::shared_ptr<aspl::Driver> driver_;
    std::shared_ptr<SpikeDevice> engine_;
    std::map<UInt32, std::shared_ptr<SpikeDevice>> devices_;
    mutable std::mutex mutex_;
    std::string result_ = "ok";
};

} // namespace

extern "C" void *PatchPrimeMacSpikeEntry(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static auto *plugin = new SpikePlugin();
    return plugin->driver()->GetReference();
}
