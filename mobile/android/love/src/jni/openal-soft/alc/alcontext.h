#ifndef ALCONTEXT_H
#define ALCONTEXT_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"

#include "al/listener.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "alu.h"
#include "atomic.h"
#include "inprogext.h"
#include "intrusive_ptr.h"
#include "threads.h"
#include "vector.h"
#include "voice.h"

struct ALeffectslot;
struct ALeffectslotProps;
struct ALsource;
struct RingBuffer;


enum class DistanceModel {
    InverseClamped  = AL_INVERSE_DISTANCE_CLAMPED,
    LinearClamped   = AL_LINEAR_DISTANCE_CLAMPED,
    ExponentClamped = AL_EXPONENT_DISTANCE_CLAMPED,
    Inverse  = AL_INVERSE_DISTANCE,
    Linear   = AL_LINEAR_DISTANCE,
    Exponent = AL_EXPONENT_DISTANCE,
    Disable  = AL_NONE,

    Default = InverseClamped
};


struct WetBuffer {
    bool mInUse;
    al::FlexArray<FloatBufferLine, 16> mBuffer;

    WetBuffer(size_t count) : mBuffer{count} { }

    DEF_FAM_NEWDEL(WetBuffer, mBuffer)
};
using WetBufferPtr = std::unique_ptr<WetBuffer>;


struct ALcontextProps {
    float DopplerFactor;
    float DopplerVelocity;
    float SpeedOfSound;
    bool SourceDistanceModel;
    DistanceModel mDistanceModel;

    std::atomic<ALcontextProps*> next;

    DEF_NEWDEL(ALcontextProps)
};


struct VoiceChange {
    Voice *mOldVoice{nullptr};
    Voice *mVoice{nullptr};
    ALuint mSourceID{0};
    ALenum mState{0};

    std::atomic<VoiceChange*> mNext{nullptr};

    DEF_NEWDEL(VoiceChange)
};


struct SourceSubList {
    uint64_t FreeMask{~0_u64};
    ALsource *Sources{nullptr}; /* 64 */

    SourceSubList() noexcept = default;
    SourceSubList(const SourceSubList&) = delete;
    SourceSubList(SourceSubList&& rhs) noexcept : FreeMask{rhs.FreeMask}, Sources{rhs.Sources}
    { rhs.FreeMask = ~0_u64; rhs.Sources = nullptr; }
    ~SourceSubList();

    SourceSubList& operator=(const SourceSubList&) = delete;
    SourceSubList& operator=(SourceSubList&& rhs) noexcept
    { std::swap(FreeMask, rhs.FreeMask); std::swap(Sources, rhs.Sources); return *this; }
};

struct EffectSlotSubList {
    uint64_t FreeMask{~0_u64};
    ALeffectslot *EffectSlots{nullptr}; /* 64 */

    EffectSlotSubList() noexcept = default;
    EffectSlotSubList(const EffectSlotSubList&) = delete;
    EffectSlotSubList(EffectSlotSubList&& rhs) noexcept
      : FreeMask{rhs.FreeMask}, EffectSlots{rhs.EffectSlots}
    { rhs.FreeMask = ~0_u64; rhs.EffectSlots = nullptr; }
    ~EffectSlotSubList();

    EffectSlotSubList& operator=(const EffectSlotSubList&) = delete;
    EffectSlotSubList& operator=(EffectSlotSubList&& rhs) noexcept
    { std::swap(FreeMask, rhs.FreeMask); std::swap(EffectSlots, rhs.EffectSlots); return *this; }
};

struct ALCcontext : public al::intrusive_ref<ALCcontext> {
    al::vector<SourceSubList> mSourceList;
    ALuint mNumSources{0};
    std::mutex mSourceLock;

    al::vector<EffectSlotSubList> mEffectSlotList;
    ALuint mNumEffectSlots{0u};
    std::mutex mEffectSlotLock;

    std::atomic<ALenum> mLastError{AL_NO_ERROR};

    DistanceModel mDistanceModel{DistanceModel::Default};
    bool mSourceDistanceModel{false};

    float mDopplerFactor{1.0f};
    float mDopplerVelocity{1.0f};
    float mSpeedOfSound{SpeedOfSoundMetersPerSec};

    std::atomic_flag mPropsClean;
    std::atomic<bool> mDeferUpdates{false};

    std::mutex mPropLock;

    /* Counter for the pre-mixing updates, in 31.1 fixed point (lowest bit
     * indicates if updates are currently happening).
     */
    RefCount mUpdateCount{0u};
    std::atomic<bool> mHoldUpdates{false};

    float mGainBoost{1.0f};

    std::atomic<ALcontextProps*> mUpdate{nullptr};

    /* Linked lists of unused property containers, free to use for future
     * updates.
     */
    std::atomic<ALcontextProps*> mFreeContextProps{nullptr};
    std::atomic<ALlistenerProps*> mFreeListenerProps{nullptr};
    std::atomic<VoicePropsItem*> mFreeVoiceProps{nullptr};
    std::atomic<ALeffectslotProps*> mFreeEffectslotProps{nullptr};

    /* Asynchronous voice change actions are processed as a linked list of
     * VoiceChange objects by the mixer, which is atomically appended to.
     * However, to avoid allocating each object individually, they're allocated
     * in clusters that are stored in a vector for easy automatic cleanup.
     */
    using VoiceChangeCluster = std::unique_ptr<VoiceChange[]>;
    al::vector<VoiceChangeCluster> mVoiceChangeClusters;

    /* The voice change tail is the beginning of the "free" elements, up to and
     * *excluding* the current. If tail==current, there's no free elements and
     * new ones need to be allocated. The current voice change is the element
     * last processed, and any after are pending.
     */
    VoiceChange *mVoiceChangeTail{};
    std::atomic<VoiceChange*> mCurrentVoiceChange{};

    void allocVoiceChanges(size_t addcount);


    using VoiceCluster = std::unique_ptr<Voice[]>;
    al::vector<VoiceCluster> mVoiceClusters;

    using VoiceArray = al::FlexArray<Voice*>;
    std::atomic<VoiceArray*> mVoices{};
    std::atomic<size_t> mActiveVoiceCount{};

    void allocVoices(size_t addcount);
    al::span<Voice*> getVoicesSpan() const noexcept
    {
        return {mVoices.load(std::memory_order_relaxed)->data(),
            mActiveVoiceCount.load(std::memory_order_relaxed)};
    }
    al::span<Voice*> getVoicesSpanAcquired() const noexcept
    {
        return {mVoices.load(std::memory_order_acquire)->data(),
            mActiveVoiceCount.load(std::memory_order_acquire)};
    }


    /* Wet buffers used by effect slots. */
    al::vector<WetBufferPtr> mWetBuffers;

    using ALeffectslotArray = al::FlexArray<ALeffectslot*>;
    std::atomic<ALeffectslotArray*> mActiveAuxSlots{nullptr};

    std::thread mEventThread;
    al::semaphore mEventSem;
    std::unique_ptr<RingBuffer> mAsyncEvents;
    std::atomic<ALbitfieldSOFT> mEnabledEvts{0u};
    std::mutex mEventCbLock;
    ALEVENTPROCSOFT mEventCb{};
    void *mEventParam{nullptr};

    /* Default effect slot */
    std::unique_ptr<ALeffectslot> mDefaultSlot;

    const al::intrusive_ptr<ALCdevice> mDevice;
    const char *mExtensionList{nullptr};

    ALlistener mListener{};


    ALCcontext(al::intrusive_ptr<ALCdevice> device);
    ALCcontext(const ALCcontext&) = delete;
    ALCcontext& operator=(const ALCcontext&) = delete;
    ~ALCcontext();

    void init();
    /**
     * Removes the context from its device and removes it from being current on
     * the running thread or globally. Returns true if other contexts still
     * exist on the device.
     */
    bool deinit();

    /**
     * Defers/suspends updates for the given context's listener and sources.
     * This does *NOT* stop mixing, but rather prevents certain property
     * changes from taking effect.
     */
    void deferUpdates() noexcept { mDeferUpdates.exchange(true, std::memory_order_acq_rel); }

    /** Resumes update processing after being deferred. */
    void processUpdates();

    [[gnu::format(printf,3,4)]] void setError(ALenum errorCode, const char *msg, ...);

    DEF_NEWDEL(ALCcontext)
};

#define SETERR_RETURN(ctx, err, retval, ...) do {                             \
    (ctx)->setError((err), __VA_ARGS__);                                      \
    return retval;                                                            \
} while(0)


using ContextRef = al::intrusive_ptr<ALCcontext>;

ContextRef GetContextRef(void);

void UpdateContextProps(ALCcontext *context);


extern bool TrapALError;

#endif /* ALCONTEXT_H */
