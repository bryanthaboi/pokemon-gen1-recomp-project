/**
 * OpenAL cross platform audio library
 * Copyright (C) 2013 by Anis A. Hireche
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

#include <cstdlib>

#include "al/auxeffectslot.h"
#include "alcmain.h"
#include "alcontext.h"
#include "alu.h"
#include "vecmat.h"


namespace {

#define AMP_ENVELOPE_MIN  0.5f
#define AMP_ENVELOPE_MAX  2.0f

#define ATTACK_TIME  0.1f /* 100ms to rise from min to max */
#define RELEASE_TIME 0.2f /* 200ms to drop from max to min */


struct CompressorState final : public EffectState {
    /* Effect gains for each channel */
    float mGain[MAX_AMBI_CHANNELS][MAX_OUTPUT_CHANNELS]{};

    /* Effect parameters */
    bool mEnabled{true};
    float mAttackMult{1.0f};
    float mReleaseMult{1.0f};
    float mEnvFollower{1.0f};


    void deviceUpdate(const ALCdevice *device) override;
    void update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target) override;
    void process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut) override;

    DEF_NEWDEL(CompressorState)
};

void CompressorState::deviceUpdate(const ALCdevice *device)
{
    /* Number of samples to do a full attack and release (non-integer sample
     * counts are okay).
     */
    const float attackCount{static_cast<float>(device->Frequency) * ATTACK_TIME};
    const float releaseCount{static_cast<float>(device->Frequency) * RELEASE_TIME};

    /* Calculate per-sample multipliers to attack and release at the desired
     * rates.
     */
    mAttackMult  = std::pow(AMP_ENVELOPE_MAX/AMP_ENVELOPE_MIN, 1.0f/attackCount);
    mReleaseMult = std::pow(AMP_ENVELOPE_MIN/AMP_ENVELOPE_MAX, 1.0f/releaseCount);
}

void CompressorState::update(const ALCcontext*, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target)
{
    mEnabled = props->Compressor.OnOff;

    mOutTarget = target.Main->Buffer;
    auto set_gains = [slot,target](auto &gains, al::span<const float,MAX_AMBI_CHANNELS> coeffs)
    { ComputePanGains(target.Main, coeffs.data(), slot->Params.Gain, gains); };
    SetAmbiPanIdentity(std::begin(mGain), slot->Wet.Buffer.size(), set_gains);
}

void CompressorState::process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut)
{
    for(size_t base{0u};base < samplesToDo;)
    {
        float gains[256];
        const size_t td{minz(256, samplesToDo-base)};

        /* Generate the per-sample gains from the signal envelope. */
        float env{mEnvFollower};
        if(mEnabled)
        {
            for(size_t i{0u};i < td;++i)
            {
                /* Clamp the absolute amplitude to the defined envelope limits,
                 * then attack or release the envelope to reach it.
                 */
                const float amplitude{clampf(std::fabs(samplesIn[0][base+i]), AMP_ENVELOPE_MIN,
                    AMP_ENVELOPE_MAX)};
                if(amplitude > env)
                    env = minf(env*mAttackMult, amplitude);
                else if(amplitude < env)
                    env = maxf(env*mReleaseMult, amplitude);

                /* Apply the reciprocal of the envelope to normalize the volume
                 * (compress the dynamic range).
                 */
                gains[i] = 1.0f / env;
            }
        }
        else
        {
            /* Same as above, except the amplitude is forced to 1. This helps
             * ensure smooth gain changes when the compressor is turned on and
             * off.
             */
            for(size_t i{0u};i < td;++i)
            {
                const float amplitude{1.0f};
                if(amplitude > env)
                    env = minf(env*mAttackMult, amplitude);
                else if(amplitude < env)
                    env = maxf(env*mReleaseMult, amplitude);

                gains[i] = 1.0f / env;
            }
        }
        mEnvFollower = env;

        /* Now compress the signal amplitude to output. */
        auto changains = std::addressof(mGain[0]);
        for(const auto &input : samplesIn)
        {
            const float *outgains{*(changains++)};
            for(FloatBufferLine &output : samplesOut)
            {
                const float gain{*(outgains++)};
                if(!(std::fabs(gain) > GainSilenceThreshold))
                    continue;

                for(size_t i{0u};i < td;i++)
                    output[base+i] += input[base+i] * gains[i] * gain;
            }
        }

        base += td;
    }
}


void Compressor_setParami(EffectProps *props, ALenum param, int val)
{
    switch(param)
    {
    case AL_COMPRESSOR_ONOFF:
        if(!(val >= AL_COMPRESSOR_MIN_ONOFF && val <= AL_COMPRESSOR_MAX_ONOFF))
            throw effect_exception{AL_INVALID_VALUE, "Compressor state out of range"};
        props->Compressor.OnOff = (val != AL_FALSE);
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid compressor integer property 0x%04x",
            param};
    }
}
void Compressor_setParamiv(EffectProps *props, ALenum param, const int *vals)
{ Compressor_setParami(props, param, vals[0]); }
void Compressor_setParamf(EffectProps*, ALenum param, float)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid compressor float property 0x%04x", param}; }
void Compressor_setParamfv(EffectProps*, ALenum param, const float*)
{
    throw effect_exception{AL_INVALID_ENUM, "Invalid compressor float-vector property 0x%04x",
        param};
}

void Compressor_getParami(const EffectProps *props, ALenum param, int *val)
{ 
    switch(param)
    {
    case AL_COMPRESSOR_ONOFF:
        *val = props->Compressor.OnOff;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid compressor integer property 0x%04x",
            param};
    }
}
void Compressor_getParamiv(const EffectProps *props, ALenum param, int *vals)
{ Compressor_getParami(props, param, vals); }
void Compressor_getParamf(const EffectProps*, ALenum param, float*)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid compressor float property 0x%04x", param}; }
void Compressor_getParamfv(const EffectProps*, ALenum param, float*)
{
    throw effect_exception{AL_INVALID_ENUM, "Invalid compressor float-vector property 0x%04x",
        param};
}

DEFINE_ALEFFECT_VTABLE(Compressor);


struct CompressorStateFactory final : public EffectStateFactory {
    EffectState *create() override { return new CompressorState{}; }
    EffectProps getDefaultProps() const noexcept override;
    const EffectVtable *getEffectVtable() const noexcept override { return &Compressor_vtable; }
};

EffectProps CompressorStateFactory::getDefaultProps() const noexcept
{
    EffectProps props{};
    props.Compressor.OnOff = AL_COMPRESSOR_DEFAULT_ONOFF;
    return props;
}

} // namespace

EffectStateFactory *CompressorStateFactory_getFactory()
{
    static CompressorStateFactory CompressorFactory{};
    return &CompressorFactory;
}
