#include "config.h"

#include <arm_neon.h>

#include <limits>

#include "AL/al.h"
#include "AL/alc.h"
#include "alcmain.h"
#include "alu.h"
#include "hrtf.h"
#include "defs.h"
#include "bsinc_defs.h"
#include "hrtfbase.h"

struct NEONTag;
struct LerpTag;
struct BSincTag;
struct FastBSincTag;


namespace {

constexpr ALuint FracPhaseBitDiff{MixerFracBits - BSincPhaseBits};
constexpr ALuint FracPhaseDiffOne{1 << FracPhaseBitDiff};

inline void ApplyCoeffs(float2 *RESTRICT Values, const uint_fast32_t IrSize,
    const HrirArray &Coeffs, const float left, const float right)
{
    float32x4_t leftright4;
    {
        float32x2_t leftright2 = vdup_n_f32(0.0);
        leftright2 = vset_lane_f32(left, leftright2, 0);
        leftright2 = vset_lane_f32(right, leftright2, 1);
        leftright4 = vcombine_f32(leftright2, leftright2);
    }

    ASSUME(IrSize >= MIN_IR_LENGTH);
    for(size_t c{0};c < IrSize;c += 2)
    {
        float32x4_t vals = vld1q_f32(&Values[c][0]);
        float32x4_t coefs = vld1q_f32(&Coeffs[c][0]);

        vals = vmlaq_f32(vals, coefs, leftright4);

        vst1q_f32(&Values[c][0], vals);
    }
}

} // namespace

template<>
const float *Resample_<LerpTag,NEONTag>(const InterpState*, const float *RESTRICT src, ALuint frac,
    ALuint increment, const al::span<float> dst)
{
    const int32x4_t increment4 = vdupq_n_s32(static_cast<int>(increment*4));
    const float32x4_t fracOne4 = vdupq_n_f32(1.0f/MixerFracOne);
    const int32x4_t fracMask4 = vdupq_n_s32(MixerFracMask);
    alignas(16) ALuint pos_[4], frac_[4];
    int32x4_t pos4, frac4;

    InitPosArrays(frac, increment, frac_, pos_, 4);
    frac4 = vld1q_s32(reinterpret_cast<int*>(frac_));
    pos4 = vld1q_s32(reinterpret_cast<int*>(pos_));

    auto dst_iter = dst.begin();
    for(size_t todo{dst.size()>>2};todo;--todo)
    {
        const int pos0{vgetq_lane_s32(pos4, 0)};
        const int pos1{vgetq_lane_s32(pos4, 1)};
        const int pos2{vgetq_lane_s32(pos4, 2)};
        const int pos3{vgetq_lane_s32(pos4, 3)};
        const float32x4_t val1{src[pos0], src[pos1], src[pos2], src[pos3]};
        const float32x4_t val2{src[pos0+1], src[pos1+1], src[pos2+1], src[pos3+1]};

        /* val1 + (val2-val1)*mu */
        const float32x4_t r0{vsubq_f32(val2, val1)};
        const float32x4_t mu{vmulq_f32(vcvtq_f32_s32(frac4), fracOne4)};
        const float32x4_t out{vmlaq_f32(val1, mu, r0)};

        vst1q_f32(dst_iter, out);
        dst_iter += 4;

        frac4 = vaddq_s32(frac4, increment4);
        pos4 = vaddq_s32(pos4, vshrq_n_s32(frac4, MixerFracBits));
        frac4 = vandq_s32(frac4, fracMask4);
    }

    if(size_t todo{dst.size()&3})
    {
        src += static_cast<ALuint>(vgetq_lane_s32(pos4, 0));
        frac = static_cast<ALuint>(vgetq_lane_s32(frac4, 0));

        do {
            *(dst_iter++) = lerp(src[0], src[1], static_cast<float>(frac) * (1.0f/MixerFracOne));

            frac += increment;
            src  += frac>>MixerFracBits;
            frac &= MixerFracMask;
        } while(--todo);
    }
    return dst.data();
}

template<>
const float *Resample_<BSincTag,NEONTag>(const InterpState *state, const float *RESTRICT src,
    ALuint frac, ALuint increment, const al::span<float> dst)
{
    const float *const filter{state->bsinc.filter};
    const float32x4_t sf4{vdupq_n_f32(state->bsinc.sf)};
    const size_t m{state->bsinc.m};

    src -= state->bsinc.l;
    for(float &out_sample : dst)
    {
        // Calculate the phase index and factor.
        const ALuint pi{frac >> FracPhaseBitDiff};
        const float pf{static_cast<float>(frac & (FracPhaseDiffOne-1)) * (1.0f/FracPhaseDiffOne)};

        // Apply the scale and phase interpolated filter.
        float32x4_t r4{vdupq_n_f32(0.0f)};
        {
            const float32x4_t pf4{vdupq_n_f32(pf)};
            const float *fil{filter + m*pi*4};
            const float *phd{fil + m};
            const float *scd{phd + m};
            const float *spd{scd + m};
            size_t td{m >> 2};
            size_t j{0u};

            do {
                /* f = ((fil + sf*scd) + pf*(phd + sf*spd)) */
                const float32x4_t f4 = vmlaq_f32(
                    vmlaq_f32(vld1q_f32(&fil[j]), sf4, vld1q_f32(&scd[j])),
                    pf4, vmlaq_f32(vld1q_f32(&phd[j]), sf4, vld1q_f32(&spd[j])));
                /* r += f*src */
                r4 = vmlaq_f32(r4, f4, vld1q_f32(&src[j]));
                j += 4;
            } while(--td);
        }
        r4 = vaddq_f32(r4, vrev64q_f32(r4));
        out_sample = vget_lane_f32(vadd_f32(vget_low_f32(r4), vget_high_f32(r4)), 0);

        frac += increment;
        src  += frac>>MixerFracBits;
        frac &= MixerFracMask;
    }
    return dst.data();
}

template<>
const float *Resample_<FastBSincTag,NEONTag>(const InterpState *state,
    const float *RESTRICT src, ALuint frac, ALuint increment, const al::span<float> dst)
{
    const float *const filter{state->bsinc.filter};
    const size_t m{state->bsinc.m};

    src -= state->bsinc.l;
    for(float &out_sample : dst)
    {
        // Calculate the phase index and factor.
        const ALuint pi{frac >> FracPhaseBitDiff};
        const float pf{static_cast<float>(frac & (FracPhaseDiffOne-1)) * (1.0f/FracPhaseDiffOne)};

        // Apply the phase interpolated filter.
        float32x4_t r4{vdupq_n_f32(0.0f)};
        {
            const float32x4_t pf4{vdupq_n_f32(pf)};
            const float *fil{filter + m*pi*4};
            const float *phd{fil + m};
            size_t td{m >> 2};
            size_t j{0u};

            do {
                /* f = fil + pf*phd */
                const float32x4_t f4 = vmlaq_f32(vld1q_f32(&fil[j]), pf4, vld1q_f32(&phd[j]));
                /* r += f*src */
                r4 = vmlaq_f32(r4, f4, vld1q_f32(&src[j]));
                j += 4;
            } while(--td);
        }
        r4 = vaddq_f32(r4, vrev64q_f32(r4));
        out_sample = vget_lane_f32(vadd_f32(vget_low_f32(r4), vget_high_f32(r4)), 0);

        frac += increment;
        src  += frac>>MixerFracBits;
        frac &= MixerFracMask;
    }
    return dst.data();
}


template<>
void MixHrtf_<NEONTag>(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const MixHrtfFilter *hrtfparams, const size_t BufferSize)
{ MixHrtfBase<ApplyCoeffs>(InSamples, AccumSamples, IrSize, hrtfparams, BufferSize); }

template<>
void MixHrtfBlend_<NEONTag>(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const HrtfFilter *oldparams, const MixHrtfFilter *newparams, const size_t BufferSize)
{
    MixHrtfBlendBase<ApplyCoeffs>(InSamples, AccumSamples, IrSize, oldparams, newparams,
        BufferSize);
}

template<>
void MixDirectHrtf_<NEONTag>(FloatBufferLine &LeftOut, FloatBufferLine &RightOut,
    const al::span<const FloatBufferLine> InSamples, float2 *AccumSamples, DirectHrtfState *State,
    const size_t BufferSize)
{ MixDirectHrtfBase<ApplyCoeffs>(LeftOut, RightOut, InSamples, AccumSamples, State, BufferSize); }


template<>
void Mix_<NEONTag>(const al::span<const float> InSamples, const al::span<FloatBufferLine> OutBuffer,
    float *CurrentGains, const float *TargetGains, const size_t Counter, const size_t OutPos)
{
    const float delta{(Counter > 0) ? 1.0f / static_cast<float>(Counter) : 0.0f};
    const auto min_len = minz(Counter, InSamples.size());
    const auto aligned_len = minz((min_len+3) & ~size_t{3}, InSamples.size()) - min_len;

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
            /* Mix with applying gain steps in aligned multiples of 4. */
            if(size_t todo{(min_len-pos) >> 2})
            {
                const float32x4_t four4{vdupq_n_f32(4.0f)};
                const float32x4_t step4{vdupq_n_f32(step)};
                const float32x4_t gain4{vdupq_n_f32(gain)};
                float32x4_t step_count4{vdupq_n_f32(0.0f)};
                step_count4 = vsetq_lane_f32(1.0f, step_count4, 1);
                step_count4 = vsetq_lane_f32(2.0f, step_count4, 2);
                step_count4 = vsetq_lane_f32(3.0f, step_count4, 3);

                do {
                    const float32x4_t val4 = vld1q_f32(&InSamples[pos]);
                    float32x4_t dry4 = vld1q_f32(&dst[pos]);
                    dry4 = vmlaq_f32(dry4, val4, vmlaq_f32(gain4, step4, step_count4));
                    step_count4 = vaddq_f32(step_count4, four4);
                    vst1q_f32(&dst[pos], dry4);
                    pos += 4;
                } while(--todo);
                /* NOTE: step_count4 now represents the next four counts after
                 * the last four mixed samples, so the lowest element
                 * represents the next step count to apply.
                 */
                step_count = vgetq_lane_f32(step_count4, 0);
            }
            /* Mix with applying left over gain steps that aren't aligned multiples of 4. */
            for(size_t leftover{min_len&3};leftover;++pos,--leftover)
            {
                dst[pos] += InSamples[pos] * (gain + step*step_count);
                step_count += 1.0f;
            }
            if(pos == Counter)
                gain = *TargetGains;
            else
                gain += step*step_count;

            /* Mix until pos is aligned with 4 or the mix is done. */
            for(size_t leftover{aligned_len&3};leftover;++pos,--leftover)
                dst[pos] += InSamples[pos] * gain;
        }
        *CurrentGains = gain;
        ++CurrentGains;
        ++TargetGains;

        if(!(std::fabs(gain) > GainSilenceThreshold))
            continue;
        if(size_t todo{(InSamples.size()-pos) >> 2})
        {
            const float32x4_t gain4 = vdupq_n_f32(gain);
            do {
                const float32x4_t val4 = vld1q_f32(&InSamples[pos]);
                float32x4_t dry4 = vld1q_f32(&dst[pos]);
                dry4 = vmlaq_f32(dry4, val4, gain4);
                vst1q_f32(&dst[pos], dry4);
                pos += 4;
            } while(--todo);
        }
        for(size_t leftover{(InSamples.size()-pos)&3};leftover;++pos,--leftover)
            dst[pos] += InSamples[pos] * gain;
    }
}
