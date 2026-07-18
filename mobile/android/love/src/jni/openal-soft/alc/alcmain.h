#ifndef ALC_MAIN_H
#define ALC_MAIN_H

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/alext.h"

#include "albyte.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "alspan.h"
#include "ambidefs.h"
#include "atomic.h"
#include "bufferline.h"
#include "devformat.h"
#include "filters/splitter.h"
#include "hrtf.h"
#include "inprogext.h"
#include "intrusive_ptr.h"
#include "vector.h"

class BFormatDec;
struct ALbuffer;
struct ALeffect;
struct ALfilter;
struct BackendBase;
struct Compressor;
struct EffectState;
struct Uhj2Encoder;
struct bs2b;


#define MIN_OUTPUT_RATE      8000
#define MAX_OUTPUT_RATE      192000
#define DEFAULT_OUTPUT_RATE  44100

#define DEFAULT_UPDATE_SIZE  882 /* 20ms */
#define DEFAULT_NUM_UPDATES  3


enum class DeviceType {
    Playback,
    Capture,
    Loopback
};


enum class RenderMode {
    Normal,
    Pairwise,
    Hrtf
};


struct InputRemixMap {
    struct TargetMix { Channel channel; float mix; };

    Channel channel;
    std::array<TargetMix,2> targets;
};


struct BufferSubList {
    uint64_t FreeMask{~0_u64};
    ALbuffer *Buffers{nullptr}; /* 64 */

    BufferSubList() noexcept = default;
    BufferSubList(const BufferSubList&) = delete;
    BufferSubList(BufferSubList&& rhs) noexcept : FreeMask{rhs.FreeMask}, Buffers{rhs.Buffers}
    { rhs.FreeMask = ~0_u64; rhs.Buffers = nullptr; }
    ~BufferSubList();

    BufferSubList& operator=(const BufferSubList&) = delete;
    BufferSubList& operator=(BufferSubList&& rhs) noexcept
    { std::swap(FreeMask, rhs.FreeMask); std::swap(Buffers, rhs.Buffers); return *this; }
};

struct EffectSubList {
    uint64_t FreeMask{~0_u64};
    ALeffect *Effects{nullptr}; /* 64 */

    EffectSubList() noexcept = default;
    EffectSubList(const EffectSubList&) = delete;
    EffectSubList(EffectSubList&& rhs) noexcept : FreeMask{rhs.FreeMask}, Effects{rhs.Effects}
    { rhs.FreeMask = ~0_u64; rhs.Effects = nullptr; }
    ~EffectSubList();

    EffectSubList& operator=(const EffectSubList&) = delete;
    EffectSubList& operator=(EffectSubList&& rhs) noexcept
    { std::swap(FreeMask, rhs.FreeMask); std::swap(Effects, rhs.Effects); return *this; }
};

struct FilterSubList {
    uint64_t FreeMask{~0_u64};
    ALfilter *Filters{nullptr}; /* 64 */

    FilterSubList() noexcept = default;
    FilterSubList(const FilterSubList&) = delete;
    FilterSubList(FilterSubList&& rhs) noexcept : FreeMask{rhs.FreeMask}, Filters{rhs.Filters}
    { rhs.FreeMask = ~0_u64; rhs.Filters = nullptr; }
    ~FilterSubList();

    FilterSubList& operator=(const FilterSubList&) = delete;
    FilterSubList& operator=(FilterSubList&& rhs) noexcept
    { std::swap(FreeMask, rhs.FreeMask); std::swap(Filters, rhs.Filters); return *this; }
};


/* Maximum delay in samples for speaker distance compensation. */
#define MAX_DELAY_LENGTH 1024

class DistanceComp {
public:
    struct DistData {
        float Gain{1.0f};
        ALuint Length{0u}; /* Valid range is [0...MAX_DELAY_LENGTH). */
        float *Buffer{nullptr};
    };

private:
    using FloatArray = al::FlexArray<float,16>;
    std::array<DistData,MAX_OUTPUT_CHANNELS> mChannels;
    std::unique_ptr<FloatArray> mSamples;

public:
    void setSampleCount(size_t new_size)
    { mSamples = FloatArray::Create(new_size); }
    void clear() noexcept
    {
        mChannels.fill(DistData{});
        mSamples = nullptr;
    }

    float *getSamples() noexcept { return mSamples->data(); }

    al::span<DistData,MAX_OUTPUT_CHANNELS> as_span() { return mChannels; }
};


struct BFChannelConfig {
    float Scale;
    ALuint Index;
};

/* Maximum number of samples to pad on the ends of a buffer for resampling.
 * Note that the padding is symmetric (half at the beginning and half at the
 * end)!
 */
#define MAX_RESAMPLER_PADDING 48


struct MixParams {
    /* Coefficient channel mapping for mixing to the buffer. */
    std::array<BFChannelConfig,MAX_OUTPUT_CHANNELS> AmbiMap{};

    al::span<FloatBufferLine> Buffer;
};

struct RealMixParams {
    al::span<const InputRemixMap> RemixMap;
    std::array<ALuint,MaxChannels> ChannelIndex{};

    al::span<FloatBufferLine> Buffer;
};

enum {
    // Frequency was requested by the app or config file
    FrequencyRequest,
    // Channel configuration was requested by the config file
    ChannelsRequest,
    // Sample type was requested by the config file
    SampleTypeRequest,

    // Specifies if the DSP is paused at user request
    DevicePaused,
    // Specifies if the device is currently running
    DeviceRunning,

    DeviceFlagsCount
};

struct ALCdevice : public al::intrusive_ref<ALCdevice> {
    std::atomic<bool> Connected{true};
    const DeviceType Type{};

    ALuint Frequency{};
    ALuint UpdateSize{};
    ALuint BufferSize{};

    DevFmtChannels FmtChans{};
    DevFmtType FmtType{};
    bool IsHeadphones{false};
    ALuint mAmbiOrder{0};
    /* For DevFmtAmbi* output only, specifies the channel order and
     * normalization.
     */
    DevAmbiLayout mAmbiLayout{DevAmbiLayout::Default};
    DevAmbiScaling mAmbiScale{DevAmbiScaling::Default};

    ALCenum LimiterState{ALC_DONT_CARE_SOFT};

    std::string DeviceName;

    // Device flags
    al::bitfield<DeviceFlagsCount> Flags{};

    std::string HrtfName;
    al::vector<std::string> HrtfList;
    ALCenum HrtfStatus{ALC_FALSE};

    std::atomic<ALCenum> LastError{ALC_NO_ERROR};

    // Maximum number of sources that can be created
    ALuint SourcesMax{};
    // Maximum number of slots that can be created
    ALuint AuxiliaryEffectSlotMax{};

    ALCuint NumMonoSources{};
    ALCuint NumStereoSources{};
    ALCuint NumAuxSends{};

    // Map of Buffers for this device
    std::mutex BufferLock;
    al::vector<BufferSubList> BufferList;

    // Map of Effects for this device
    std::mutex EffectLock;
    al::vector<EffectSubList> EffectList;

    // Map of Filters for this device
    std::mutex FilterLock;
    al::vector<FilterSubList> FilterList;

    /* Rendering mode. */
    RenderMode mRenderMode{RenderMode::Normal};

    /* The average speaker distance as determined by the ambdec configuration,
     * HRTF data set, or the NFC-HOA reference delay. Only used for NFC.
     */
    float AvgSpeakerDist{0.0f};

    ALuint SamplesDone{0u};
    std::chrono::nanoseconds ClockBase{0};
    std::chrono::nanoseconds FixedLatency{0};

    /* Temp storage used for mixer processing. */
    alignas(16) float SourceData[BUFFERSIZE + MAX_RESAMPLER_PADDING];
    alignas(16) float ResampledData[BUFFERSIZE];
    alignas(16) float FilteredData[BUFFERSIZE];
    union {
        alignas(16) float HrtfSourceData[BUFFERSIZE + HRTF_HISTORY_LENGTH];
        alignas(16) float NfcSampleData[BUFFERSIZE];
    };

    /* Persistent storage for HRTF mixing. */
    alignas(16) float2 HrtfAccumData[BUFFERSIZE + HRIR_LENGTH + HRTF_DIRECT_DELAY];

    /* Mixing buffer used by the Dry mix and Real output. */
    al::vector<FloatBufferLine, 16> MixBuffer;

    /* The "dry" path corresponds to the main output. */
    MixParams Dry;
    ALuint NumChannelsPerOrder[MAX_AMBI_ORDER+1]{};

    /* "Real" output, which will be written to the device buffer. May alias the
     * dry buffer.
     */
    RealMixParams RealOut;

    /* HRTF state and info */
    std::unique_ptr<DirectHrtfState> mHrtfState;
    al::intrusive_ptr<HrtfStore> mHrtf;

    /* Ambisonic-to-UHJ encoder */
    std::unique_ptr<Uhj2Encoder> Uhj_Encoder;

    /* Ambisonic decoder for speakers */
    std::unique_ptr<BFormatDec> AmbiDecoder;

    /* Stereo-to-binaural filter */
    std::unique_ptr<bs2b> Bs2b;

    using PostProc = void(ALCdevice::*)(const size_t SamplesToDo);
    PostProc PostProcess{nullptr};

    std::unique_ptr<Compressor> Limiter;

    /* Delay buffers used to compensate for speaker distances. */
    DistanceComp ChannelDelay;

    /* Dithering control. */
    float DitherDepth{0.0f};
    ALuint DitherSeed{0u};

    /* Running count of the mixer invocations, in 31.1 fixed point. This
     * actually increments *twice* when mixing, first at the start and then at
     * the end, so the bottom bit indicates if the device is currently mixing
     * and the upper bits indicates how many mixes have been done.
     */
    RefCount MixCount{0u};

    // Contexts created on this device
    std::atomic<al::FlexArray<ALCcontext*>*> mContexts{nullptr};

    /* This lock protects the device state (format, update size, etc) from
     * being from being changed in multiple threads, or being accessed while
     * being changed. It's also used to serialize calls to the backend.
     */
    std::mutex StateLock;
    std::unique_ptr<BackendBase> Backend;


    ALCdevice(DeviceType type);
    ALCdevice(const ALCdevice&) = delete;
    ALCdevice& operator=(const ALCdevice&) = delete;
    ~ALCdevice();

    ALuint bytesFromFmt() const noexcept { return BytesFromDevFmt(FmtType); }
    ALuint channelsFromFmt() const noexcept { return ChannelsFromDevFmt(FmtChans, mAmbiOrder); }
    ALuint frameSizeFromFmt() const noexcept { return bytesFromFmt() * channelsFromFmt(); }

    ALuint waitForMix() const noexcept
    {
        ALuint refcount;
        while((refcount=MixCount.load(std::memory_order_acquire))&1) {
        }
        return refcount;
    }

    void ProcessHrtf(const size_t SamplesToDo);
    void ProcessAmbiDec(const size_t SamplesToDo);
    void ProcessAmbiDecStablized(const size_t SamplesToDo);
    void ProcessUhj(const size_t SamplesToDo);
    void ProcessBs2b(const size_t SamplesToDo);

    inline void postProcess(const size_t SamplesToDo)
    { if LIKELY(PostProcess) (this->*PostProcess)(SamplesToDo); }

    void renderSamples(void *outBuffer, const ALuint numSamples, const size_t frameStep);

    /* Caller must lock the device state, and the mixer must not be running. */
    [[gnu::format(printf,2,3)]] void handleDisconnect(const char *msg, ...);

    DEF_NEWDEL(ALCdevice)
};

/* Must be less than 15 characters (16 including terminating null) for
 * compatibility with pthread_setname_np limitations. */
#define MIXER_THREAD_NAME "alsoft-mixer"

#define RECORD_THREAD_NAME "alsoft-record"


extern int RTPrioLevel;
void SetRTPriority(void);

const ALCchar *DevFmtTypeString(DevFmtType type) noexcept;
const ALCchar *DevFmtChannelsString(DevFmtChannels chans) noexcept;

/**
 * Returns the index for the given channel name (e.g. FrontCenter), or
 * INVALID_CHANNEL_INDEX if it doesn't exist.
 */
inline ALuint GetChannelIdxByName(const RealMixParams &real, Channel chan) noexcept
{ return real.ChannelIndex[chan]; }
#define INVALID_CHANNEL_INDEX ~0u


al::vector<std::string> SearchDataFiles(const char *match, const char *subdir);

#endif
