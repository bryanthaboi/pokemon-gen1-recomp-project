/**
 * OpenAL cross platform audio library
 * Copyright (C) 2018 by Raul Herraiz.
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
#include <array>
#include <complex>
#include <algorithm>

#include "al/auxeffectslot.h"
#include "alcmain.h"
#include "alcontext.h"
#include "alu.h"

#include "alcomplex.h"

namespace {

using complex_d = std::complex<double>;

#define HIL_SIZE 1024
#define OVERSAMP (1<<2)

#define HIL_STEP     (HIL_SIZE / OVERSAMP)
#define FIFO_LATENCY (HIL_STEP * (OVERSAMP-1))

/* Define a Hann window, used to filter the HIL input and output. */
std::array<double,HIL_SIZE> InitHannWindow()
{
    std::array<double,HIL_SIZE> ret;
    /* Create lookup table of the Hann window for the desired size, i.e. HIL_SIZE */
    for(size_t i{0};i < HIL_SIZE>>1;i++)
    {
        constexpr double scale{al::MathDefs<double>::Pi() / double{HIL_SIZE}};
        const double val{std::sin(static_cast<double>(i+1) * scale)};
        ret[i] = ret[HIL_SIZE-1-i] = val * val;
    }
    return ret;
}
alignas(16) const std::array<double,HIL_SIZE> HannWindow = InitHannWindow();


struct FshifterState final : public EffectState {
    /* Effect parameters */
    size_t mCount{};
    ALuint mPhaseStep[2]{};
    ALuint mPhase[2]{};
    double mSign[2]{};

    /* Effects buffers */
    double mInFIFO[HIL_SIZE]{};
    complex_d mOutFIFO[HIL_STEP]{};
    complex_d mOutputAccum[HIL_SIZE]{};
    complex_d mAnalytic[HIL_SIZE]{};
    complex_d mOutdata[BUFFERSIZE]{};

    alignas(16) float mBufferOut[BUFFERSIZE]{};

    /* Effect gains for each output channel */
    struct {
        float Current[MAX_OUTPUT_CHANNELS]{};
        float Target[MAX_OUTPUT_CHANNELS]{};
    } mGains[2];


    void deviceUpdate(const ALCdevice *device) override;
    void update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target) override;
    void process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut) override;

    DEF_NEWDEL(FshifterState)
};

void FshifterState::deviceUpdate(const ALCdevice*)
{
    /* (Re-)initializing parameters and clear the buffers. */
    mCount = FIFO_LATENCY;

    std::fill(std::begin(mPhaseStep),   std::end(mPhaseStep),   0u);
    std::fill(std::begin(mPhase),       std::end(mPhase),       0u);
    std::fill(std::begin(mSign),        std::end(mSign),        1.0);
    std::fill(std::begin(mInFIFO),      std::end(mInFIFO),      0.0);
    std::fill(std::begin(mOutFIFO),     std::end(mOutFIFO),     complex_d{});
    std::fill(std::begin(mOutputAccum), std::end(mOutputAccum), complex_d{});
    std::fill(std::begin(mAnalytic),    std::end(mAnalytic),    complex_d{});

    for(auto &gain : mGains)
    {
        std::fill(std::begin(gain.Current), std::end(gain.Current), 0.0f);
        std::fill(std::begin(gain.Target), std::end(gain.Target), 0.0f);
    }
}

void FshifterState::update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target)
{
    const ALCdevice *device{context->mDevice.get()};

    const float step{props->Fshifter.Frequency / static_cast<float>(device->Frequency)};
    mPhaseStep[0] = mPhaseStep[1] = fastf2u(minf(step, 1.0f) * MixerFracOne);

    switch(props->Fshifter.LeftDirection)
    {
    case AL_FREQUENCY_SHIFTER_DIRECTION_DOWN:
        mSign[0] = -1.0;
        break;

    case AL_FREQUENCY_SHIFTER_DIRECTION_UP:
        mSign[0] = 1.0;
        break;

    case AL_FREQUENCY_SHIFTER_DIRECTION_OFF:
        mPhase[0]     = 0;
        mPhaseStep[0] = 0;
        break;
    }

    switch(props->Fshifter.RightDirection)
    {
    case AL_FREQUENCY_SHIFTER_DIRECTION_DOWN:
        mSign[1] = -1.0;
        break;

    case AL_FREQUENCY_SHIFTER_DIRECTION_UP:
        mSign[1] = 1.0;
        break;

    case AL_FREQUENCY_SHIFTER_DIRECTION_OFF:
        mPhase[1]     = 0;
        mPhaseStep[1] = 0;
        break;
    }

    const auto lcoeffs = CalcDirectionCoeffs({-1.0f, 0.0f, 0.0f}, 0.0f);
    const auto rcoeffs = CalcDirectionCoeffs({ 1.0f, 0.0f, 0.0f}, 0.0f);

    mOutTarget = target.Main->Buffer;
    ComputePanGains(target.Main, lcoeffs.data(), slot->Params.Gain, mGains[0].Target);
    ComputePanGains(target.Main, rcoeffs.data(), slot->Params.Gain, mGains[1].Target);
}

void FshifterState::process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut)
{
    for(size_t base{0u};base < samplesToDo;)
    {
        size_t todo{minz(HIL_SIZE-mCount, samplesToDo-base)};

        /* Fill FIFO buffer with samples data */
        size_t count{mCount};
        do {
            mInFIFO[count] = samplesIn[0][base];
            mOutdata[base] = mOutFIFO[count-FIFO_LATENCY];
            ++base; ++count;
        } while(--todo);
        mCount = count;

        /* Check whether FIFO buffer is filled */
        if(mCount < HIL_SIZE) break;
        mCount = FIFO_LATENCY;

        /* Real signal windowing and store in Analytic buffer */
        for(size_t k{0};k < HIL_SIZE;k++)
            mAnalytic[k] = mInFIFO[k]*HannWindow[k];

        /* Processing signal by Discrete Hilbert Transform (analytical signal). */
        complex_hilbert(mAnalytic);

        /* Windowing and add to output accumulator */
        for(size_t k{0};k < HIL_SIZE;k++)
            mOutputAccum[k] += 2.0/OVERSAMP*HannWindow[k]*mAnalytic[k];

        /* Shift accumulator, input & output FIFO */
        std::copy_n(mOutputAccum, HIL_STEP, mOutFIFO);
        auto accum_iter = std::copy(std::begin(mOutputAccum)+HIL_STEP, std::end(mOutputAccum),
            std::begin(mOutputAccum));
        std::fill(accum_iter, std::end(mOutputAccum), complex_d{});
        std::copy(std::begin(mInFIFO)+HIL_STEP, std::end(mInFIFO), std::begin(mInFIFO));
    }

    /* Process frequency shifter using the analytic signal obtained. */
    float *RESTRICT BufferOut{mBufferOut};
    for(ALsizei c{0};c < 2;++c)
    {
        const ALuint phase_step{mPhaseStep[c]};
        ALuint phase_idx{mPhase[c]};
        for(size_t k{0};k < samplesToDo;++k)
        {
            const double phase{phase_idx * ((1.0/MixerFracOne) * al::MathDefs<double>::Tau())};
            BufferOut[k] = static_cast<float>(mOutdata[k].real()*std::cos(phase) +
                mOutdata[k].imag()*std::sin(phase)*mSign[c]);

            phase_idx += phase_step;
            phase_idx &= MixerFracMask;
        }
        mPhase[c] = phase_idx;

        /* Now, mix the processed sound data to the output. */
        MixSamples({BufferOut, samplesToDo}, samplesOut, mGains[c].Current, mGains[c].Target,
            maxz(samplesToDo, 512), 0);
    }
}


void Fshifter_setParamf(EffectProps *props, ALenum param, float val)
{
    switch(param)
    {
    case AL_FREQUENCY_SHIFTER_FREQUENCY:
        if(!(val >= AL_FREQUENCY_SHIFTER_MIN_FREQUENCY && val <= AL_FREQUENCY_SHIFTER_MAX_FREQUENCY))
            throw effect_exception{AL_INVALID_VALUE, "Frequency shifter frequency out of range"};
        props->Fshifter.Frequency = val;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid frequency shifter float property 0x%04x",
            param};
    }
}
void Fshifter_setParamfv(EffectProps *props, ALenum param, const float *vals)
{ Fshifter_setParamf(props, param, vals[0]); }

void Fshifter_setParami(EffectProps *props, ALenum param, int val)
{
    switch(param)
    {
    case AL_FREQUENCY_SHIFTER_LEFT_DIRECTION:
        if(!(val >= AL_FREQUENCY_SHIFTER_MIN_LEFT_DIRECTION && val <= AL_FREQUENCY_SHIFTER_MAX_LEFT_DIRECTION))
            throw effect_exception{AL_INVALID_VALUE,
                "Frequency shifter left direction out of range"};
        props->Fshifter.LeftDirection = val;
        break;

    case AL_FREQUENCY_SHIFTER_RIGHT_DIRECTION:
        if(!(val >= AL_FREQUENCY_SHIFTER_MIN_RIGHT_DIRECTION && val <= AL_FREQUENCY_SHIFTER_MAX_RIGHT_DIRECTION))
            throw effect_exception{AL_INVALID_VALUE,
                "Frequency shifter right direction out of range"};
        props->Fshifter.RightDirection = val;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM,
            "Invalid frequency shifter integer property 0x%04x", param};
    }
}
void Fshifter_setParamiv(EffectProps *props, ALenum param, const int *vals)
{ Fshifter_setParami(props, param, vals[0]); }

void Fshifter_getParami(const EffectProps *props, ALenum param, int *val)
{
    switch(param)
    {
    case AL_FREQUENCY_SHIFTER_LEFT_DIRECTION:
        *val = props->Fshifter.LeftDirection;
        break;
    case AL_FREQUENCY_SHIFTER_RIGHT_DIRECTION:
        *val = props->Fshifter.RightDirection;
        break;
    default:
        throw effect_exception{AL_INVALID_ENUM,
            "Invalid frequency shifter integer property 0x%04x", param};
    }
}
void Fshifter_getParamiv(const EffectProps *props, ALenum param, int *vals)
{ Fshifter_getParami(props, param, vals); }

void Fshifter_getParamf(const EffectProps *props, ALenum param, float *val)
{
    switch(param)
    {
    case AL_FREQUENCY_SHIFTER_FREQUENCY:
        *val = props->Fshifter.Frequency;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid frequency shifter float property 0x%04x",
            param};
    }
}
void Fshifter_getParamfv(const EffectProps *props, ALenum param, float *vals)
{ Fshifter_getParamf(props, param, vals); }

DEFINE_ALEFFECT_VTABLE(Fshifter);


struct FshifterStateFactory final : public EffectStateFactory {
    EffectState *create() override { return new FshifterState{}; }
    EffectProps getDefaultProps() const noexcept override;
    const EffectVtable *getEffectVtable() const noexcept override { return &Fshifter_vtable; }
};

EffectProps FshifterStateFactory::getDefaultProps() const noexcept
{
    EffectProps props{};
    props.Fshifter.Frequency      = AL_FREQUENCY_SHIFTER_DEFAULT_FREQUENCY;
    props.Fshifter.LeftDirection  = AL_FREQUENCY_SHIFTER_DEFAULT_LEFT_DIRECTION;
    props.Fshifter.RightDirection = AL_FREQUENCY_SHIFTER_DEFAULT_RIGHT_DIRECTION;
    return props;
}

} // namespace

EffectStateFactory *FshifterStateFactory_getFactory()
{
    static FshifterStateFactory FshifterFactory{};
    return &FshifterFactory;
}
