/**
 * OpenAL cross platform audio library
 * Copyright (C) 2009 by Chris Robinson.
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

#include <cmath>
#include <cstdlib>

#include <algorithm>

#include "al/auxeffectslot.h"
#include "al/filter.h"
#include "alcmain.h"
#include "alcontext.h"
#include "alu.h"
#include "filters/biquad.h"
#include "vector.h"


namespace {

struct EchoState final : public EffectState {
    al::vector<float,16> mSampleBuffer;

    // The echo is two tap. The delay is the number of samples from before the
    // current offset
    struct {
        size_t delay{0u};
    } mTap[2];
    size_t mOffset{0u};

    /* The panning gains for the two taps */
    struct {
        float Current[MAX_OUTPUT_CHANNELS]{};
        float Target[MAX_OUTPUT_CHANNELS]{};
    } mGains[2];

    BiquadFilter mFilter;
    float mFeedGain{0.0f};

    alignas(16) float mTempBuffer[2][BUFFERSIZE];

    void deviceUpdate(const ALCdevice *device) override;
    void update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target) override;
    void process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut) override;

    DEF_NEWDEL(EchoState)
};

void EchoState::deviceUpdate(const ALCdevice *Device)
{
    const auto frequency = static_cast<float>(Device->Frequency);

    // Use the next power of 2 for the buffer length, so the tap offsets can be
    // wrapped using a mask instead of a modulo
    const ALuint maxlen{NextPowerOf2(float2uint(AL_ECHO_MAX_DELAY*frequency + 0.5f) +
        float2uint(AL_ECHO_MAX_LRDELAY*frequency + 0.5f))};
    if(maxlen != mSampleBuffer.size())
        al::vector<float,16>(maxlen).swap(mSampleBuffer);

    std::fill(mSampleBuffer.begin(), mSampleBuffer.end(), 0.0f);
    for(auto &e : mGains)
    {
        std::fill(std::begin(e.Current), std::end(e.Current), 0.0f);
        std::fill(std::begin(e.Target), std::end(e.Target), 0.0f);
    }
}

void EchoState::update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target)
{
    const ALCdevice *device{context->mDevice.get()};
    const auto frequency = static_cast<float>(device->Frequency);

    mTap[0].delay = maxu(float2uint(props->Echo.Delay*frequency + 0.5f), 1);
    mTap[1].delay = float2uint(props->Echo.LRDelay*frequency + 0.5f) + mTap[0].delay;

    const float gainhf{maxf(1.0f - props->Echo.Damping, 0.0625f)}; /* Limit -24dB */
    mFilter.setParamsFromSlope(BiquadType::HighShelf, LOWPASSFREQREF/frequency, gainhf, 1.0f);

    mFeedGain = props->Echo.Feedback;

    /* Convert echo spread (where 0 = center, +/-1 = sides) to angle. */
    const float angle{std::asin(props->Echo.Spread)};

    const auto coeffs0 = CalcAngleCoeffs(-angle, 0.0f, 0.0f);
    const auto coeffs1 = CalcAngleCoeffs( angle, 0.0f, 0.0f);

    mOutTarget = target.Main->Buffer;
    ComputePanGains(target.Main, coeffs0.data(), slot->Params.Gain, mGains[0].Target);
    ComputePanGains(target.Main, coeffs1.data(), slot->Params.Gain, mGains[1].Target);
}

void EchoState::process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut)
{
    const size_t mask{mSampleBuffer.size()-1};
    float *RESTRICT delaybuf{mSampleBuffer.data()};
    size_t offset{mOffset};
    size_t tap1{offset - mTap[0].delay};
    size_t tap2{offset - mTap[1].delay};
    float z1, z2;

    ASSUME(samplesToDo > 0);

    const BiquadFilter filter{mFilter};
    std::tie(z1, z2) = mFilter.getComponents();
    for(size_t i{0u};i < samplesToDo;)
    {
        offset &= mask;
        tap1 &= mask;
        tap2 &= mask;

        size_t td{minz(mask+1 - maxz(offset, maxz(tap1, tap2)), samplesToDo-i)};
        do {
            /* Feed the delay buffer's input first. */
            delaybuf[offset] = samplesIn[0][i];

            /* Get delayed output from the first and second taps. Use the
             * second tap for feedback.
             */
            mTempBuffer[0][i] = delaybuf[tap1++];
            mTempBuffer[1][i] = delaybuf[tap2++];
            const float feedb{mTempBuffer[1][i++]};

            /* Add feedback to the delay buffer with damping and attenuation. */
            delaybuf[offset++] += filter.processOne(feedb, z1, z2) * mFeedGain;
        } while(--td);
    }
    mFilter.setComponents(z1, z2);
    mOffset = offset;

    for(ALsizei c{0};c < 2;c++)
        MixSamples({mTempBuffer[c], samplesToDo}, samplesOut, mGains[c].Current, mGains[c].Target,
            samplesToDo, 0);
}


void Echo_setParami(EffectProps*, ALenum param, int)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid echo integer property 0x%04x", param}; }
void Echo_setParamiv(EffectProps*, ALenum param, const int*)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid echo integer-vector property 0x%04x", param}; }
void Echo_setParamf(EffectProps *props, ALenum param, float val)
{
    switch(param)
    {
    case AL_ECHO_DELAY:
        if(!(val >= AL_ECHO_MIN_DELAY && val <= AL_ECHO_MAX_DELAY))
            throw effect_exception{AL_INVALID_VALUE, "Echo delay out of range"};
        props->Echo.Delay = val;
        break;

    case AL_ECHO_LRDELAY:
        if(!(val >= AL_ECHO_MIN_LRDELAY && val <= AL_ECHO_MAX_LRDELAY))
            throw effect_exception{AL_INVALID_VALUE, "Echo LR delay out of range"};
        props->Echo.LRDelay = val;
        break;

    case AL_ECHO_DAMPING:
        if(!(val >= AL_ECHO_MIN_DAMPING && val <= AL_ECHO_MAX_DAMPING))
            throw effect_exception{AL_INVALID_VALUE, "Echo damping out of range"};
        props->Echo.Damping = val;
        break;

    case AL_ECHO_FEEDBACK:
        if(!(val >= AL_ECHO_MIN_FEEDBACK && val <= AL_ECHO_MAX_FEEDBACK))
            throw effect_exception{AL_INVALID_VALUE, "Echo feedback out of range"};
        props->Echo.Feedback = val;
        break;

    case AL_ECHO_SPREAD:
        if(!(val >= AL_ECHO_MIN_SPREAD && val <= AL_ECHO_MAX_SPREAD))
            throw effect_exception{AL_INVALID_VALUE, "Echo spread out of range"};
        props->Echo.Spread = val;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid echo float property 0x%04x", param};
    }
}
void Echo_setParamfv(EffectProps *props, ALenum param, const float *vals)
{ Echo_setParamf(props, param, vals[0]); }

void Echo_getParami(const EffectProps*, ALenum param, int*)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid echo integer property 0x%04x", param}; }
void Echo_getParamiv(const EffectProps*, ALenum param, int*)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid echo integer-vector property 0x%04x", param}; }
void Echo_getParamf(const EffectProps *props, ALenum param, float *val)
{
    switch(param)
    {
    case AL_ECHO_DELAY:
        *val = props->Echo.Delay;
        break;

    case AL_ECHO_LRDELAY:
        *val = props->Echo.LRDelay;
        break;

    case AL_ECHO_DAMPING:
        *val = props->Echo.Damping;
        break;

    case AL_ECHO_FEEDBACK:
        *val = props->Echo.Feedback;
        break;

    case AL_ECHO_SPREAD:
        *val = props->Echo.Spread;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid echo float property 0x%04x", param};
    }
}
void Echo_getParamfv(const EffectProps *props, ALenum param, float *vals)
{ Echo_getParamf(props, param, vals); }

DEFINE_ALEFFECT_VTABLE(Echo);


struct EchoStateFactory final : public EffectStateFactory {
    EffectState *create() override { return new EchoState{}; }
    EffectProps getDefaultProps() const noexcept override;
    const EffectVtable *getEffectVtable() const noexcept override { return &Echo_vtable; }
};

EffectProps EchoStateFactory::getDefaultProps() const noexcept
{
    EffectProps props{};
    props.Echo.Delay    = AL_ECHO_DEFAULT_DELAY;
    props.Echo.LRDelay  = AL_ECHO_DEFAULT_LRDELAY;
    props.Echo.Damping  = AL_ECHO_DEFAULT_DAMPING;
    props.Echo.Feedback = AL_ECHO_DEFAULT_FEEDBACK;
    props.Echo.Spread   = AL_ECHO_DEFAULT_SPREAD;
    return props;
}

} // namespace

EffectStateFactory *EchoStateFactory_getFactory()
{
    static EchoStateFactory EchoFactory{};
    return &EchoFactory;
}
