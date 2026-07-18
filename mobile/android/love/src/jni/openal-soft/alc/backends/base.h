#ifndef ALC_BACKENDS_BASE_H
#define ALC_BACKENDS_BASE_H

#include <chrono>
#include <memory>
#include <mutex>
#include <string>

#include "AL/alc.h"

#include "albyte.h"
#include "alcmain.h"
#include "alexcpt.h"


struct ClockLatency {
    std::chrono::nanoseconds ClockTime;
    std::chrono::nanoseconds Latency;
};

struct BackendBase {
    virtual void open(const ALCchar *name) = 0;

    virtual bool reset();
    virtual void start() = 0;
    virtual void stop() = 0;

    virtual ALCenum captureSamples(al::byte *buffer, ALCuint samples);
    virtual ALCuint availableSamples();

    virtual ClockLatency getClockLatency();

    ALCdevice *const mDevice;

    BackendBase(ALCdevice *device) noexcept : mDevice{device} { }
    virtual ~BackendBase() = default;

protected:
    /** Sets the default channel order used by most non-WaveFormatEx-based APIs. */
    void setDefaultChannelOrder();
    /** Sets the default channel order used by WaveFormatEx. */
    void setDefaultWFXChannelOrder();

#ifdef _WIN32
    /** Sets the channel order given the WaveFormatEx mask. */
    void setChannelOrderFromWFXMask(ALuint chanmask);
#endif
};
using BackendPtr = std::unique_ptr<BackendBase>;

enum class BackendType {
    Playback,
    Capture
};


/* Helper to get the current clock time from the device's ClockBase, and
 * SamplesDone converted from the sample rate.
 */
inline std::chrono::nanoseconds GetDeviceClockTime(ALCdevice *device)
{
    using std::chrono::seconds;
    using std::chrono::nanoseconds;

    auto ns = nanoseconds{seconds{device->SamplesDone}} / device->Frequency;
    return device->ClockBase + ns;
}

/* Helper to get the device latency from the backend, including any fixed
 * latency from post-processing.
 */
inline ClockLatency GetClockLatency(ALCdevice *device)
{
    BackendBase *backend{device->Backend.get()};
    ClockLatency ret{backend->getClockLatency()};
    ret.Latency += device->FixedLatency;
    return ret;
}


struct BackendFactory {
    virtual bool init() = 0;

    virtual bool querySupport(BackendType type) = 0;

    virtual std::string probe(BackendType type) = 0;

    virtual BackendPtr createBackend(ALCdevice *device, BackendType type) = 0;

protected:
    virtual ~BackendFactory() = default;
};

namespace al {

class backend_exception final : public base_exception {
public:
    [[gnu::format(printf, 3, 4)]]
    backend_exception(ALCenum code, const char *msg, ...) : base_exception{code}
    {
        std::va_list args;
        va_start(args, msg);
        setMessage(msg, args);
        va_end(args);
    }
};

} // namespace al

#endif /* ALC_BACKENDS_BASE_H */
