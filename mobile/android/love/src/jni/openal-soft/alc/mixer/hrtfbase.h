#ifndef MIXER_HRTFBASE_H
#define MIXER_HRTFBASE_H

#include <algorithm>

#include "alu.h"
#include "../hrtf.h"
#include "opthelpers.h"
#include "voice.h"


using ApplyCoeffsT = void(&)(float2 *RESTRICT Values, const uint_fast32_t irSize,
    const HrirArray &Coeffs, const float left, const float right);

template<ApplyCoeffsT ApplyCoeffs>
inline void MixHrtfBase(const float *InSamples, float2 *RESTRICT AccumSamples, const ALuint IrSize,
    const MixHrtfFilter *hrtfparams, const size_t BufferSize)
{
    ASSUME(BufferSize > 0);

    const HrirArray &Coeffs = *hrtfparams->Coeffs;
    const float gainstep{hrtfparams->GainStep};
    const float gain{hrtfparams->Gain};

    size_t ldelay{HRTF_HISTORY_LENGTH - hrtfparams->Delay[0]};
    size_t rdelay{HRTF_HISTORY_LENGTH - hrtfparams->Delay[1]};
    float stepcount{0.0f};
    for(size_t i{0u};i < BufferSize;++i)
    {
        const float g{gain + gainstep*stepcount};
        const float left{InSamples[ldelay++] * g};
        const float right{InSamples[rdelay++] * g};
        ApplyCoeffs(AccumSamples+i, IrSize, Coeffs, left, right);

        stepcount += 1.0f;
    }
}

template<ApplyCoeffsT ApplyCoeffs>
inline void MixHrtfBlendBase(const float *InSamples, float2 *RESTRICT AccumSamples,
    const ALuint IrSize, const HrtfFilter *oldparams, const MixHrtfFilter *newparams,
    const size_t BufferSize)
{
    ASSUME(BufferSize > 0);

    const auto &OldCoeffs = oldparams->Coeffs;
    const float oldGainStep{oldparams->Gain / static_cast<float>(BufferSize)};
    const auto &NewCoeffs = *newparams->Coeffs;
    const float newGainStep{newparams->GainStep};

    if LIKELY(oldparams->Gain > GainSilenceThreshold)
    {
        size_t ldelay{HRTF_HISTORY_LENGTH - oldparams->Delay[0]};
        size_t rdelay{HRTF_HISTORY_LENGTH - oldparams->Delay[1]};
        auto stepcount = static_cast<float>(BufferSize);
        for(size_t i{0u};i < BufferSize;++i)
        {
            const float g{oldGainStep*stepcount};
            const float left{InSamples[ldelay++] * g};
            const float right{InSamples[rdelay++] * g};
            ApplyCoeffs(AccumSamples+i, IrSize, OldCoeffs, left, right);

            stepcount -= 1.0f;
        }
    }

    if LIKELY(newGainStep*static_cast<float>(BufferSize) > GainSilenceThreshold)
    {
        size_t ldelay{HRTF_HISTORY_LENGTH+1 - newparams->Delay[0]};
        size_t rdelay{HRTF_HISTORY_LENGTH+1 - newparams->Delay[1]};
        float stepcount{1.0f};
        for(size_t i{1u};i < BufferSize;++i)
        {
            const float g{newGainStep*stepcount};
            const float left{InSamples[ldelay++] * g};
            const float right{InSamples[rdelay++] * g};
            ApplyCoeffs(AccumSamples+i, IrSize, NewCoeffs, left, right);

            stepcount += 1.0f;
        }
    }
}

template<ApplyCoeffsT ApplyCoeffs>
inline void MixDirectHrtfBase(FloatBufferLine &LeftOut, FloatBufferLine &RightOut,
    const al::span<const FloatBufferLine> InSamples, float2 *RESTRICT AccumSamples,
    DirectHrtfState *State, const size_t BufferSize)
{
    ASSUME(BufferSize > 0);

    /* Add the existing signal directly to the accumulation buffer, unfiltered,
     * and with a delay to align with the input delay.
     */
    for(size_t i{0};i < BufferSize;++i)
    {
        AccumSamples[HRTF_DIRECT_DELAY+i][0] += LeftOut[i];
        AccumSamples[HRTF_DIRECT_DELAY+i][1] += RightOut[i];
    }

    const uint_fast32_t IrSize{State->mIrSize};
    auto chan_iter = State->mChannels.begin();
    for(const FloatBufferLine &input : InSamples)
    {
        /* For dual-band processing, the signal needs extra scaling applied to
         * the high frequency response. The band-splitter alone creates a
         * frequency-dependent phase shift, which is not ideal. To counteract
         * it, combine it with a backwards phase shift.
         */

        /* Load the input signal backwards, into a temp buffer with delay
         * padding. The delay serves to reduce the error caused by the IIR
         * filter's phase shift on a partial input.
         */
        al::span<float> tempbuf{al::assume_aligned<16>(State->mTemp.data()),
            HRTF_DIRECT_DELAY+BufferSize};
        auto tmpiter = std::reverse_copy(input.begin(), input.begin()+BufferSize, tempbuf.begin());
        std::copy(chan_iter->mDelay.cbegin(), chan_iter->mDelay.cend(), tmpiter);

        /* Save the unfiltered newest input samples for next time. */
        std::copy_n(tempbuf.begin(), chan_iter->mDelay.size(), chan_iter->mDelay.begin());

        /* Apply the all-pass on the reversed signal and reverse the resulting
         * sample array. This produces the forward response with a backwards
         * phase shift (+n degrees becomes -n degrees).
         */
        chan_iter->mSplitter.applyAllpass(tempbuf);
        tempbuf = tempbuf.subspan<HRTF_DIRECT_DELAY>();
        std::reverse(tempbuf.begin(), tempbuf.end());

        /* Now apply the HF scale with the band-splitter. This applies the
         * forward phase shift, which cancels out with the backwards phase
         * shift to get the original phase on the scaled signal.
         */
        chan_iter->mSplitter.processHfScale(tempbuf, chan_iter->mHfScale);

        /* Now apply the HRIR coefficients to this channel. */
        const auto &Coeffs = chan_iter->mCoeffs;
        for(size_t i{0u};i < BufferSize;++i)
        {
            const float insample{tempbuf[i]};
            ApplyCoeffs(AccumSamples+i, IrSize, Coeffs, insample, insample);
        }

        ++chan_iter;
    }

    for(size_t i{0u};i < BufferSize;++i)
        LeftOut[i]  = AccumSamples[i][0];
    for(size_t i{0u};i < BufferSize;++i)
        RightOut[i] = AccumSamples[i][1];

    /* Copy the new in-progress accumulation values to the front and clear the
     * following samples for the next mix.
     */
    auto accum_iter = std::copy_n(AccumSamples+BufferSize, HRIR_LENGTH+HRTF_DIRECT_DELAY,
        AccumSamples);
    std::fill_n(accum_iter, BufferSize, float2{});
}

#endif /* MIXER_HRTFBASE_H */
