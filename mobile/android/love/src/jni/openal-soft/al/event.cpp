
#include "config.h"

#include "event.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"

#include "albyte.h"
#include "alcontext.h"
#include "alexcpt.h"
#include "almalloc.h"
#include "effects/base.h"
#include "inprogext.h"
#include "logging.h"
#include "opthelpers.h"
#include "ringbuffer.h"
#include "threads.h"


static int EventThread(ALCcontext *context)
{
    RingBuffer *ring{context->mAsyncEvents.get()};
    bool quitnow{false};
    while LIKELY(!quitnow)
    {
        auto evt_data = ring->getReadVector().first;
        if(evt_data.len == 0)
        {
            context->mEventSem.wait();
            continue;
        }

        std::lock_guard<std::mutex> _{context->mEventCbLock};
        do {
            auto *evt_ptr = reinterpret_cast<AsyncEvent*>(evt_data.buf);
            evt_data.buf += sizeof(AsyncEvent);
            evt_data.len -= 1;

            AsyncEvent evt{*evt_ptr};
            al::destroy_at(evt_ptr);
            ring->readAdvance(1);

            quitnow = evt.EnumType == EventType_KillThread;
            if UNLIKELY(quitnow) break;

            if(evt.EnumType == EventType_ReleaseEffectState)
            {
                evt.u.mEffectState->release();
                continue;
            }

            ALbitfieldSOFT enabledevts{context->mEnabledEvts.load(std::memory_order_acquire)};
            if(!context->mEventCb) continue;

            if(evt.EnumType == EventType_SourceStateChange)
            {
                if(!(enabledevts&EventType_SourceStateChange))
                    continue;
                std::string msg{"Source ID " + std::to_string(evt.u.srcstate.id)};
                msg += " state has changed to ";
                msg += (evt.u.srcstate.state==AL_INITIAL) ? "AL_INITIAL" :
                    (evt.u.srcstate.state==AL_PLAYING) ? "AL_PLAYING" :
                    (evt.u.srcstate.state==AL_PAUSED) ? "AL_PAUSED" :
                    (evt.u.srcstate.state==AL_STOPPED) ? "AL_STOPPED" : "<unknown>";
                context->mEventCb(AL_EVENT_TYPE_SOURCE_STATE_CHANGED_SOFT, evt.u.srcstate.id,
                    static_cast<ALuint>(evt.u.srcstate.state), static_cast<ALsizei>(msg.length()),
                    msg.c_str(), context->mEventParam);
            }
            else if(evt.EnumType == EventType_BufferCompleted)
            {
                if(!(enabledevts&EventType_BufferCompleted))
                    continue;
                std::string msg{std::to_string(evt.u.bufcomp.count)};
                if(evt.u.bufcomp.count == 1) msg += " buffer completed";
                else msg += " buffers completed";
                context->mEventCb(AL_EVENT_TYPE_BUFFER_COMPLETED_SOFT, evt.u.bufcomp.id,
                    evt.u.bufcomp.count, static_cast<ALsizei>(msg.length()), msg.c_str(),
                    context->mEventParam);
            }
            else if((enabledevts&evt.EnumType) == evt.EnumType)
                context->mEventCb(evt.u.user.type, evt.u.user.id, evt.u.user.param,
                    static_cast<ALsizei>(strlen(evt.u.user.msg)), evt.u.user.msg,
                    context->mEventParam);
        } while(evt_data.len != 0);
    }
    return 0;
}

void StartEventThrd(ALCcontext *ctx)
{
    try {
        ctx->mEventThread = std::thread{EventThread, ctx};
    }
    catch(std::exception& e) {
        ERR("Failed to start event thread: %s\n", e.what());
    }
    catch(...) {
        ERR("Failed to start event thread! Expect problems.\n");
    }
}

void StopEventThrd(ALCcontext *ctx)
{
    RingBuffer *ring{ctx->mAsyncEvents.get()};
    auto evt_data = ring->getWriteVector().first;
    if(evt_data.len == 0)
    {
        do {
            std::this_thread::yield();
            evt_data = ring->getWriteVector().first;
        } while(evt_data.len == 0);
    }
    ::new(evt_data.buf) AsyncEvent{EventType_KillThread};
    ring->writeAdvance(1);

    ctx->mEventSem.post();
    if(ctx->mEventThread.joinable())
        ctx->mEventThread.join();
}

AL_API void AL_APIENTRY alEventControlSOFT(ALsizei count, const ALenum *types, ALboolean enable)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if(count < 0) context->setError(AL_INVALID_VALUE, "Controlling %d events", count);
    if(count <= 0) return;
    if(!types) SETERR_RETURN(context, AL_INVALID_VALUE,, "NULL pointer");

    ALbitfieldSOFT flags{0};
    const ALenum *types_end = types+count;
    auto bad_type = std::find_if_not(types, types_end,
        [&flags](ALenum type) noexcept -> bool
        {
            if(type == AL_EVENT_TYPE_BUFFER_COMPLETED_SOFT)
                flags |= EventType_BufferCompleted;
            else if(type == AL_EVENT_TYPE_SOURCE_STATE_CHANGED_SOFT)
                flags |= EventType_SourceStateChange;
            else if(type == AL_EVENT_TYPE_DISCONNECTED_SOFT)
                flags |= EventType_Disconnected;
            else
                return false;
            return true;
        }
    );
    if(bad_type != types_end)
        SETERR_RETURN(context, AL_INVALID_ENUM,, "Invalid event type 0x%04x", *bad_type);

    if(enable)
    {
        ALbitfieldSOFT enabledevts{context->mEnabledEvts.load(std::memory_order_relaxed)};
        while(context->mEnabledEvts.compare_exchange_weak(enabledevts, enabledevts|flags,
            std::memory_order_acq_rel, std::memory_order_acquire) == 0)
        {
            /* enabledevts is (re-)filled with the current value on failure, so
             * just try again.
             */
        }
    }
    else
    {
        ALbitfieldSOFT enabledevts{context->mEnabledEvts.load(std::memory_order_relaxed)};
        while(context->mEnabledEvts.compare_exchange_weak(enabledevts, enabledevts&~flags,
            std::memory_order_acq_rel, std::memory_order_acquire) == 0)
        {
        }
        /* Wait to ensure the event handler sees the changed flags before
         * returning.
         */
        std::lock_guard<std::mutex>{context->mEventCbLock};
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alEventCallbackSOFT(ALEVENTPROCSOFT callback, void *userParam)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mPropLock};
    std::lock_guard<std::mutex> __{context->mEventCbLock};
    context->mEventCb = callback;
    context->mEventParam = userParam;
}
END_API_FUNC
