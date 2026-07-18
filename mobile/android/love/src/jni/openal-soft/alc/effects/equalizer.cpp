/**
 * OpenAL cross platform audio library
 * Copyright (C) 2013 by Mike Gorchak
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
#include <functional>

#include "al/auxeffectslot.h"
#include "alcmain.h"
#include "alcontext.h"
#include "alu.h"
#include "filters/biquad.h"
#include "vecmat.h"


namespace {

/*  The document  "Effects Extension Guide.pdf"  says that low and high  *
 *  frequencies are cutoff frequencies. This is not fully correct, they  *
 *  are corner frequencies for low and high shelf filters. If they were  *
 *  just cutoff frequencies, there would be no need in cutoff frequency  *
 *  gains, which are present.  Documentation for  "Creative Proteus X2"  *
 *  software describes  4-band equalizer functionality in a much better  *
 *  way.  This equalizer seems  to be a predecessor  of  OpenAL  4-band  *
 *  equalizer.  With low and high  shelf filters  we are able to cutoff  *
 *  frequencies below and/or above corner frequencies using attenuation  *
 *  gains (below 1.0) and amplify all low and/or high frequencies using  *
 *  gains above 1.0.                                                     *
 *                                                                       *
 *     Low-shelf       Low Mid Band      High Mid Band     High-shelf    *
 *      corner            center             center          corner      *
 *     frequency        frequency          frequency       frequency     *
 *    50Hz..800Hz     200Hz..3000Hz      1000Hz..8000Hz  4000Hz..16000Hz *
 *                                                                       *
 *          |               |                  |               |         *
 *          |               |                  |               |         *
 *   B -----+            /--+--\            /--+--\            +-----    *
 *   O      |\          |   |   |          |   |   |          /|         *
 *   O      | \        -    |    -        -    |    -        / |         *
 *   S +    |  \      |     |     |      |     |     |      /  |         *
 *   T      |   |    |      |      |    |      |      |    |   |         *
 * ---------+---------------+------------------+---------------+-------- *
 *   C      |   |    |      |      |    |      |      |    |   |         *
 *   U -    |  /      |     |     |      |     |     |      \  |         *
 *   T      | /        -    |    -        -    |    -        \ |         *
 *   O      |/          |   |   |          |   |   |          \|         *
 *   F -----+            \--+--/            \--+--/            +-----    *
 *   F      |               |                  |               |         *
 *          |               |                  |               |         *
 *                                                                       *
 * Gains vary from 0.126 up to 7.943, which means from -18dB attenuation *
 * up to +18dB amplification. Band width varies from 0.01 up to 1.0 in   *
 * octaves for two mid bands.                                            *
 *                                                                       *
 * Implementation is based on the "Cookbook formulae for audio EQ biquad *
 * filter coefficients" by Robert Bristow-Johnson                        *
 * http://www.musicdsp.org/files/Audio-EQ-Cookbook.txt                   */


struct EqualizerState final : public EffectState {
    struct {
        /* Effect parameters */
        BiquadFilter filter[4];

        /* Effect gains for each channel */
        float CurrentGains[MAX_OUTPUT_CHANNELS]{};
        float TargetGains[MAX_OUTPUT_CHANNELS]{};
    } mChans[MAX_AMBI_CHANNELS];

    FloatBufferLine mSampleBuffer{};


    void deviceUpdate(const ALCdevice *device) override;
    void update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target) override;
    void process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut) override;

    DEF_NEWDEL(EqualizerState)
};

void EqualizerState::deviceUpdate(const ALCdevice*)
{
    for(auto &e : mChans)
    {
        std::for_each(std::begin(e.filter), std::end(e.filter), std::mem_fn(&BiquadFilter::clear));
        std::fill(std::begin(e.CurrentGains), std::end(e.CurrentGains), 0.0f);
    }
}

void EqualizerState::update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target)
{
    const ALCdevice *device{context->mDevice.get()};
    auto frequency = static_cast<float>(device->Frequency);
    float gain, f0norm;

    /* Calculate coefficients for the each type of filter. Note that the shelf
     * and peaking filters' gain is for the centerpoint of the transition band,
     * while the effect property gains are for the shelf/peak itself. So the
     * property gains need their dB halved (sqrt of linear gain) for the
     * shelf/peak to reach the provided gain.
     */
    gain = std::sqrt(props->Equalizer.LowGain);
    f0norm = props->Equalizer.LowCutoff / frequency;
    mChans[0].filter[0].setParamsFromSlope(BiquadType::LowShelf, f0norm, gain, 0.75f);

    gain = std::sqrt(props->Equalizer.Mid1Gain);
    f0norm = props->Equalizer.Mid1Center / frequency;
    mChans[0].filter[1].setParamsFromBandwidth(BiquadType::Peaking, f0norm, gain,
        props->Equalizer.Mid1Width);

    gain = std::sqrt(props->Equalizer.Mid2Gain);
    f0norm = props->Equalizer.Mid2Center / frequency;
    mChans[0].filter[2].setParamsFromBandwidth(BiquadType::Peaking, f0norm, gain,
        props->Equalizer.Mid2Width);

    gain = std::sqrt(props->Equalizer.HighGain);
    f0norm = props->Equalizer.HighCutoff / frequency;
    mChans[0].filter[3].setParamsFromSlope(BiquadType::HighShelf, f0norm, gain, 0.75f);

    /* Copy the filter coefficients for the other input channels. */
    for(size_t i{1u};i < slot->Wet.Buffer.size();++i)
    {
        mChans[i].filter[0].copyParamsFrom(mChans[0].filter[0]);
        mChans[i].filter[1].copyParamsFrom(mChans[0].filter[1]);
        mChans[i].filter[2].copyParamsFrom(mChans[0].filter[2]);
        mChans[i].filter[3].copyParamsFrom(mChans[0].filter[3]);
    }

    mOutTarget = target.Main->Buffer;
    auto set_gains = [slot,target](auto &chan, al::span<const float,MAX_AMBI_CHANNELS> coeffs)
    { ComputePanGains(target.Main, coeffs.data(), slot->Params.Gain, chan.TargetGains); };
    SetAmbiPanIdentity(std::begin(mChans), slot->Wet.Buffer.size(), set_gains);
}

void EqualizerState::process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut)
{
    const al::span<float> buffer{mSampleBuffer.data(), samplesToDo};
    auto chan = std::addressof(mChans[0]);
    for(const auto &input : samplesIn)
    {
        const al::span<const float> inbuf{input.data(), samplesToDo};
        DualBiquad{chan->filter[0], chan->filter[1]}.process(inbuf, buffer.begin());
        DualBiquad{chan->filter[2], chan->filter[3]}.process(buffer, buffer.begin());

        MixSamples(buffer, samplesOut, chan->CurrentGains, chan->TargetGains, samplesToDo, 0u);
        ++chan;
    }
}


void Equalizer_setParami(EffectProps*, ALenum param, int)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid equalizer integer property 0x%04x", param}; }
void Equalizer_setParamiv(EffectProps*, ALenum param, const int*)
{
    throw effect_exception{AL_INVALID_ENUM, "Invalid equalizer integer-vector property 0x%04x",
        param};
}
void Equalizer_setParamf(EffectProps *props, ALenum param, float val)
{
    switch(param)
    {
    case AL_EQUALIZER_LOW_GAIN:
        if(!(val >= AL_EQUALIZER_MIN_LOW_GAIN && val <= AL_EQUALIZER_MAX_LOW_GAIN))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer low-band gain out of range"};
        props->Equalizer.LowGain = val;
        break;

    case AL_EQUALIZER_LOW_CUTOFF:
        if(!(val >= AL_EQUALIZER_MIN_LOW_CUTOFF && val <= AL_EQUALIZER_MAX_LOW_CUTOFF))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer low-band cutoff out of range"};
        props->Equalizer.LowCutoff = val;
        break;

    case AL_EQUALIZER_MID1_GAIN:
        if(!(val >= AL_EQUALIZER_MIN_MID1_GAIN && val <= AL_EQUALIZER_MAX_MID1_GAIN))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer mid1-band gain out of range"};
        props->Equalizer.Mid1Gain = val;
        break;

    case AL_EQUALIZER_MID1_CENTER:
        if(!(val >= AL_EQUALIZER_MIN_MID1_CENTER && val <= AL_EQUALIZER_MAX_MID1_CENTER))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer mid1-band center out of range"};
        props->Equalizer.Mid1Center = val;
        break;

    case AL_EQUALIZER_MID1_WIDTH:
        if(!(val >= AL_EQUALIZER_MIN_MID1_WIDTH && val <= AL_EQUALIZER_MAX_MID1_WIDTH))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer mid1-band width out of range"};
        props->Equalizer.Mid1Width = val;
        break;

    case AL_EQUALIZER_MID2_GAIN:
        if(!(val >= AL_EQUALIZER_MIN_MID2_GAIN && val <= AL_EQUALIZER_MAX_MID2_GAIN))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer mid2-band gain out of range"};
        props->Equalizer.Mid2Gain = val;
        break;

    case AL_EQUALIZER_MID2_CENTER:
        if(!(val >= AL_EQUALIZER_MIN_MID2_CENTER && val <= AL_EQUALIZER_MAX_MID2_CENTER))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer mid2-band center out of range"};
        props->Equalizer.Mid2Center = val;
        break;

    case AL_EQUALIZER_MID2_WIDTH:
        if(!(val >= AL_EQUALIZER_MIN_MID2_WIDTH && val <= AL_EQUALIZER_MAX_MID2_WIDTH))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer mid2-band width out of range"};
        props->Equalizer.Mid2Width = val;
        break;

    case AL_EQUALIZER_HIGH_GAIN:
        if(!(val >= AL_EQUALIZER_MIN_HIGH_GAIN && val <= AL_EQUALIZER_MAX_HIGH_GAIN))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer high-band gain out of range"};
        props->Equalizer.HighGain = val;
        break;

    case AL_EQUALIZER_HIGH_CUTOFF:
        if(!(val >= AL_EQUALIZER_MIN_HIGH_CUTOFF && val <= AL_EQUALIZER_MAX_HIGH_CUTOFF))
            throw effect_exception{AL_INVALID_VALUE, "Equalizer high-band cutoff out of range"};
        props->Equalizer.HighCutoff = val;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid equalizer float property 0x%04x", param};
    }
}
void Equalizer_setParamfv(EffectProps *props, ALenum param, const float *vals)
{ Equalizer_setParamf(props, param, vals[0]); }

void Equalizer_getParami(const EffectProps*, ALenum param, int*)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid equalizer integer property 0x%04x", param}; }
void Equalizer_getParamiv(const EffectProps*, ALenum param, int*)
{
    throw effect_exception{AL_INVALID_ENUM, "Invalid equalizer integer-vector property 0x%04x",
        param};
}
void Equalizer_getParamf(const EffectProps *props, ALenum param, float *val)
{
    switch(param)
    {
    case AL_EQUALIZER_LOW_GAIN:
        *val = props->Equalizer.LowGain;
        break;

    case AL_EQUALIZER_LOW_CUTOFF:
        *val = props->Equalizer.LowCutoff;
        break;

    case AL_EQUALIZER_MID1_GAIN:
        *val = props->Equalizer.Mid1Gain;
        break;

    case AL_EQUALIZER_MID1_CENTER:
        *val = props->Equalizer.Mid1Center;
        break;

    case AL_EQUALIZER_MID1_WIDTH:
        *val = props->Equalizer.Mid1Width;
        break;

    case AL_EQUALIZER_MID2_GAIN:
        *val = props->Equalizer.Mid2Gain;
        break;

    case AL_EQUALIZER_MID2_CENTER:
        *val = props->Equalizer.Mid2Center;
        break;

    case AL_EQUALIZER_MID2_WIDTH:
        *val = props->Equalizer.Mid2Width;
        break;

    case AL_EQUALIZER_HIGH_GAIN:
        *val = props->Equalizer.HighGain;
        break;

    case AL_EQUALIZER_HIGH_CUTOFF:
        *val = props->Equalizer.HighCutoff;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid equalizer float property 0x%04x", param};
    }
}
void Equalizer_getParamfv(const EffectProps *props, ALenum param, float *vals)
{ Equalizer_getParamf(props, param, vals); }

DEFINE_ALEFFECT_VTABLE(Equalizer);


struct EqualizerStateFactory final : public EffectStateFactory {
    EffectState *create() override { return new EqualizerState{}; }
    EffectProps getDefaultProps() const noexcept override;
    const EffectVtable *getEffectVtable() const noexcept override { return &Equalizer_vtable; }
};

EffectProps EqualizerStateFactory::getDefaultProps() const noexcept
{
    EffectProps props{};
    props.Equalizer.LowCutoff = AL_EQUALIZER_DEFAULT_LOW_CUTOFF;
    props.Equalizer.LowGain = AL_EQUALIZER_DEFAULT_LOW_GAIN;
    props.Equalizer.Mid1Center = AL_EQUALIZER_DEFAULT_MID1_CENTER;
    props.Equalizer.Mid1Gain = AL_EQUALIZER_DEFAULT_MID1_GAIN;
    props.Equalizer.Mid1Width = AL_EQUALIZER_DEFAULT_MID1_WIDTH;
    props.Equalizer.Mid2Center = AL_EQUALIZER_DEFAULT_MID2_CENTER;
    props.Equalizer.Mid2Gain = AL_EQUALIZER_DEFAULT_MID2_GAIN;
    props.Equalizer.Mid2Width = AL_EQUALIZER_DEFAULT_MID2_WIDTH;
    props.Equalizer.HighCutoff = AL_EQUALIZER_DEFAULT_HIGH_CUTOFF;
    props.Equalizer.HighGain = AL_EQUALIZER_DEFAULT_HIGH_GAIN;
    return props;
}

} // namespace

EffectStateFactory *EqualizerStateFactory_getFactory()
{
    static EqualizerStateFactory EqualizerFactory{};
    return &EqualizerFactory;
}
