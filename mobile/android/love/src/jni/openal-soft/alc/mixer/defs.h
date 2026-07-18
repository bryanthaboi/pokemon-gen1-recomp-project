#ifndef MIXER_DEFS_H
#define MIXER_DEFS_H

#include "AL/al.h"

#include "alcmain.h"
#include "alspan.h"
#include "alu.h"
#include "hrtf.h"

union InterpState;
struct MixHrtfFilter;


template<typename TypeTag, typename InstTag>
const float *Resample_(const InterpState *state, const float *RESTRICT src, ALuint frac,
    ALuint increment, const al::span<float> dst);

template<typename InstTag>
void Mix_(const al::span<const float> InSamples, const al::span<FloatBufferLine> OutBuffer,
    float *CurrentGains, const float *TargetGains, const size_t Counter, const size_t OutPos);

template<typename InstTag>
void MixHrtf_(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const MixHrtfFilter *hrtfparams, const size_t BufferSize);
template<typename InstTag>
void MixHrtfBlend_(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const HrtfFilter *oldparams, const MixHrtfFilter *newparams, const size_t BufferSize);
template<typename InstTag>
void MixDirectHrtf_(FloatBufferLine &LeftOut, FloatBufferLine &RightOut,
    const al::span<const FloatBufferLine> InSamples, float2 *AccumSamples, DirectHrtfState *State,
    const size_t BufferSize);

/* Vectorized resampler helpers */
inline void InitPosArrays(ALuint frac, ALuint increment, ALuint *frac_arr, ALuint *pos_arr,
    size_t size)
{
    pos_arr[0] = 0;
    frac_arr[0] = frac;
    for(size_t i{1};i < size;i++)
    {
        const ALuint frac_tmp{frac_arr[i-1] + increment};
        pos_arr[i] = pos_arr[i-1] + (frac_tmp>>MixerFracBits);
        frac_arr[i] = frac_tmp&MixerFracMask;
    }
}

#endif /* MIXER_DEFS_H */
