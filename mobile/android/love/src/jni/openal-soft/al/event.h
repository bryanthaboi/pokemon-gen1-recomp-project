#ifndef AL_EVENT_H
#define AL_EVENT_H

#include "AL/al.h"
#include "AL/alc.h"

#include "almalloc.h"

struct EffectState;


enum {
    /* End event thread processing. */
    EventType_KillThread = 0,

    /* User event types. */
    EventType_SourceStateChange = 1<<0,
    EventType_BufferCompleted   = 1<<1,
    EventType_Disconnected      = 1<<2,

    /* Internal events. */
    EventType_ReleaseEffectState = 65536,
};

struct AsyncEvent {
    unsigned int EnumType{0u};
    union {
        char dummy;
        struct {
            ALuint id;
            ALenum state;
        } srcstate;
        struct {
            ALuint id;
            ALuint count;
        } bufcomp;
        struct {
            ALenum type;
            ALuint id;
            ALuint param;
            ALchar msg[232];
        } user;
        EffectState *mEffectState;
    } u{};

    AsyncEvent() noexcept = default;
    constexpr AsyncEvent(unsigned int type) noexcept : EnumType{type} { }

    DISABLE_ALLOC()
};


void StartEventThrd(ALCcontext *ctx);
void StopEventThrd(ALCcontext *ctx);

#endif
