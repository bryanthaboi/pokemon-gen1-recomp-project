#include "config.h"

#include <cassert>

#include <limits>

#include "alcmain.h"
#include "alu.h"
#include "bsinc_defs.h"
#include "defs.h"
#include "hrtfbase.h"

struct CTag;
struct CopyTag;
struct PointTag;
struct LerpTag;
struct CubicTag;
struct BSincTag;
struct FastBSincTag;


namespace {

constexpr ALuint FracPhaseBitDiff{MixerFracBits - BSincPhaseBits};
constexpr ALuint FracPhaseDiffOne{1 << FracPhaseBitDiff};

inline float do_point(const InterpState&, const float *RESTRICT vals, const ALuint)
{ return vals[0]; }
inline float do_lerp(const InterpState&, const float *RESTRICT vals, const ALuint frac)
{ return lerp(vals[0], vals[1], static_cast<float>(frac)*(1.0f/MixerFracOne)); }
inline float do_cubic(const InterpState&, const float *RESTRICT vals, const ALuint frac)
{ return cubic(vals[0], vals[1], vals[2], vals[3], static_cast<float>(frac)*(1.0f/MixerFracOne)); }
inline float do_bsinc(const InterpState &istate, const float *RESTRICT vals, const ALuint frac)
{
    const size_t m{istate.bsinc.m};

    // Calculate the phase index and factor.
    const ALuint pi{frac >> FracPhaseBitDiff};
    const float pf{static_cast<float>(frac & (FracPhaseDiffOne-1)) * (1.0f/FracPhaseDiffOne)};

    const float *fil{istate.bsinc.filter + m*pi*4};
    const float *phd{fil + m};
    const float *scd{phd + m};
    const float *spd{scd + m};

    // Apply the scale and phase interpolated filter.
    float r{0.0f};
    for(size_t j_f{0};j_f < m;j_f++)
        r += (fil[j_f] + istate.bsinc.sf*scd[j_f] + pf*(phd[j_f] + istate.bsinc.sf*spd[j_f])) * vals[j_f];
    return r;
}
inline float do_fastbsinc(const InterpState &istate, const float *RESTRICT vals, const ALuint frac)
{
    const size_t m{istate.bsinc.m};

    // Calculate the phase index and factor.
    const ALuint pi{frac >> FracPhaseBitDiff};
    const float pf{static_cast<float>(frac & (FracPhaseDiffOne-1)) * (1.0f/FracPhaseDiffOne)};

    const float *fil{istate.bsinc.filter + m*pi*4};
    const float *phd{fil + m};

    // Apply the phase interpolated filter.
    float r{0.0f};
    for(size_t j_f{0};j_f < m;j_f++)
        r += (fil[j_f] + pf*phd[j_f]) * vals[j_f];
    return r;
}

using SamplerT = float(&)(const InterpState&, const float*RESTRICT, const ALuint);
template<SamplerT Sampler>
const float *DoResample(const InterpState *state, const float *RESTRICT src, ALuint frac,
    ALuint increment, const al::span<float> dst)
{
    const InterpState istate{*state};
    for(float &out : dst)
    {
        out = Sampler(istate, src, frac);

        frac += increment;
        src  += frac>>MixerFracBits;
        frac &= MixerFracMask;
    }
    return dst.data();
}

inline void ApplyCoeffs(float2 *RESTRICT Values, const uint_fast32_t IrSize,
    const HrirArray &Coeffs, const float left, const float right)
{
    ASSUME(IrSize >= MIN_IR_LENGTH);
    for(size_t c{0};c < IrSize;++c)
    {
        Values[c][0] += Coeffs[c][0] * left;
        Values[c][1] += Coeffs[c][1] * right;
    }
}

} // namespace

template<>
const float *Resample_<CopyTag,CTag>(const InterpState*, const float *RESTRICT src, ALuint, ALuint,
    const al::span<float> dst)
{
#if defined(HAVE_SSE) || defined(HAVE_NEON)
    /* Avoid copying the source data if it's aligned like the destination. */
    if((reinterpret_cast<intptr_t>(src)&15) == (reinterpret_cast<intptr_t>(dst.data())&15))
        return src;
#endif
    std::copy_n(src, dst.size(), dst.begin());
    return dst.data();
}

template<>
const float *Resample_<PointTag,CTag>(const InterpState *state, const float *RESTRICT src,
    ALuint frac, ALuint increment, const al::span<float> dst)
{ return DoResample<do_point>(state, src, frac, increment, dst); }

template<>
const float *Resample_<LerpTag,CTag>(const InterpState *state, const float *RESTRICT src,
    ALuint frac, ALuint increment, const al::span<float> dst)
{ return DoResample<do_lerp>(state, src, frac, increment, dst); }

template<>
const float *Resample_<CubicTag,CTag>(const InterpState *state, const float *RESTRICT src,
    ALuint frac, ALuint increment, const al::span<float> dst)
{ return DoResample<do_cubic>(state, src-1, frac, increment, dst); }

template<>
const float *Resample_<BSincTag,CTag>(const InterpState *state, const float *RESTRICT src,
    ALuint frac, ALuint increment, const al::span<float> dst)
{ return DoResample<do_bsinc>(state, src-state->bsinc.l, frac, increment, dst); }

template<>
const float *Resample_<FastBSincTag,CTag>(const InterpState *state, const float *RESTRICT src,
    ALuint frac, ALuint increment, const al::span<float> dst)
{ return DoResample<do_fastbsinc>(state, src-state->bsinc.l, frac, increment, dst); }


template<>
void MixHrtf_<CTag>(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const MixHrtfFilter *hrtfparams, const size_t BufferSize)
{ MixHrtfBase<ApplyCoeffs>(InSamples, AccumSamples, IrSize, hrtfparams, BufferSize); }

template<>
void MixHrtfBlend_<CTag>(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const HrtfFilter *oldparams, const MixHrtfFilter *newparams, const size_t BufferSize)
{
    MixHrtfBlendBase<ApplyCoeffs>(InSamples, AccumSamples, IrSize, oldparams, newparams,
        BufferSize);
}

template<>
void MixDirectHrtf_<CTag>(FloatBufferLine &LeftOut, FloatBufferLine &RightOut,
    const al::span<const FloatBufferLine> InSamples, float2 *AccumSamples, DirectHrtfState *State,
    const size_t BufferSize)
{ MixDirectHrtfBase<ApplyCoeffs>(LeftOut, RightOut, InSamples, AccumSamples, State, BufferSize); }


template<>
void Mix_<CTag>(const al::span<const float> InSamples, const al::span<FloatBufferLine> OutBuffer,
    float *CurrentGains, const float *TargetGains, const size_t Counter, const size_t OutPos)
{
    const float delta{(Counter > 0) ? 1.0f / static_cast<float>(Counter) : 0.0f};
    const auto min_len = minz(Counter, InSamples.size());
    for(FloatBufferLine &output : OutBuffer)
    {
        float *RESTRICT dst{al::assume_aligned<16>(output.data()+OutPos)};
        float gain{*CurrentGains};
        const float step{(*TargetGains-gain) * delta};

        size_t pos{0};
        if(!(std::fabs(step) > std::numeric_limits<float>::epsilon()))
            gain = *TargetGains;
        else
        {
            float step_count{0.0f};
            for(;pos != min_len;++pos)
            {
                dst[pos] += InSamples[pos] * (gain + step*step_count);
                step_count += 1.0f;
            }
            if(pos == Counter)
                gain = *TargetGains;
            else
                gain += step*step_count;
        }
        *CurrentGains = gain;
        ++CurrentGains;
        ++TargetGains;

        if(!(std::fabs(gain) > GainSilenceThreshold))
            continue;
        for(;pos != InSamples.size();++pos)
            dst[pos] += InSamples[pos] * gain;
    }
}
