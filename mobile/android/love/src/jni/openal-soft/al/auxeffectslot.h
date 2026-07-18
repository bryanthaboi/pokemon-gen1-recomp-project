#ifndef AL_AUXEFFECTSLOT_H
#define AL_AUXEFFECTSLOT_H

#include <atomic>
#include <cstddef>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/efx.h"

#include "alcmain.h"
#include "almalloc.h"
#include "atomic.h"
#include "effects/base.h"
#include "intrusive_ptr.h"
#include "vector.h"

struct ALbuffer;
struct ALeffect;
struct ALeffectslot;
struct WetBuffer;


using ALeffectslotArray = al::FlexArray<ALeffectslot*>;


struct ALeffectslotProps {
    float Gain;
    bool  AuxSendAuto;
    ALeffectslot *Target;

    ALenum Type;
    EffectProps Props;

    al::intrusive_ptr<EffectState> State;

    std::atomic<ALeffectslotProps*> next;

    DEF_NEWDEL(ALeffectslotProps)
};


enum class SlotState : ALenum {
    Initial = AL_INITIAL,
    Playing = AL_PLAYING,
    Stopped = AL_STOPPED,
};

struct ALeffectslot {
    float Gain{1.0f};
    bool  AuxSendAuto{true};
    ALeffectslot *Target{nullptr};
    ALbuffer *Buffer{nullptr};

    struct {
        ALenum Type{AL_EFFECT_NULL};
        EffectProps Props{};

        al::intrusive_ptr<EffectState> State;
    } Effect;

    std::atomic_flag PropsClean;

    SlotState mState{SlotState::Initial};

    RefCount ref{0u};

    struct {
        std::atomic<ALeffectslotProps*> Update{nullptr};

        float Gain{1.0f};
        bool  AuxSendAuto{true};
        ALeffectslot *Target{nullptr};

        ALenum EffectType{AL_EFFECT_NULL};
        EffectProps mEffectProps{};
        EffectState *mEffectState{nullptr};

        float RoomRolloff{0.0f}; /* Added to the source's room rolloff, not multiplied. */
        float DecayTime{0.0f};
        float DecayLFRatio{0.0f};
        float DecayHFRatio{0.0f};
        bool DecayHFLimit{false};
        float AirAbsorptionGainHF{1.0f};
    } Params;

    /* Self ID */
    ALuint id{};

    /* Mixing buffer used by the Wet mix. */
    WetBuffer *mWetBuffer{nullptr};

    /* Wet buffer configuration is ACN channel order with N3D scaling.
     * Consequently, effects that only want to work with mono input can use
     * channel 0 by itself. Effects that want multichannel can process the
     * ambisonics signal and make a B-Format source pan.
     */
    MixParams Wet;

    ALeffectslot() { PropsClean.test_and_set(std::memory_order_relaxed); }
    ALeffectslot(const ALeffectslot&) = delete;
    ALeffectslot& operator=(const ALeffectslot&) = delete;
    ~ALeffectslot();

    ALenum init();
    ALenum initEffect(ALeffect *effect, ALCcontext *context);
    void updateProps(ALCcontext *context);

    static ALeffectslotArray *CreatePtrArray(size_t count) noexcept;

    /* This can be new'd for the context's default effect slot. */
    DEF_NEWDEL(ALeffectslot)
};

void UpdateAllEffectSlotProps(ALCcontext *context);

#endif
