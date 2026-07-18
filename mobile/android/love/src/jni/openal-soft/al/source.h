#ifndef AL_SOURCE_H
#define AL_SOURCE_H

#include <array>
#include <atomic>
#include <cstddef>
#include <iterator>
#include <limits>

#include "AL/al.h"
#include "AL/alc.h"

#include "alcontext.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "alu.h"
#include "math_defs.h"
#include "vector.h"

struct ALbuffer;
struct ALeffectslot;


#define DEFAULT_SENDS  2

#define INVALID_VOICE_IDX static_cast<ALuint>(-1)

struct ALbufferlistitem {
    std::atomic<ALbufferlistitem*> mNext{nullptr};
    ALuint mSampleLen{0u};
    ALbuffer *mBuffer{nullptr};

    DEF_NEWDEL(ALbufferlistitem)
};


struct ALsource {
    /** Source properties. */
    float Pitch{1.0f};
    float Gain{1.0f};
    float OuterGain{0.0f};
    float MinGain{0.0f};
    float MaxGain{1.0f};
    float InnerAngle{360.0f};
    float OuterAngle{360.0f};
    float RefDistance{1.0f};
    float MaxDistance{std::numeric_limits<float>::max()};
    float RolloffFactor{1.0f};
    std::array<float,3> Position{{0.0f, 0.0f, 0.0f}};
    std::array<float,3> Velocity{{0.0f, 0.0f, 0.0f}};
    std::array<float,3> Direction{{0.0f, 0.0f, 0.0f}};
    std::array<float,3> OrientAt{{0.0f, 0.0f, -1.0f}};
    std::array<float,3> OrientUp{{0.0f, 1.0f,  0.0f}};
    bool HeadRelative{false};
    bool Looping{false};
    DistanceModel mDistanceModel{DistanceModel::Default};
    Resampler mResampler{ResamplerDefault};
    DirectMode DirectChannels{DirectMode::Off};
    SpatializeMode mSpatialize{SpatializeMode::Auto};

    bool DryGainHFAuto{true};
    bool WetGainAuto{true};
    bool WetGainHFAuto{true};
    float OuterGainHF{1.0f};

    float AirAbsorptionFactor{0.0f};
    float RoomRolloffFactor{0.0f};
    float DopplerFactor{1.0f};

    /* NOTE: Stereo pan angles are specified in radians, counter-clockwise
     * rather than clockwise.
     */
    std::array<float,2> StereoPan{{Deg2Rad( 30.0f), Deg2Rad(-30.0f)}};

    float Radius{0.0f};

    /** Direct filter and auxiliary send info. */
    struct {
        float Gain;
        float GainHF;
        float HFReference;
        float GainLF;
        float LFReference;
    } Direct;
    struct SendData {
        ALeffectslot *Slot;
        float Gain;
        float GainHF;
        float HFReference;
        float GainLF;
        float LFReference;
    };
    std::array<SendData,MAX_SENDS> Send;

    /**
     * Last user-specified offset, and the offset type (bytes, samples, or
     * seconds).
     */
    double Offset{0.0};
    ALenum OffsetType{AL_NONE};

    /** Source type (static, streaming, or undetermined) */
    ALenum SourceType{AL_UNDETERMINED};

    /** Source state (initial, playing, paused, or stopped) */
    ALenum state{AL_INITIAL};

    /** Source Buffer Queue head. */
    ALbufferlistitem *queue{nullptr};

    std::atomic_flag PropsClean;

    /* Index into the context's Voices array. Lazily updated, only checked and
     * reset when looking up the voice.
     */
    ALuint VoiceIdx{INVALID_VOICE_IDX};

    /** Self ID */
    ALuint id{0};


    ALsource();
    ~ALsource();

    ALsource(const ALsource&) = delete;
    ALsource& operator=(const ALsource&) = delete;

    DISABLE_ALLOC()
};

void UpdateAllSourceProps(ALCcontext *context);

#endif
