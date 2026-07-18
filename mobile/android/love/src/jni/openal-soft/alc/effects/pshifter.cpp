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

#ifdef HAVE_SSE_INTRINSICS
#include <emmintrin.h>
#endif

#include <cmath>
#include <cstdlib>
#include <array>
#include <complex>
#include <algorithm>

#include "al/auxeffectslot.h"
#include "alcmain.h"
#include "alcomplex.h"
#include "alcontext.h"
#include "alnumeric.h"
#include "alu.h"


namespace {

using complex_d = std::complex<double>;

#define STFT_SIZE      1024
#define STFT_HALF_SIZE (STFT_SIZE>>1)
#define OVERSAMP       (1<<2)

#define STFT_STEP    (STFT_SIZE / OVERSAMP)
#define FIFO_LATENCY (STFT_STEP * (OVERSAMP-1))

/* Define a Hann window, used to filter the STFT input and output. */
std::array<double,STFT_SIZE> InitHannWindow()
{
    std::array<double,STFT_SIZE> ret;
    /* Create lookup table of the Hann window for the desired size, i.e. STFT_SIZE */
    for(size_t i{0};i < STFT_SIZE>>1;i++)
    {
        constexpr double scale{al::MathDefs<double>::Pi() / double{STFT_SIZE}};
        const double val{std::sin(static_cast<double>(i+1) * scale)};
        ret[i] = ret[STFT_SIZE-1-i] = val * val;
    }
    return ret;
}
alignas(16) const std::array<double,STFT_SIZE> HannWindow = InitHannWindow();


struct FrequencyBin {
    double Amplitude;
    double Frequency;
};


struct PshifterState final : public EffectState {
    /* Effect parameters */
    size_t mCount;
    ALuint mPitchShiftI;
    double mPitchShift;
    double mFreqPerBin;

    /* Effects buffers */
    std::array<double,STFT_SIZE> mFIFO;
    std::array<double,STFT_HALF_SIZE+1> mLastPhase;
    std::array<double,STFT_HALF_SIZE+1> mSumPhase;
    std::array<double,STFT_SIZE> mOutputAccum;

    std::array<complex_d,STFT_SIZE> mFftBuffer;

    std::array<FrequencyBin,STFT_HALF_SIZE+1> mAnalysisBuffer;
    std::array<FrequencyBin,STFT_HALF_SIZE+1> mSynthesisBuffer;

    alignas(16) FloatBufferLine mBufferOut;

    /* Effect gains for each output channel */
    float mCurrentGains[MAX_OUTPUT_CHANNELS];
    float mTargetGains[MAX_OUTPUT_CHANNELS];


    void deviceUpdate(const ALCdevice *device) override;
    void update(const ALCcontext *context, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target) override;
    void process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut) override;

    DEF_NEWDEL(PshifterState)
};

void PshifterState::deviceUpdate(const ALCdevice *device)
{
    /* (Re-)initializing parameters and clear the buffers. */
    mCount       = FIFO_LATENCY;
    mPitchShiftI = MixerFracOne;
    mPitchShift  = 1.0;
    mFreqPerBin  = device->Frequency / double{STFT_SIZE};

    std::fill(mFIFO.begin(),            mFIFO.end(),            0.0);
    std::fill(mLastPhase.begin(),       mLastPhase.end(),       0.0);
    std::fill(mSumPhase.begin(),        mSumPhase.end(),        0.0);
    std::fill(mOutputAccum.begin(),     mOutputAccum.end(),     0.0);
    std::fill(mFftBuffer.begin(),       mFftBuffer.end(),       complex_d{});
    std::fill(mAnalysisBuffer.begin(),  mAnalysisBuffer.end(),  FrequencyBin{});
    std::fill(mSynthesisBuffer.begin(), mSynthesisBuffer.end(), FrequencyBin{});

    std::fill(std::begin(mCurrentGains), std::end(mCurrentGains), 0.0f);
    std::fill(std::begin(mTargetGains),  std::end(mTargetGains),  0.0f);
}

void PshifterState::update(const ALCcontext*, const ALeffectslot *slot, const EffectProps *props, const EffectTarget target)
{
    const int tune{props->Pshifter.CoarseTune*100 + props->Pshifter.FineTune};
    const float pitch{std::pow(2.0f, static_cast<float>(tune) / 1200.0f)};
    mPitchShiftI = fastf2u(pitch*MixerFracOne);
    mPitchShift  = mPitchShiftI * double{1.0/MixerFracOne};

    const auto coeffs = CalcDirectionCoeffs({0.0f, 0.0f, -1.0f}, 0.0f);

    mOutTarget = target.Main->Buffer;
    ComputePanGains(target.Main, coeffs.data(), slot->Params.Gain, mTargetGains);
}

void PshifterState::process(const size_t samplesToDo, const al::span<const FloatBufferLine> samplesIn, const al::span<FloatBufferLine> samplesOut)
{
    /* Pitch shifter engine based on the work of Stephan Bernsee.
     * http://blogs.zynaptiq.com/bernsee/pitch-shifting-using-the-ft/
     */

    static constexpr double expected{al::MathDefs<double>::Tau() / OVERSAMP};
    const double freq_per_bin{mFreqPerBin};

    for(size_t base{0u};base < samplesToDo;)
    {
        const size_t todo{minz(STFT_SIZE-mCount, samplesToDo-base)};

        /* Retrieve the output samples from the FIFO and fill in the new input
         * samples.
         */
        auto fifo_iter = mFIFO.begin() + mCount;
        std::transform(fifo_iter, fifo_iter+todo, mBufferOut.begin()+base,
            [](double d) noexcept -> float { return static_cast<float>(d); });

        std::copy_n(samplesIn[0].begin()+base, todo, fifo_iter);
        mCount += todo;
        base += todo;

        /* Check whether FIFO buffer is filled with new samples. */
        if(mCount < STFT_SIZE) break;
        mCount = FIFO_LATENCY;

        /* Time-domain signal windowing, store in FftBuffer, and apply a
         * forward FFT to get the frequency-domain signal.
         */
        for(size_t k{0u};k < STFT_SIZE;k++)
            mFftBuffer[k] = mFIFO[k] * HannWindow[k];
        forward_fft(mFftBuffer);

        /* Analyze the obtained data. Since the real FFT is symmetric, only
         * STFT_HALF_SIZE+1 samples are needed.
         */
        for(size_t k{0u};k < STFT_HALF_SIZE+1;k++)
        {
            const double amplitude{std::abs(mFftBuffer[k])};
            const double phase{std::arg(mFftBuffer[k])};

            /* Compute phase difference and subtract expected phase difference */
            double tmp{(phase - mLastPhase[k]) - static_cast<double>(k)*expected};

            /* Map delta phase into +/- Pi interval */
            int qpd{double2int(tmp / al::MathDefs<double>::Pi())};
            tmp -= al::MathDefs<double>::Pi() * (qpd + (qpd%2));

            /* Get deviation from bin frequency from the +/- Pi interval */
            tmp /= expected;

            /* Compute the k-th partials' true frequency, twice the amplitude
             * for maintain the gain (because half of bins are used) and store
             * amplitude and true frequency in analysis buffer.
             */
            mAnalysisBuffer[k].Amplitude = 2.0 * amplitude;
            mAnalysisBuffer[k].Frequency = (static_cast<double>(k) + tmp) * freq_per_bin;

            /* Store the actual phase[k] for the next frame. */
            mLastPhase[k] = phase;
        }

        /* Shift the frequency bins according to the pitch adjustment,
         * accumulating the amplitudes of overlapping frequency bins.
         */
        std::fill(mSynthesisBuffer.begin(), mSynthesisBuffer.end(), FrequencyBin{});
        for(size_t k{0u};k < STFT_HALF_SIZE+1;k++)
        {
            const size_t j{(k*mPitchShiftI + (MixerFracOne>>1)) >> MixerFracBits};
            if(j >= STFT_HALF_SIZE+1) break;

            mSynthesisBuffer[j].Amplitude += mAnalysisBuffer[k].Amplitude;
            mSynthesisBuffer[j].Frequency  = mAnalysisBuffer[k].Frequency * mPitchShift;
        }

        /* Reconstruct the frequency-domain signal from the adjusted frequency
         * bins.
         */
        for(size_t k{0u};k < STFT_HALF_SIZE+1;k++)
        {
            /* Compute bin deviation from scaled freq */
            const double tmp{mSynthesisBuffer[k].Frequency / freq_per_bin};

            /* Calculate actual delta phase and accumulate it to get bin phase */
            mSumPhase[k] += tmp * expected;

            mFftBuffer[k] = std::polar(mSynthesisBuffer[k].Amplitude, mSumPhase[k]);
        }
        for(size_t k{STFT_HALF_SIZE+1};k < STFT_SIZE;++k)
            mFftBuffer[k] = std::conj(mFftBuffer[STFT_SIZE-k]);

        /* Apply an inverse FFT to get the time-domain siganl, and accumulate
         * for the output with windowing.
         */
        inverse_fft(mFftBuffer);
        for(size_t k{0u};k < STFT_SIZE;k++)
            mOutputAccum[k] += HannWindow[k]*mFftBuffer[k].real() * (2.0/STFT_SIZE/OVERSAMP);

        /* Shift FIFO and accumulator. */
        fifo_iter = std::copy(mFIFO.begin()+STFT_STEP, mFIFO.end(), mFIFO.begin());
        std::copy_n(mOutputAccum.begin(), STFT_STEP, fifo_iter);
        auto accum_iter = std::copy(mOutputAccum.begin()+STFT_STEP, mOutputAccum.end(),
            mOutputAccum.begin());
        std::fill(accum_iter, mOutputAccum.end(), 0.0);
    }

    /* Now, mix the processed sound data to the output. */
    MixSamples({mBufferOut.data(), samplesToDo}, samplesOut, mCurrentGains, mTargetGains,
        maxz(samplesToDo, 512), 0);
}


void Pshifter_setParamf(EffectProps*, ALenum param, float)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid pitch shifter float property 0x%04x", param}; }
void Pshifter_setParamfv(EffectProps*, ALenum param, const float*)
{
    throw effect_exception{AL_INVALID_ENUM, "Invalid pitch shifter float-vector property 0x%04x",
        param};
}

void Pshifter_setParami(EffectProps *props, ALenum param, int val)
{
    switch(param)
    {
    case AL_PITCH_SHIFTER_COARSE_TUNE:
        if(!(val >= AL_PITCH_SHIFTER_MIN_COARSE_TUNE && val <= AL_PITCH_SHIFTER_MAX_COARSE_TUNE))
            throw effect_exception{AL_INVALID_VALUE, "Pitch shifter coarse tune out of range"};
        props->Pshifter.CoarseTune = val;
        break;

    case AL_PITCH_SHIFTER_FINE_TUNE:
        if(!(val >= AL_PITCH_SHIFTER_MIN_FINE_TUNE && val <= AL_PITCH_SHIFTER_MAX_FINE_TUNE))
            throw effect_exception{AL_INVALID_VALUE, "Pitch shifter fine tune out of range"};
        props->Pshifter.FineTune = val;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid pitch shifter integer property 0x%04x",
            param};
    }
}
void Pshifter_setParamiv(EffectProps *props, ALenum param, const int *vals)
{ Pshifter_setParami(props, param, vals[0]); }

void Pshifter_getParami(const EffectProps *props, ALenum param, int *val)
{
    switch(param)
    {
    case AL_PITCH_SHIFTER_COARSE_TUNE:
        *val = props->Pshifter.CoarseTune;
        break;
    case AL_PITCH_SHIFTER_FINE_TUNE:
        *val = props->Pshifter.FineTune;
        break;

    default:
        throw effect_exception{AL_INVALID_ENUM, "Invalid pitch shifter integer property 0x%04x",
            param};
    }
}
void Pshifter_getParamiv(const EffectProps *props, ALenum param, int *vals)
{ Pshifter_getParami(props, param, vals); }

void Pshifter_getParamf(const EffectProps*, ALenum param, float*)
{ throw effect_exception{AL_INVALID_ENUM, "Invalid pitch shifter float property 0x%04x", param}; }
void Pshifter_getParamfv(const EffectProps*, ALenum param, float*)
{
    throw effect_exception{AL_INVALID_ENUM, "Invalid pitch shifter float vector-property 0x%04x",
        param};
}

DEFINE_ALEFFECT_VTABLE(Pshifter);


struct PshifterStateFactory final : public EffectStateFactory {
    EffectState *create() override;
    EffectProps getDefaultProps() const noexcept override;
    const EffectVtable *getEffectVtable() const noexcept override { return &Pshifter_vtable; }
};

EffectState *PshifterStateFactory::create()
{ return new PshifterState{}; }

EffectProps PshifterStateFactory::getDefaultProps() const noexcept
{
    EffectProps props{};
    props.Pshifter.CoarseTune = AL_PITCH_SHIFTER_DEFAULT_COARSE_TUNE;
    props.Pshifter.FineTune   = AL_PITCH_SHIFTER_DEFAULT_FINE_TUNE;
    return props;
}

} // namespace

EffectStateFactory *PshifterStateFactory_getFactory()
{
    static PshifterStateFactory PshifterFactory{};
    return &PshifterFactory;
}
