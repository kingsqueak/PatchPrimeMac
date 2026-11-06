// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The PatchPrimeMac virtual audio driver. Keep it small: it runs inside the system's
// audio service, so a crash here hurts all audio on the Mac. No DSP belongs here.
//
// One hidden engine device, plus up to 16 named stereo devices that people see.
// Slot N is channels 2N and 2N+1 of the engine device. A visible output device
// ("apps play here") feeds the engine. The engine feeds a visible input device
// ("apps record here"). All share one clock, which the engine can steer towards a
// chosen hardware device.
//
// Audio is addressed by sample time. Anything not freshly written reads as silence,
// so if the engine stops, a virtual mic goes quiet instead of replaying old audio.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
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
constexpr UInt32 kRingFrames = 65536; // a power of two and a multiple of the period
constexpr UInt32 kClockDomain = 0x50504D43; // every device reports this
constexpr AudioObjectPropertySelector kCommandProperty = 'ppcm';
constexpr AudioObjectPropertySelector kRateProperty = 'pprt';
constexpr AudioObjectPropertySelector kListProperty = 'ppls';
const char *const kEngineUID = "PatchPrimeMac.Engine";
const char *const kStorageKey = "devices";

// One timeline for every device. Rebased when the rate changes, so it stays
// continuous. Readers use a seqlock: several IO threads call this at once.
class SharedClock
{
public:
    SharedClock()
    {
        mach_timebase_info_data_t tb{};
        mach_timebase_info(&tb);
        const double hostPerSecond = 1e9 * double(tb.denom) / double(tb.numer);
        nominalTicksPerPeriod_ = hostPerSecond * kPeriodFrames / kSampleRate;
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
        const SInt64 stepped = elapsed < 0 ? periods - 1 : periods;
        *sampleTime = double(SInt64(anchorPeriod) + stepped) * kPeriodFrames;
        *hostTime = UInt64(double(anchorHost) + double(stepped) * ticks);
    }

    // Off the IO threads only. The next period starts at the new rate.
    void setRatePpm(double ppm)
    {
        std::lock_guard lock(writer_);
        const double oldTicks = ticksPerPeriod_.load();
        const UInt64 oldAnchor = anchorHost_.load();
        const UInt64 oldPeriod = anchorPeriod_.load();
        const double done = (double(mach_absolute_time()) - double(oldAnchor)) / oldTicks;
        seq_.fetch_add(1, std::memory_order_acq_rel);
        if (done >= 0) {
            // If `done` is negative the last change hasn't started. Moving the anchor
            // again would push it ever further ahead, and a rate change would then
            // pivot the whole timeline around that distant point.
            const auto next = UInt64(done) + 1;
            anchorHost_.store(UInt64(double(oldAnchor) + double(next) * oldTicks));
            anchorPeriod_.store(oldPeriod + next);
        }
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

struct Rings
{
    std::array<std::array<float, kRingFrames * 2>, kSlots> toEngine{};
    std::array<std::array<float, kRingFrames * 2>, kSlots> fromEngine{};
    std::array<std::atomic<Float64>, kSlots> toEngineEnd{}; // end of fresh audio
    std::atomic<Float64> fromEngineEnd{0};
};

Rings &rings()
{
    static auto *r = new Rings();
    return *r;
}

inline UInt32 ringIndex(Float64 sampleTime)
{
    return UInt32(SInt64(sampleTime)) & (kRingFrames - 1);
}

class VirtualDevice final : public aspl::Device
{
public:
    VirtualDevice(std::shared_ptr<const aspl::Context> context, const aspl::DeviceParameters &params)
        : aspl::Device(std::move(context), params)
        , name_(params.Name)
    {
    }

    std::string GetName() const override
    {
        std::lock_guard lock(nameMutex_);
        return name_;
    }

    void rename(const std::string &name)
    {
        {
            std::lock_guard lock(nameMutex_);
            name_ = name;
        }
        NotifyPropertyChanged(kAudioObjectPropertyName);
    }

protected:
    OSStatus GetZeroTimeStampImpl(UInt32, Float64 *outSampleTime, UInt64 *outHostTime,
        UInt64 *outSeed) override
    {
        sharedClock().zeroTimeStamp(outSampleTime, outHostTime);
        *outSeed = 1;
        return kAudioHardwareNoError;
    }

private:
    mutable std::mutex nameMutex_;
    std::string name_;
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
        rings().toEngineEnd[slot_].store(timestamp + frames, std::memory_order_release);
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client> &,
        const std::shared_ptr<aspl::Stream> &, Float64, Float64 timestamp, void *bytes,
        UInt32 bytesCount) override
    {
        const auto &ring = rings().fromEngine[slot_];
        auto *out = static_cast<float *>(bytes);
        const UInt32 frames = bytesCount / (2 * sizeof(float));
        const Float64 end = rings().fromEngineEnd.load(std::memory_order_acquire);
        UInt32 at = ringIndex(timestamp);
        for (UInt32 f = 0; f < frames; ++f) {
            const bool fresh = timestamp + f < end;
            out[f * 2] = fresh ? ring[at * 2] : 0;
            out[f * 2 + 1] = fresh ? ring[at * 2 + 1] : 0;
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
        for (UInt32 s = 0; s < kSlots; ++s) {
            auto &ring = rings().toEngine[s];
            const Float64 end = rings().toEngineEnd[s].load(std::memory_order_acquire);
            UInt32 at = ringIndex(timestamp);
            for (UInt32 f = 0; f < frames; ++f) {
                const bool fresh = timestamp + f < end;
                out[size_t(f) * kEngineChannels + s * 2] = fresh ? ring[at * 2] : 0;
                out[size_t(f) * kEngineChannels + s * 2 + 1] = fresh ? ring[at * 2 + 1] : 0;
                ring[at * 2] = 0; // single reader: clear behind it
                ring[at * 2 + 1] = 0;
                at = (at + 1) & (kRingFrames - 1);
            }
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
        rings().fromEngineEnd.store(timestamp + frames, std::memory_order_release);
    }
};

AudioStreamBasicDescription floatFormat(UInt32 channels)
{
    AudioStreamBasicDescription f{};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = UInt32(kAudioFormatFlagIsFloat) | UInt32(kAudioFormatFlagsNativeEndian)
        | UInt32(kAudioFormatFlagIsPacked);
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = channels;
    f.mBytesPerFrame = channels * sizeof(float);
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = f.mBytesPerFrame;
    return f;
}

aspl::DeviceParameters deviceParams(const std::string &name, const std::string &uid,
    UInt32 channels, bool canBeDefault, bool systemSounds)
{
    aspl::DeviceParameters p;
    p.Name = name;
    p.Manufacturer = "PatchPrimeMac";
    p.DeviceUID = uid;
    p.ModelUID = "PatchPrimeMac";
    p.SampleRate = kSampleRate;
    p.ChannelCount = channels;
    p.ZeroTimeStampPeriod = kPeriodFrames;
    p.ClockDomain = kClockDomain;
    p.CanBeDefault = canBeDefault;
    p.CanBeDefaultForSystemSounds = systemSounds;
    return p;
}

struct Entry
{
    bool output = false;
    std::string name;
    std::shared_ptr<VirtualDevice> device;
};

class Plugin final : public aspl::DriverRequestHandler
{
public:
    Plugin()
        : context_(std::make_shared<aspl::Context>())
        , plugin_(std::make_shared<aspl::Plugin>(context_))
    {
        engine_ = std::make_shared<VirtualDevice>(context_,
            deviceParams("PatchPrimeMac Engine", kEngineUID, kEngineChannels, false, false));
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
        engine_->RegisterCustomProperty(kCommandProperty, *this, &Plugin::lastResult, &Plugin::command);
        engine_->RegisterCustomProperty(kRateProperty, *this, &Plugin::rate, &Plugin::setRate);
        engine_->RegisterCustomProperty(kListProperty, *this, &Plugin::list);
        plugin_->AddDevice(engine_);
        driver_ = std::make_shared<aspl::Driver>(context_, plugin_);
        driver_->SetDriverHandler(this);
    }

    std::shared_ptr<aspl::Driver> driver() const { return driver_; }

    OSStatus OnInitialize() override
    {
        const auto [text, found] = driver_->GetStorage()->ReadString(kStorageKey);
        if (found) {
            std::lock_guard lock(mutex_);
            std::istringstream lines(text);
            std::string line;
            while (std::getline(lines, line)) {
                const auto a = line.find('\t');
                const auto b = line.find('\t', a + 1);
                if (a == std::string::npos || b == std::string::npos) {
                    continue;
                }
                addDevice(UInt32(std::stoul(line.substr(0, a))),
                    line.substr(a + 1, b - a - 1) == "out", line.substr(b + 1));
            }
        }
        return kAudioHardwareNoError;
    }

private:
    bool addDevice(UInt32 slot, bool output, const std::string &name)
    {
        if (slot >= kSlots || entries_.count(slot) != 0 || name.empty()) {
            return false;
        }
        auto device = std::make_shared<VirtualDevice>(context_,
            deviceParams(name, "PatchPrimeMac.Device." + std::to_string(slot), 2, true, output));
        aspl::StreamParameters p;
        p.Direction = output ? aspl::Direction::Output : aspl::Direction::Input;
        p.Format = floatFormat(2);
        device->AddStreamAsync(p);
        device->SetIOHandler(std::make_shared<SlotHandler>(slot));
        plugin_->AddDevice(device);
        entries_[slot] = Entry{output, name, device};
        return true;
    }

    // Never write storage from a property call. That call is the system audio service
    // waiting on this process, and storage is a call back into the same service, so
    // doing it inline deadlocks both, and with them all audio on the Mac.
    void save()
    {
        auto storage = driver_->GetStorage();
        const std::string text = listText();
        dispatch_async(saveQueue_, ^{
            if (text.empty()) {
                storage->Delete(kStorageKey);
            } else {
                storage->WriteString(kStorageKey, text);
            }
        });
    }

    std::string listText() const
    {
        std::string text;
        for (const auto &[slot, entry] : entries_) {
            text += std::to_string(slot) + "\t" + (entry.output ? "out" : "in") + "\t" + entry.name + "\n";
        }
        return text;
    }

    static std::string clean(std::string name)
    {
        for (char &c : name) {
            if (c == '\t' || c == '\n' || c == '\r') {
                c = ' ';
            }
        }
        return name;
    }

    // "add <slot> <out|in> <name>", "remove <slot>", "rename <slot> <name>", "reset"
    void command(CFStringRef value)
    {
        char buffer[512] = {};
        CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
        std::istringstream words{std::string(buffer)};
        std::string verb;
        words >> verb;
        std::lock_guard lock(mutex_);
        result_ = "ok";
        if (verb == "reset") {
            for (auto &[slot, entry] : entries_) {
                plugin_->RemoveDevice(entry.device);
            }
            entries_.clear();
            save();
            return;
        }
        UInt32 slot = kSlots;
        words >> slot;
        const auto it = entries_.find(slot);
        if (verb == "add") {
            std::string direction, name;
            words >> direction;
            std::getline(words >> std::ws, name);
            if ((direction != "out" && direction != "in")
                || !addDevice(slot, direction == "out", clean(name))) {
                result_ = "error: can't add that device";
                return;
            }
            save();
        } else if (verb == "remove") {
            if (it == entries_.end()) {
                result_ = "error: no such device";
                return;
            }
            plugin_->RemoveDevice(it->second.device);
            entries_.erase(it);
            save();
        } else if (verb == "rename") {
            std::string name;
            std::getline(words >> std::ws, name);
            if (it == entries_.end() || clean(name).empty()) {
                result_ = "error: can't rename that device";
                return;
            }
            it->second.name = clean(name);
            it->second.device->rename(it->second.name);
            save();
        } else {
            result_ = "error: unknown command";
        }
    }

    CFStringRef lastResult() const
    {
        std::lock_guard lock(mutex_);
        return CFStringCreateWithCString(nullptr, result_.c_str(), kCFStringEncodingUTF8);
    }

    CFStringRef list() const
    {
        std::lock_guard lock(mutex_);
        return CFStringCreateWithCString(nullptr, listText().c_str(), kCFStringEncodingUTF8);
    }

    void setRate(CFStringRef value) { sharedClock().setRatePpm(CFStringGetDoubleValue(value)); }

    CFStringRef rate() const
    {
        const std::string text = std::to_string(sharedClock().ratePpm());
        return CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8);
    }

    std::shared_ptr<aspl::Context> context_;
    std::shared_ptr<aspl::Plugin> plugin_;
    std::shared_ptr<aspl::Driver> driver_;
    std::shared_ptr<VirtualDevice> engine_;
    std::map<UInt32, Entry> entries_;
    mutable std::mutex mutex_;
    std::string result_ = "ok";
    dispatch_queue_t saveQueue_ = dispatch_queue_create("com.kingsqueak.patchprimemac.save", nullptr);
};

} // namespace

extern "C" void *PatchPrimeMacEntry(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static auto *plugin = new Plugin();
    return plugin->driver()->GetReference();
}
