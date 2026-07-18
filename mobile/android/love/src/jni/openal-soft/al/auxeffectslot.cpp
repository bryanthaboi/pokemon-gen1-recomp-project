/**
 * OpenAL cross platform audio library
 * Copyright (C) 1999-2007 by authors.
 * This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Library General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 *  License along with this library; if not, write to the
 *  Free Software Foundation, Inc.,
 *  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 * Or go to http://www.gnu.org/copyleft/lgpl.html
 */

#include "config.h"

#include "auxeffectslot.h"

#include <algorithm>
#include <cstdint>
#include <iterator>
#include <memory>
#include <mutex>
#include <numeric>
#include <thread>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/efx.h"

#include "alcmain.h"
#include "alcontext.h"
#include "alexcpt.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "alspan.h"
#include "alu.h"
#include "buffer.h"
#include "effect.h"
#include "fpu_ctrl.h"
#include "inprogext.h"
#include "logging.h"
#include "opthelpers.h"


namespace {

inline ALeffectslot *LookupEffectSlot(ALCcontext *context, ALuint id) noexcept
{
    const size_t lidx{(id-1) >> 6};
    const ALuint slidx{(id-1) & 0x3f};

    if UNLIKELY(lidx >= context->mEffectSlotList.size())
        return nullptr;
    EffectSlotSubList &sublist{context->mEffectSlotList[lidx]};
    if UNLIKELY(sublist.FreeMask & (1_u64 << slidx))
        return nullptr;
    return sublist.EffectSlots + slidx;
}

inline ALeffect *LookupEffect(ALCdevice *device, ALuint id) noexcept
{
    const size_t lidx{(id-1) >> 6};
    const ALuint slidx{(id-1) & 0x3f};

    if UNLIKELY(lidx >= device->EffectList.size())
        return nullptr;
    EffectSubList &sublist = device->EffectList[lidx];
    if UNLIKELY(sublist.FreeMask & (1_u64 << slidx))
        return nullptr;
    return sublist.Effects + slidx;
}

inline ALbuffer *LookupBuffer(ALCdevice *device, ALuint id) noexcept
{
    const size_t lidx{(id-1) >> 6};
    const ALuint slidx{(id-1) & 0x3f};

    if UNLIKELY(lidx >= device->BufferList.size())
        return nullptr;
    BufferSubList &sublist = device->BufferList[lidx];
    if UNLIKELY(sublist.FreeMask & (1_u64 << slidx))
        return nullptr;
    return sublist.Buffers + slidx;
}


void AddActiveEffectSlots(const al::span<const ALuint> slotids, ALCcontext *context)
{
    if(slotids.empty()) return;
    ALeffectslotArray *curarray{context->mActiveAuxSlots.load(std::memory_order_acquire)};
    size_t newcount{curarray->size() + slotids.size()};

    /* Insert the new effect slots into the head of the array, followed by the
     * existing ones.
     */
    ALeffectslotArray *newarray = ALeffectslot::CreatePtrArray(newcount);
    auto slotiter = std::transform(slotids.begin(), slotids.end(), newarray->begin(),
        [context](ALuint id) noexcept -> ALeffectslot*
        { return LookupEffectSlot(context, id); });
    std::copy(curarray->begin(), curarray->end(), slotiter);

    /* Remove any duplicates (first instance of each will be kept). */
    auto last = newarray->end();
    for(auto start=newarray->begin()+1;;)
    {
        last = std::remove(start, last, *(start-1));
        if(start == last) break;
        ++start;
    }
    newcount = static_cast<size_t>(std::distance(newarray->begin(), last));

    /* Reallocate newarray if the new size ended up smaller from duplicate
     * removal.
     */
    if UNLIKELY(newcount < newarray->size())
    {
        curarray = newarray;
        newarray = ALeffectslot::CreatePtrArray(newcount);
        std::copy_n(curarray->begin(), newcount, newarray->begin());
        delete curarray;
        curarray = nullptr;
    }
    std::uninitialized_fill_n(newarray->end(), newcount, nullptr);

    curarray = context->mActiveAuxSlots.exchange(newarray, std::memory_order_acq_rel);
    context->mDevice->waitForMix();

    al::destroy_n(curarray->end(), curarray->size());
    delete curarray;
}

void RemoveActiveEffectSlots(const al::span<const ALuint> slotids, ALCcontext *context)
{
    if(slotids.empty()) return;
    ALeffectslotArray *curarray{context->mActiveAuxSlots.load(std::memory_order_acquire)};

    /* Don't shrink the allocated array size since we don't know how many (if
     * any) of the effect slots to remove are in the array.
     */
    ALeffectslotArray *newarray = ALeffectslot::CreatePtrArray(curarray->size());

    /* Copy each element in curarray to newarray whose ID is not in slotids. */
    auto slotiter = std::copy_if(curarray->begin(), curarray->end(), newarray->begin(),
        [slotids](const ALeffectslot *slot) -> bool
        { return std::find(slotids.begin(), slotids.end(), slot->id) == slotids.end(); });

    /* Reallocate with the new size. */
    auto newsize = static_cast<size_t>(std::distance(newarray->begin(), slotiter));
    if LIKELY(newsize != newarray->size())
    {
        curarray = newarray;
        newarray = ALeffectslot::CreatePtrArray(newsize);
        std::copy_n(curarray->begin(), newsize, newarray->begin());

        delete curarray;
        curarray = nullptr;
    }
    std::uninitialized_fill_n(newarray->end(), newsize, nullptr);

    curarray = context->mActiveAuxSlots.exchange(newarray, std::memory_order_acq_rel);
    context->mDevice->waitForMix();

    al::destroy_n(curarray->end(), curarray->size());
    delete curarray;
}


bool EnsureEffectSlots(ALCcontext *context, size_t needed)
{
    size_t count{std::accumulate(context->mEffectSlotList.cbegin(),
        context->mEffectSlotList.cend(), size_t{0},
        [](size_t cur, const EffectSlotSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(sublist.FreeMask)); }
    )};

    while(needed > count)
    {
        if UNLIKELY(context->mEffectSlotList.size() >= 1<<25)
            return false;

        context->mEffectSlotList.emplace_back();
        auto sublist = context->mEffectSlotList.end() - 1;
        sublist->FreeMask = ~0_u64;
        sublist->EffectSlots = static_cast<ALeffectslot*>(
            al_calloc(alignof(ALeffectslot), sizeof(ALeffectslot)*64));
        if UNLIKELY(!sublist->EffectSlots)
        {
            context->mEffectSlotList.pop_back();
            return false;
        }
        count += 64;
    }
    return true;
}

ALeffectslot *AllocEffectSlot(ALCcontext *context)
{
    auto sublist = std::find_if(context->mEffectSlotList.begin(), context->mEffectSlotList.end(),
        [](const EffectSlotSubList &entry) noexcept -> bool
        { return entry.FreeMask != 0; }
    );
    auto lidx = static_cast<ALuint>(std::distance(context->mEffectSlotList.begin(), sublist));
    auto slidx = static_cast<ALuint>(CountTrailingZeros(sublist->FreeMask));

    ALeffectslot *slot{::new (sublist->EffectSlots + slidx) ALeffectslot{}};
    if(ALenum err{slot->init()})
    {
        al::destroy_at(slot);
        context->setError(err, "Effect slot object initialization failed");
        return nullptr;
    }
    aluInitEffectPanning(slot, context);

    /* Add 1 to avoid source ID 0. */
    slot->id = ((lidx<<6) | slidx) + 1;

    context->mNumEffectSlots += 1;
    sublist->FreeMask &= ~(1_u64 << slidx);

    return slot;
}

void FreeEffectSlot(ALCcontext *context, ALeffectslot *slot)
{
    const ALuint id{slot->id - 1};
    const size_t lidx{id >> 6};
    const ALuint slidx{id & 0x3f};

    al::destroy_at(slot);

    context->mEffectSlotList[lidx].FreeMask |= 1_u64 << slidx;
    context->mNumEffectSlots--;
}


#define DO_UPDATEPROPS() do {                                                 \
    if(!context->mDeferUpdates.load(std::memory_order_acquire)                \
        && slot->mState == SlotState::Playing)                                \
        slot->updateProps(context.get());                                     \
    else                                                                      \
        slot->PropsClean.clear(std::memory_order_release);                    \
} while(0)

} // namespace

ALeffectslotArray *ALeffectslot::CreatePtrArray(size_t count) noexcept
{
    /* Allocate space for twice as many pointers, so the mixer has scratch
     * space to store a sorted list during mixing.
     */
    void *ptr{al_calloc(alignof(ALeffectslotArray), ALeffectslotArray::Sizeof(count*2))};
    return new (ptr) ALeffectslotArray{count};
}


AL_API void AL_APIENTRY alGenAuxiliaryEffectSlots(ALsizei n, ALuint *effectslots)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if UNLIKELY(n < 0)
        context->setError(AL_INVALID_VALUE, "Generating %d effect slots", n);
    if UNLIKELY(n <= 0) return;

    std::unique_lock<std::mutex> slotlock{context->mEffectSlotLock};
    ALCdevice *device{context->mDevice.get()};
    if(static_cast<ALuint>(n) > device->AuxiliaryEffectSlotMax-context->mNumEffectSlots)
    {
        context->setError(AL_OUT_OF_MEMORY, "Exceeding %u effect slot limit (%u + %d)",
            device->AuxiliaryEffectSlotMax, context->mNumEffectSlots, n);
        return;
    }
    if(!EnsureEffectSlots(context.get(), static_cast<ALuint>(n)))
    {
        context->setError(AL_OUT_OF_MEMORY, "Failed to allocate %d effectslot%s", n,
            (n==1) ? "" : "s");
        return;
    }

    if(n == 1)
    {
        ALeffectslot *slot{AllocEffectSlot(context.get())};
        if(!slot) return;
        effectslots[0] = slot->id;
    }
    else
    {
        al::vector<ALuint> ids;
        ALsizei count{n};
        ids.reserve(static_cast<ALuint>(count));
        do {
            ALeffectslot *slot{AllocEffectSlot(context.get())};
            if(!slot)
            {
                slotlock.unlock();
                alDeleteAuxiliaryEffectSlots(static_cast<ALsizei>(ids.size()), ids.data());
                return;
            }
            ids.emplace_back(slot->id);
        } while(--count);
        std::copy(ids.cbegin(), ids.cend(), effectslots);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alDeleteAuxiliaryEffectSlots(ALsizei n, const ALuint *effectslots)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if UNLIKELY(n < 0)
        context->setError(AL_INVALID_VALUE, "Deleting %d effect slots", n);
    if UNLIKELY(n <= 0) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    auto validate_slot = [&context](const ALuint id) -> bool
    {
        ALeffectslot *slot{LookupEffectSlot(context.get(), id)};
        if UNLIKELY(!slot)
        {
            context->setError(AL_INVALID_NAME, "Invalid effect slot ID %u", id);
            return false;
        }
        if UNLIKELY(ReadRef(slot->ref) != 0)
        {
            context->setError(AL_INVALID_OPERATION, "Deleting in-use effect slot %u", id);
            return false;
        }
        return true;
    };
    auto effectslots_end = effectslots + n;
    auto bad_slot = std::find_if_not(effectslots, effectslots_end, validate_slot);
    if UNLIKELY(bad_slot != effectslots_end) return;

    // All effectslots are valid, remove and delete them
    RemoveActiveEffectSlots({effectslots, static_cast<ALuint>(n)}, context.get());
    auto delete_slot = [&context](const ALuint sid) -> void
    {
        ALeffectslot *slot{LookupEffectSlot(context.get(), sid)};
        if(slot) FreeEffectSlot(context.get(), slot);
    };
    std::for_each(effectslots, effectslots_end, delete_slot);
}
END_API_FUNC

AL_API ALboolean AL_APIENTRY alIsAuxiliaryEffectSlot(ALuint effectslot)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if LIKELY(context)
    {
        std::lock_guard<std::mutex> _{context->mEffectSlotLock};
        if(LookupEffectSlot(context.get(), effectslot) != nullptr)
            return AL_TRUE;
    }
    return AL_FALSE;
}
END_API_FUNC


AL_API void AL_APIENTRY alAuxiliaryEffectSlotPlaySOFT(ALuint slotid)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot{LookupEffectSlot(context.get(), slotid)};
    if UNLIKELY(!slot)
    {
        context->setError(AL_INVALID_NAME, "Invalid effect slot ID %u", slotid);
        return;
    }
    if(slot->mState == SlotState::Playing)
        return;

    slot->PropsClean.test_and_set(std::memory_order_acq_rel);
    slot->updateProps(context.get());

    AddActiveEffectSlots({&slotid, 1}, context.get());
    slot->mState = SlotState::Playing;
}
END_API_FUNC

AL_API void AL_APIENTRY alAuxiliaryEffectSlotPlayvSOFT(ALsizei n, const ALuint *slotids)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if UNLIKELY(n < 0)
        context->setError(AL_INVALID_VALUE, "Playing %d effect slots", n);
    if UNLIKELY(n <= 0) return;

    auto slots = al::vector<ALeffectslot*>(static_cast<ALuint>(n));
    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    for(size_t i{0};i < slots.size();++i)
    {
        ALeffectslot *slot{LookupEffectSlot(context.get(), slotids[i])};
        if UNLIKELY(!slot)
        {
            context->setError(AL_INVALID_NAME, "Invalid effect slot ID %u", slotids[i]);
            return;
        }

        if(slot->mState != SlotState::Playing)
        {
            slot->PropsClean.test_and_set(std::memory_order_acq_rel);
            slot->updateProps(context.get());
        }
        slots[i] = slot;
    };

    AddActiveEffectSlots({slotids, static_cast<ALuint>(n)}, context.get());
    for(auto slot : slots)
        slot->mState = SlotState::Playing;
}
END_API_FUNC

AL_API void AL_APIENTRY alAuxiliaryEffectSlotStopSOFT(ALuint slotid)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot{LookupEffectSlot(context.get(), slotid)};
    if UNLIKELY(!slot)
    {
        context->setError(AL_INVALID_NAME, "Invalid effect slot ID %u", slotid);
        return;
    }

    RemoveActiveEffectSlots({&slotid, 1}, context.get());
    slot->mState = SlotState::Stopped;
}
END_API_FUNC

AL_API void AL_APIENTRY alAuxiliaryEffectSlotStopvSOFT(ALsizei n, const ALuint *slotids)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if UNLIKELY(n < 0)
        context->setError(AL_INVALID_VALUE, "Stopping %d effect slots", n);
    if UNLIKELY(n <= 0) return;

    auto slots = al::vector<ALeffectslot*>(static_cast<ALuint>(n));
    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    for(size_t i{0};i < slots.size();++i)
    {
        ALeffectslot *slot{LookupEffectSlot(context.get(), slotids[i])};
        if UNLIKELY(!slot)
        {
            context->setError(AL_INVALID_NAME, "Invalid effect slot ID %u", slotids[i]);
            return;
        }

        slots[i] = slot;
    };

    RemoveActiveEffectSlots({slotids, static_cast<ALuint>(n)}, context.get());
    for(auto slot : slots)
        slot->mState = SlotState::Stopped;
}
END_API_FUNC


AL_API void AL_APIENTRY alAuxiliaryEffectSloti(ALuint effectslot, ALenum param, ALint value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mPropLock};
    std::lock_guard<std::mutex> __{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    ALeffectslot *target{};
    ALCdevice *device{};
    ALenum err{};
    switch(param)
    {
    case AL_EFFECTSLOT_EFFECT:
        device = context->mDevice.get();

        {
            std::lock_guard<std::mutex> ___{device->EffectLock};
            ALeffect *effect{value ? LookupEffect(device, static_cast<ALuint>(value)) : nullptr};
            if(!(value == 0 || effect != nullptr))
                SETERR_RETURN(context, AL_INVALID_VALUE,, "Invalid effect ID %u", value);
            err = slot->initEffect(effect, context.get());
        }
        if UNLIKELY(err != AL_NO_ERROR)
        {
            context->setError(err, "Effect initialization failed");
            return;
        }
        if UNLIKELY(slot->mState == SlotState::Initial)
        {
            AddActiveEffectSlots({&slot->id, 1}, context.get());
            slot->mState = SlotState::Playing;
        }
        break;

    case AL_EFFECTSLOT_AUXILIARY_SEND_AUTO:
        if(!(value == AL_TRUE || value == AL_FALSE))
            SETERR_RETURN(context, AL_INVALID_VALUE,,
                "Effect slot auxiliary send auto out of range");
        slot->AuxSendAuto = !!value;
        break;

    case AL_EFFECTSLOT_TARGET_SOFT:
        target = LookupEffectSlot(context.get(), static_cast<ALuint>(value));
        if(value && !target)
            SETERR_RETURN(context, AL_INVALID_VALUE,, "Invalid effect slot target ID");
        if(target)
        {
            ALeffectslot *checker{target};
            while(checker && checker != slot)
                checker = checker->Target;
            if(checker)
                SETERR_RETURN(context, AL_INVALID_OPERATION,,
                    "Setting target of effect slot ID %u to %u creates circular chain", slot->id,
                    target->id);
        }

        if(ALeffectslot *oldtarget{slot->Target})
        {
            /* We must force an update if there was an existing effect slot
             * target, in case it's about to be deleted.
             */
            if(target) IncrementRef(target->ref);
            DecrementRef(oldtarget->ref);
            slot->Target = target;
            slot->updateProps(context.get());
            return;
        }

        if(target) IncrementRef(target->ref);
        slot->Target = target;
        break;

    case AL_BUFFER:
        device = context->mDevice.get();

        if(slot->mState == SlotState::Playing)
            SETERR_RETURN(context, AL_INVALID_OPERATION,,
                "Setting buffer on playing effect slot %u", slot->id);

        {
            std::lock_guard<std::mutex> ___{device->BufferLock};
            ALbuffer *buffer{};
            if(value)
            {
                buffer = LookupBuffer(device, static_cast<ALuint>(value));
                if(!buffer) SETERR_RETURN(context, AL_INVALID_VALUE,, "Invalid buffer ID");
                if(buffer->mBuffer.mCallback)
                    SETERR_RETURN(context, AL_INVALID_OPERATION,,
                        "Callback buffer not valid for effects");

                IncrementRef(buffer->ref);
            }

            if(ALbuffer *oldbuffer{slot->Buffer})
                DecrementRef(oldbuffer->ref);
            slot->Buffer = buffer;

            FPUCtl mixer_mode{};
            auto *state = slot->Effect.State.get();
            state->setBuffer(device, buffer ? &buffer->mBuffer : nullptr);
        }
        break;

    case AL_EFFECTSLOT_STATE_SOFT:
        SETERR_RETURN(context, AL_INVALID_OPERATION,, "AL_EFFECTSLOT_STATE_SOFT is read-only");

    default:
        SETERR_RETURN(context, AL_INVALID_ENUM,, "Invalid effect slot integer property 0x%04x",
            param);
    }
    DO_UPDATEPROPS();
}
END_API_FUNC

AL_API void AL_APIENTRY alAuxiliaryEffectSlotiv(ALuint effectslot, ALenum param, const ALint *values)
START_API_FUNC
{
    switch(param)
    {
    case AL_EFFECTSLOT_EFFECT:
    case AL_EFFECTSLOT_AUXILIARY_SEND_AUTO:
    case AL_EFFECTSLOT_TARGET_SOFT:
    case AL_EFFECTSLOT_STATE_SOFT:
    case AL_BUFFER:
        alAuxiliaryEffectSloti(effectslot, param, values[0]);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    default:
        SETERR_RETURN(context, AL_INVALID_ENUM,,
            "Invalid effect slot integer-vector property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alAuxiliaryEffectSlotf(ALuint effectslot, ALenum param, ALfloat value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mPropLock};
    std::lock_guard<std::mutex> __{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    case AL_EFFECTSLOT_GAIN:
        if(!(value >= 0.0f && value <= 1.0f))
            SETERR_RETURN(context, AL_INVALID_VALUE,, "Effect slot gain out of range");
        slot->Gain = value;
        break;

    default:
        SETERR_RETURN(context, AL_INVALID_ENUM,, "Invalid effect slot float property 0x%04x",
            param);
    }
    DO_UPDATEPROPS();
}
END_API_FUNC

AL_API void AL_APIENTRY alAuxiliaryEffectSlotfv(ALuint effectslot, ALenum param, const ALfloat *values)
START_API_FUNC
{
    switch(param)
    {
    case AL_EFFECTSLOT_GAIN:
        alAuxiliaryEffectSlotf(effectslot, param, values[0]);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    default:
        SETERR_RETURN(context, AL_INVALID_ENUM,,
            "Invalid effect slot float-vector property 0x%04x", param);
    }
}
END_API_FUNC


AL_API void AL_APIENTRY alGetAuxiliaryEffectSloti(ALuint effectslot, ALenum param, ALint *value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    case AL_EFFECTSLOT_AUXILIARY_SEND_AUTO:
        *value = slot->AuxSendAuto ? AL_TRUE : AL_FALSE;
        break;

    case AL_EFFECTSLOT_TARGET_SOFT:
        if(auto *target = slot->Target)
            *value = static_cast<ALint>(target->id);
        else
            *value = 0;
        break;

    case AL_EFFECTSLOT_STATE_SOFT:
        *value = static_cast<int>(slot->mState);
        break;

    case AL_BUFFER:
        if(auto *buffer = slot->Buffer)
            *value = static_cast<ALint>(buffer->id);
        else
            *value = 0;
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid effect slot integer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetAuxiliaryEffectSlotiv(ALuint effectslot, ALenum param, ALint *values)
START_API_FUNC
{
    switch(param)
    {
    case AL_EFFECTSLOT_EFFECT:
    case AL_EFFECTSLOT_AUXILIARY_SEND_AUTO:
    case AL_EFFECTSLOT_TARGET_SOFT:
    case AL_EFFECTSLOT_STATE_SOFT:
    case AL_BUFFER:
        alGetAuxiliaryEffectSloti(effectslot, param, values);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid effect slot integer-vector property 0x%04x",
            param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetAuxiliaryEffectSlotf(ALuint effectslot, ALenum param, ALfloat *value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    case AL_EFFECTSLOT_GAIN:
        *value = slot->Gain;
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid effect slot float property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetAuxiliaryEffectSlotfv(ALuint effectslot, ALenum param, ALfloat *values)
START_API_FUNC
{
    switch(param)
    {
    case AL_EFFECTSLOT_GAIN:
        alGetAuxiliaryEffectSlotf(effectslot, param, values);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslot *slot = LookupEffectSlot(context.get(), effectslot);
    if UNLIKELY(!slot)
        SETERR_RETURN(context, AL_INVALID_NAME,, "Invalid effect slot ID %u", effectslot);

    switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid effect slot float-vector property 0x%04x",
            param);
    }
}
END_API_FUNC


ALeffectslot::~ALeffectslot()
{
    if(Target)
        DecrementRef(Target->ref);
    Target = nullptr;
    if(Buffer)
        DecrementRef(Buffer->ref);
    Buffer = nullptr;

    ALeffectslotProps *props{Params.Update.load()};
    if(props)
    {
        TRACE("Freed unapplied AuxiliaryEffectSlot update %p\n",
            decltype(std::declval<void*>()){props});
        delete props;
    }

    if(mWetBuffer)
        mWetBuffer->mInUse = false;
    if(Params.mEffectState)
        Params.mEffectState->release();
}

ALenum ALeffectslot::init()
{
    EffectStateFactory *factory{getFactoryByType(Effect.Type)};
    if(!factory) return AL_INVALID_VALUE;

    Effect.State.reset(factory->create());
    if(!Effect.State) return AL_OUT_OF_MEMORY;

    Effect.State->add_ref();
    Params.mEffectState = Effect.State.get();
    return AL_NO_ERROR;
}

ALenum ALeffectslot::initEffect(ALeffect *effect, ALCcontext *context)
{
    ALenum newtype{effect ? effect->type : AL_EFFECT_NULL};
    if(newtype != Effect.Type)
    {
        EffectStateFactory *factory{getFactoryByType(newtype)};
        if(!factory)
        {
            ERR("Failed to find factory for effect type 0x%04x\n", newtype);
            return AL_INVALID_ENUM;
        }
        al::intrusive_ptr<EffectState> State{factory->create()};
        if(!State) return AL_OUT_OF_MEMORY;

        ALCdevice *Device{context->mDevice.get()};
        std::unique_lock<std::mutex> statelock{Device->StateLock};
        State->mOutTarget = Device->Dry.Buffer;
        {
            FPUCtl mixer_mode{};
            State->deviceUpdate(Device);
            if(Buffer)
                State->setBuffer(Device, &Buffer->mBuffer);
        }

        if(!effect)
        {
            Effect.Type = AL_EFFECT_NULL;
            Effect.Props = EffectProps{};
        }
        else
        {
            Effect.Type = effect->type;
            Effect.Props = effect->Props;
        }

        Effect.State = std::move(State);
    }
    else if(effect)
        Effect.Props = effect->Props;

    /* Remove state references from old effect slot property updates. */
    ALeffectslotProps *props{context->mFreeEffectslotProps.load()};
    while(props)
    {
        props->State = nullptr;
        props = props->next.load(std::memory_order_relaxed);
    }

    return AL_NO_ERROR;
}

void ALeffectslot::updateProps(ALCcontext *context)
{
    /* Get an unused property container, or allocate a new one as needed. */
    ALeffectslotProps *props{context->mFreeEffectslotProps.load(std::memory_order_relaxed)};
    if(!props)
        props = new ALeffectslotProps{};
    else
    {
        ALeffectslotProps *next;
        do {
            next = props->next.load(std::memory_order_relaxed);
        } while(context->mFreeEffectslotProps.compare_exchange_weak(props, next,
                std::memory_order_seq_cst, std::memory_order_acquire) == 0);
    }

    /* Copy in current property values. */
    props->Gain = Gain;
    props->AuxSendAuto = AuxSendAuto;
    props->Target = Target;

    props->Type = Effect.Type;
    props->Props = Effect.Props;
    props->State = Effect.State;

    /* Set the new container for updating internal parameters. */
    props = Params.Update.exchange(props, std::memory_order_acq_rel);
    if(props)
    {
        /* If there was an unused update container, put it back in the
         * freelist.
         */
        props->State = nullptr;
        AtomicReplaceHead(context->mFreeEffectslotProps, props);
    }
}

void UpdateAllEffectSlotProps(ALCcontext *context)
{
    std::lock_guard<std::mutex> _{context->mEffectSlotLock};
    ALeffectslotArray *auxslots{context->mActiveAuxSlots.load(std::memory_order_acquire)};
    for(ALeffectslot *slot : *auxslots)
    {
        if(!slot->PropsClean.test_and_set(std::memory_order_acq_rel))
            slot->updateProps(context);
    }
}

EffectSlotSubList::~EffectSlotSubList()
{
    uint64_t usemask{~FreeMask};
    while(usemask)
    {
        const ALsizei idx{CountTrailingZeros(usemask)};
        al::destroy_at(EffectSlots+idx);
        usemask &= ~(1_u64 << idx);
    }
    FreeMask = ~usemask;
    al_free(EffectSlots);
    EffectSlots = nullptr;
}
