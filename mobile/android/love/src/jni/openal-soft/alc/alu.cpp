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

#include "alu.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <iterator>
#include <limits>
#include <memory>
#include <new>
#include <numeric>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/efx.h"

#include "al/auxeffectslot.h"
#include "al/buffer.h"
#include "al/effect.h"
#include "al/event.h"
#include "al/listener.h"
#include "alcmain.h"
#include "alcontext.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "alspan.h"
#include "alstring.h"
#include "ambidefs.h"
#include "atomic.h"
#include "bformatdec.h"
#include "bs2b.h"
#include "cpu_caps.h"
#include "devformat.h"
#include "effects/base.h"
#include "filters/biquad.h"
#include "filters/nfc.h"
#include "filters/splitter.h"
#include "fpu_ctrl.h"
#include "front_stablizer.h"
#include "hrtf.h"
#include "inprogext.h"
#include "mastering.h"
#include "math_defs.h"
#include "mixer/defs.h"
#include "opthelpers.h"
#include "ringbuffer.h"
#include "strutils.h"
#include "threads.h"
#include "uhjfilter.h"
#include "vecmat.h"
#include "voice.h"

#include "bsinc_tables.h"

struct CTag;
#ifdef HAVE_SSE
struct SSETag;
#endif
#ifdef HAVE_SSE2
struct SSE2Tag;
#endif
#ifdef HAVE_SSE4_1
struct SSE4Tag;
#endif
#ifdef HAVE_NEON
struct NEONTag;
#endif
struct CopyTag;
struct PointTag;
struct LerpTag;
struct CubicTag;
struct BSincTag;
struct FastBSincTag;


static_assert(MAX_RESAMPLER_PADDING >= BSincPointsMax, "MAX_RESAMPLER_PADDING is too small");
static_assert(!(MAX_RESAMPLER_PADDING&1), "MAX_RESAMPLER_PADDING is not a multiple of two");


namespace {

using namespace std::placeholders;

float InitConeScale()
{
    float ret{1.0f};
    if(auto optval = al::getenv("__ALSOFT_HALF_ANGLE_CONES"))
    {
        if(al::strcasecmp(optval->c_str(), "true") == 0
            || strtol(optval->c_str(), nullptr, 0) == 1)
            ret *= 0.5f;
    }
    return ret;
}

float InitZScale()
{
    float ret{1.0f};
    if(auto optval = al::getenv("__ALSOFT_REVERSE_Z"))
    {
        if(al::strcasecmp(optval->c_str(), "true") == 0
            || strtol(optval->c_str(), nullptr, 0) == 1)
            ret *= -1.0f;
    }
    return ret;
}

} // namespace

/* Cone scalar */
const float ConeScale{InitConeScale()};

/* Localized Z scalar for mono sources */
const float ZScale{InitZScale()};

namespace {

struct ChanMap {
    Channel channel;
    float angle;
    float elevation;
};

using HrtfDirectMixerFunc = void(*)(FloatBufferLine &LeftOut, FloatBufferLine &RightOut,
    const al::span<const FloatBufferLine> InSamples, float2 *AccumSamples, DirectHrtfState *State,
    const size_t BufferSize);

HrtfDirectMixerFunc MixDirectHrtf{MixDirectHrtf_<CTag>};

inline HrtfDirectMixerFunc SelectHrtfMixer(void)
{
#ifdef HAVE_NEON
    if((CPUCapFlags&CPU_CAP_NEON))
        return MixDirectHrtf_<NEONTag>;
#endif
#ifdef HAVE_SSE
    if((CPUCapFlags&CPU_CAP_SSE))
        return MixDirectHrtf_<SSETag>;
#endif

    return MixDirectHrtf_<CTag>;
}


inline void BsincPrepare(const ALuint increment, BsincState *state, const BSincTable *table)
{
    size_t si{BSincScaleCount - 1};
    float sf{0.0f};

    if(increment > MixerFracOne)
    {
        sf = MixerFracOne / static_cast<float>(increment);
        sf = maxf(0.0f, (BSincScaleCount-1) * (sf-table->scaleBase) * table->scaleRange);
        si = float2uint(sf);
        /* The interpolation factor is fit to this diagonally-symmetric curve
         * to reduce the transition ripple caused by interpolating different
         * scales of the sinc function.
         */
        sf = 1.0f - std::cos(std::asin(sf - static_cast<float>(si)));
    }

    state->sf = sf;
    state->m = table->m[si];
    state->l = (state->m/2) - 1;
    state->filter = table->Tab + table->filterOffset[si];
}

inline ResamplerFunc SelectResampler(Resampler resampler, ALuint increment)
{
    switch(resampler)
    {
    case Resampler::Point:
        return Resample_<PointTag,CTag>;
    case Resampler::Linear:
#ifdef HAVE_NEON
        if((CPUCapFlags&CPU_CAP_NEON))
            return Resample_<LerpTag,NEONTag>;
#endif
#ifdef HAVE_SSE4_1
        if((CPUCapFlags&CPU_CAP_SSE4_1))
            return Resample_<LerpTag,SSE4Tag>;
#endif
#ifdef HAVE_SSE2
        if((CPUCapFlags&CPU_CAP_SSE2))
            return Resample_<LerpTag,SSE2Tag>;
#endif
        return Resample_<LerpTag,CTag>;
    case Resampler::Cubic:
        return Resample_<CubicTag,CTag>;
    case Resampler::BSinc12:
    case Resampler::BSinc24:
        if(increment <= MixerFracOne)
        {
            /* fall-through */
        case Resampler::FastBSinc12:
        case Resampler::FastBSinc24:
#ifdef HAVE_NEON
            if((CPUCapFlags&CPU_CAP_NEON))
                return Resample_<FastBSincTag,NEONTag>;
#endif
#ifdef HAVE_SSE
            if((CPUCapFlags&CPU_CAP_SSE))
                return Resample_<FastBSincTag,SSETag>;
#endif
            return Resample_<FastBSincTag,CTag>;
        }
#ifdef HAVE_NEON
        if((CPUCapFlags&CPU_CAP_NEON))
            return Resample_<BSincTag,NEONTag>;
#endif
#ifdef HAVE_SSE
        if((CPUCapFlags&CPU_CAP_SSE))
            return Resample_<BSincTag,SSETag>;
#endif
        return Resample_<BSincTag,CTag>;
    }

    return Resample_<PointTag,CTag>;
}

} // namespace

void aluInit(void)
{
    MixDirectHrtf = SelectHrtfMixer();
}


ResamplerFunc PrepareResampler(Resampler resampler, ALuint increment, InterpState *state)
{
    switch(resampler)
    {
    case Resampler::Point:
    case Resampler::Linear:
    case Resampler::Cubic:
        break;
    case Resampler::FastBSinc12:
    case Resampler::BSinc12:
        BsincPrepare(increment, &state->bsinc, &bsinc12);
        break;
    case Resampler::FastBSinc24:
    case Resampler::BSinc24:
        BsincPrepare(increment, &state->bsinc, &bsinc24);
        break;
    }
    return SelectResampler(resampler, increment);
}


void ALCdevice::ProcessHrtf(const size_t SamplesToDo)
{
    /* HRTF is stereo output only. */
    const ALuint lidx{RealOut.ChannelIndex[FrontLeft]};
    const ALuint ridx{RealOut.ChannelIndex[FrontRight]};

    MixDirectHrtf(RealOut.Buffer[lidx], RealOut.Buffer[ridx], Dry.Buffer, HrtfAccumData,
        mHrtfState.get(), SamplesToDo);
}

void ALCdevice::ProcessAmbiDec(const size_t SamplesToDo)
{
    AmbiDecoder->process(RealOut.Buffer, Dry.Buffer.data(), SamplesToDo);
}

void ALCdevice::ProcessAmbiDecStablized(const size_t SamplesToDo)
{
    /* Decode with front image stablization. */
    const ALuint lidx{RealOut.ChannelIndex[FrontLeft]};
    const ALuint ridx{RealOut.ChannelIndex[FrontRight]};
    const ALuint cidx{RealOut.ChannelIndex[FrontCenter]};

    AmbiDecoder->processStablize(RealOut.Buffer, Dry.Buffer.data(), lidx, ridx, cidx,
        SamplesToDo);
}

void ALCdevice::ProcessUhj(const size_t SamplesToDo)
{
    /* UHJ is stereo output only. */
    const ALuint lidx{RealOut.ChannelIndex[FrontLeft]};
    const ALuint ridx{RealOut.ChannelIndex[FrontRight]};

    /* Encode to stereo-compatible 2-channel UHJ output. */
    Uhj_Encoder->encode(RealOut.Buffer[lidx], RealOut.Buffer[ridx], Dry.Buffer.data(),
        SamplesToDo);
}

void ALCdevice::ProcessBs2b(const size_t SamplesToDo)
{
    /* First, decode the ambisonic mix to the "real" output. */
    AmbiDecoder->process(RealOut.Buffer, Dry.Buffer.data(), SamplesToDo);

    /* BS2B is stereo output only. */
    const ALuint lidx{RealOut.ChannelIndex[FrontLeft]};
    const ALuint ridx{RealOut.ChannelIndex[FrontRight]};

    /* Now apply the BS2B binaural/crossfeed filter. */
    bs2b_cross_feed(Bs2b.get(), RealOut.Buffer[lidx].data(), RealOut.Buffer[ridx].data(),
        SamplesToDo);
}


namespace {

/* This RNG method was created based on the math found in opusdec. It's quick,
 * and starting with a seed value of 22222, is suitable for generating
 * whitenoise.
 */
inline ALuint dither_rng(ALuint *seed) noexcept
{
    *seed = (*seed * 96314165) + 907633515;
    return *seed;
}


auto GetAmbiScales(AmbiScaling scaletype) noexcept -> const std::array<float,MAX_AMBI_CHANNELS>&
{
    if(scaletype == AmbiScaling::FuMa) return AmbiScale::FromFuMa;
    if(scaletype == AmbiScaling::SN3D) return AmbiScale::FromSN3D;
    return AmbiScale::FromN3D;
}

auto GetAmbiLayout(AmbiLayout layouttype) noexcept -> const std::array<uint8_t,MAX_AMBI_CHANNELS>&
{
    if(layouttype == AmbiLayout::FuMa) return AmbiIndex::FromFuMa;
    return AmbiIndex::FromACN;
}

auto GetAmbi2DLayout(AmbiLayout layouttype) noexcept -> const std::array<uint8_t,MAX_AMBI2D_CHANNELS>&
{
    if(layouttype == AmbiLayout::FuMa) return AmbiIndex::FromFuMa2D;
    return AmbiIndex::From2D;
}


inline alu::Vector aluCrossproduct(const alu::Vector &in1, const alu::Vector &in2)
{
    return alu::Vector{
        in1[1]*in2[2] - in1[2]*in2[1],
        in1[2]*in2[0] - in1[0]*in2[2],
        in1[0]*in2[1] - in1[1]*in2[0],
        0.0f
    };
}

inline float aluDotproduct(const alu::Vector &vec1, const alu::Vector &vec2)
{
    return vec1[0]*vec2[0] + vec1[1]*vec2[1] + vec1[2]*vec2[2];
}


alu::Vector operator*(const alu::Matrix &mtx, const alu::Vector &vec) noexcept
{
    return alu::Vector{
        vec[0]*mtx[0][0] + vec[1]*mtx[1][0] + vec[2]*mtx[2][0] + vec[3]*mtx[3][0],
        vec[0]*mtx[0][1] + vec[1]*mtx[1][1] + vec[2]*mtx[2][1] + vec[3]*mtx[3][1],
        vec[0]*mtx[0][2] + vec[1]*mtx[1][2] + vec[2]*mtx[2][2] + vec[3]*mtx[3][2],
        vec[0]*mtx[0][3] + vec[1]*mtx[1][3] + vec[2]*mtx[2][3] + vec[3]*mtx[3][3]
    };
}


bool CalcContextParams(ALCcontext *Context)
{
    ALcontextProps *props{Context->mUpdate.exchange(nullptr, std::memory_order_acq_rel)};
    if(!props) return false;

    ALlistener &Listener = Context->mListener;
    Listener.Params.DopplerFactor = props->DopplerFactor;
    Listener.Params.SpeedOfSound = props->SpeedOfSound * props->DopplerVelocity;

    Listener.Params.SourceDistanceModel = props->SourceDistanceModel;
    Listener.Params.mDistanceModel = props->mDistanceModel;

    AtomicReplaceHead(Context->mFreeContextProps, props);
    return true;
}

bool CalcListenerParams(ALCcontext *Context)
{
    ALlistener &Listener = Context->mListener;

    ALlistenerProps *props{Listener.Params.Update.exchange(nullptr, std::memory_order_acq_rel)};
    if(!props) return false;

    /* AT then UP */
    alu::Vector N{props->OrientAt[0], props->OrientAt[1], props->OrientAt[2], 0.0f};
    N.normalize();
    alu::Vector V{props->OrientUp[0], props->OrientUp[1], props->OrientUp[2], 0.0f};
    V.normalize();
    /* Build and normalize right-vector */
    alu::Vector U{aluCrossproduct(N, V)};
    U.normalize();

    Listener.Params.Matrix = alu::Matrix{
        U[0], V[0], -N[0], 0.0f,
        U[1], V[1], -N[1], 0.0f,
        U[2], V[2], -N[2], 0.0f,
        0.0f, 0.0f,  0.0f, 1.0f
    };

    const alu::Vector P{Listener.Params.Matrix *
        alu::Vector{props->Position[0], props->Position[1], props->Position[2], 1.0f}};
    Listener.Params.Matrix.setRow(3, -P[0], -P[1], -P[2], 1.0f);

    const alu::Vector vel{props->Velocity[0], props->Velocity[1], props->Velocity[2], 0.0f};
    Listener.Params.Velocity = Listener.Params.Matrix * vel;

    Listener.Params.Gain = props->Gain * Context->mGainBoost;
    Listener.Params.MetersPerUnit = props->MetersPerUnit;

    AtomicReplaceHead(Context->mFreeListenerProps, props);
    return true;
}

bool CalcEffectSlotParams(ALeffectslot *slot, ALeffectslot **sorted_slots, ALCcontext *context)
{
    ALeffectslotProps *props{slot->Params.Update.exchange(nullptr, std::memory_order_acq_rel)};
    if(!props) return false;

    /* If the effect slot target changed, clear the first sorted entry to force
     * a re-sort.
     */
    if(slot->Params.Target != props->Target)
        *sorted_slots = nullptr;
    slot->Params.Gain = props->Gain;
    slot->Params.AuxSendAuto = props->AuxSendAuto;
    slot->Params.Target = props->Target;
    slot->Params.EffectType = props->Type;
    slot->Params.mEffectProps = props->Props;
    if(IsReverbEffect(props->Type))
    {
        slot->Params.RoomRolloff = props->Props.Reverb.RoomRolloffFactor;
        slot->Params.DecayTime = props->Props.Reverb.DecayTime;
        slot->Params.DecayLFRatio = props->Props.Reverb.DecayLFRatio;
        slot->Params.DecayHFRatio = props->Props.Reverb.DecayHFRatio;
        slot->Params.DecayHFLimit = props->Props.Reverb.DecayHFLimit;
        slot->Params.AirAbsorptionGainHF = props->Props.Reverb.AirAbsorptionGainHF;
    }
    else
    {
        slot->Params.RoomRolloff = 0.0f;
        slot->Params.DecayTime = 0.0f;
        slot->Params.DecayLFRatio = 0.0f;
        slot->Params.DecayHFRatio = 0.0f;
        slot->Params.DecayHFLimit = false;
        slot->Params.AirAbsorptionGainHF = 1.0f;
    }

    EffectState *state{props->State.release()};
    EffectState *oldstate{slot->Params.mEffectState};
    slot->Params.mEffectState = state;

    /* Only release the old state if it won't get deleted, since we can't be
     * deleting/freeing anything in the mixer.
     */
    if(!oldstate->releaseIfNoDelete())
    {
        /* Otherwise, if it would be deleted send it off with a release event. */
        RingBuffer *ring{context->mAsyncEvents.get()};
        auto evt_vec = ring->getWriteVector();
        if LIKELY(evt_vec.first.len > 0)
        {
            AsyncEvent *evt{::new(evt_vec.first.buf) AsyncEvent{EventType_ReleaseEffectState}};
            evt->u.mEffectState = oldstate;
            ring->writeAdvance(1);
        }
        else
        {
            /* If writing the event failed, the queue was probably full. Store
             * the old state in the property object where it can eventually be
             * cleaned up sometime later (not ideal, but better than blocking
             * or leaking).
             */
            props->State.reset(oldstate);
        }
    }

    AtomicReplaceHead(context->mFreeEffectslotProps, props);

    EffectTarget output;
    if(ALeffectslot *target{slot->Params.Target})
        output = EffectTarget{&target->Wet, nullptr};
    else
    {
        ALCdevice *device{context->mDevice.get()};
        output = EffectTarget{&device->Dry, &device->RealOut};
    }
    state->update(context, slot, &slot->Params.mEffectProps, output);
    return true;
}


/* Scales the given azimuth toward the side (+/- pi/2 radians) for positions in
 * front.
 */
inline float ScaleAzimuthFront(float azimuth, float scale)
{
    const float abs_azi{std::fabs(azimuth)};
    if(!(abs_azi >= al::MathDefs<float>::Pi()*0.5f))
        return std::copysign(minf(abs_azi*scale, al::MathDefs<float>::Pi()*0.5f), azimuth);
    return azimuth;
}

/* Wraps the given value in radians to stay between [-pi,+pi] */
inline float WrapRadians(float r)
{
    constexpr float Pi{al::MathDefs<float>::Pi()};
    constexpr float Pi2{al::MathDefs<float>::Tau()};
    if(r >  Pi) return std::fmod(Pi+r, Pi2) - Pi;
    if(r < -Pi) return Pi - std::fmod(Pi-r, Pi2);
    return r;
}

/* Begin ambisonic rotation helpers.
 *
 * Rotating first-order B-Format just needs a straight-forward X/Y/Z rotation
 * matrix. Higher orders, however, are more complicated. The method implemented
 * here is a recursive algorithm (the rotation for first-order is used to help
 * generate the second-order rotation, which helps generate the third-order
 * rotation, etc).
 *
 * Adapted from
 * <https://github.com/polarch/Spherical-Harmonic-Transform/blob/master/getSHrotMtx.m>,
 * provided under the BSD 3-Clause license.
 *
 * Copyright (c) 2015, Archontis Politis
 * Copyright (c) 2019, Christopher Robinson
 *
 * The u, v, and w coefficients used for generating higher-order rotations are
 * precomputed since they're constant. The second-order coefficients are
 * followed by the third-order coefficients, etc.
 */
struct RotatorCoeffs {
    float u, v, w;

    template<size_t N0, size_t N1>
    static std::array<RotatorCoeffs,N0+N1> ConcatArrays(const std::array<RotatorCoeffs,N0> &lhs,
        const std::array<RotatorCoeffs,N1> &rhs)
    {
        std::array<RotatorCoeffs,N0+N1> ret;
        auto iter = std::copy(lhs.cbegin(), lhs.cend(), ret.begin());
        std::copy(rhs.cbegin(), rhs.cend(), iter);
        return ret;
    }

    template<int l, int num_elems=l*2+1>
    static std::array<RotatorCoeffs,num_elems*num_elems> GenCoeffs()
    {
        std::array<RotatorCoeffs,num_elems*num_elems> ret{};
        auto coeffs = ret.begin();

        for(int m{-l};m <= l;++m)
        {
            for(int n{-l};n <= l;++n)
            {
                // compute u,v,w terms of Eq.8.1 (Table I)
                const bool d{m == 0}; // the delta function d_m0
                const float denom{static_cast<float>((std::abs(n) == l) ?
                    (2*l) * (2*l - 1) : (l*l - n*n))};

                const int abs_m{std::abs(m)};
                coeffs->u = std::sqrt(static_cast<float>(l*l - m*m)/denom);
                coeffs->v = std::sqrt(static_cast<float>(l+abs_m-1) * static_cast<float>(l+abs_m) /
                    denom) * (1.0f+d) * (1.0f - 2.0f*d) * 0.5f;
                coeffs->w = std::sqrt(static_cast<float>(l-abs_m-1) * static_cast<float>(l-abs_m) /
                    denom) * (1.0f-d) * -0.5f;
                ++coeffs;
            }
        }

        return ret;
    }
};
const auto RotatorCoeffArray = RotatorCoeffs::ConcatArrays(RotatorCoeffs::GenCoeffs<2>(),
    RotatorCoeffs::GenCoeffs<3>());

/**
 * Given the matrix, pre-filled with the (zeroth- and) first-order rotation
 * coefficients, this fills in the coefficients for the higher orders up to and
 * including the given order. The matrix is in ACN layout.
 */
void AmbiRotator(std::array<std::array<float,MAX_AMBI_CHANNELS>,MAX_AMBI_CHANNELS> &matrix,
    const int order)
{
    /* Don't do anything for < 2nd order. */
    if(order < 2) return;

    auto P = [](const int i, const int l, const int a, const int n, const size_t last_band,
        const std::array<std::array<float,MAX_AMBI_CHANNELS>,MAX_AMBI_CHANNELS> &R)
    {
        const float ri1{ R[static_cast<ALuint>(i+2)][ 1+2]};
        const float rim1{R[static_cast<ALuint>(i+2)][-1+2]};
        const float ri0{ R[static_cast<ALuint>(i+2)][ 0+2]};

        auto vec = R[static_cast<ALuint>(a+l-1) + last_band].cbegin() + last_band;
        if(n == -l)
            return ri1*vec[0] + rim1*vec[static_cast<ALuint>(l-1)*size_t{2}];
        if(n == l)
            return ri1*vec[static_cast<ALuint>(l-1)*size_t{2}] - rim1*vec[0];
        return ri0*vec[static_cast<ALuint>(n+l-1)];
    };

    auto U = [P](const int l, const int m, const int n, const size_t last_band,
        const std::array<std::array<float,MAX_AMBI_CHANNELS>,MAX_AMBI_CHANNELS> &R)
    {
        return P(0, l, m, n, last_band, R);
    };
    auto V = [P](const int l, const int m, const int n, const size_t last_band,
        const std::array<std::array<float,MAX_AMBI_CHANNELS>,MAX_AMBI_CHANNELS> &R)
    {
        if(m > 0)
        {
            const bool d{m == 1};
            const float p0{P( 1, l,  m-1, n, last_band, R)};
            const float p1{P(-1, l, -m+1, n, last_band, R)};
            return d ? p0*std::sqrt(2.0f) : (p0 - p1);
        }
        const bool d{m == -1};
        const float p0{P( 1, l,  m+1, n, last_band, R)};
        const float p1{P(-1, l, -m-1, n, last_band, R)};
        return d ? p1*std::sqrt(2.0f) : (p0 + p1);
    };
    auto W = [P](const int l, const int m, const int n, const size_t last_band,
        const std::array<std::array<float,MAX_AMBI_CHANNELS>,MAX_AMBI_CHANNELS> &R)
    {
        assert(m != 0);
        if(m > 0)
        {
            const float p0{P( 1, l,  m+1, n, last_band, R)};
            const float p1{P(-1, l, -m-1, n, last_band, R)};
            return p0 + p1;
        }
        const float p0{P( 1, l,  m-1, n, last_band, R)};
        const float p1{P(-1, l, -m+1, n, last_band, R)};
        return p0 - p1;
    };

    // compute rotation matrix of each subsequent band recursively
    auto coeffs = RotatorCoeffArray.cbegin();
    size_t band_idx{4}, last_band{1};
    for(int l{2};l <= order;++l)
    {
        size_t y{band_idx};
        for(int m{-l};m <= l;++m,++y)
        {
            size_t x{band_idx};
            for(int n{-l};n <= l;++n,++x)
            {
                float r{0.0f};

                // computes Eq.8.1
                const float u{coeffs->u};
                if(u != 0.0f) r += u * U(l, m, n, last_band, matrix);
                const float v{coeffs->v};
                if(v != 0.0f) r += v * V(l, m, n, last_band, matrix);
                const float w{coeffs->w};
                if(w != 0.0f) r += w * W(l, m, n, last_band, matrix);

                matrix[y][x] = r;
                ++coeffs;
            }
        }
        last_band = band_idx;
        band_idx += static_cast<ALuint>(l)*size_t{2} + 1;
    }
}
/* End ambisonic rotation helpers. */


struct GainTriplet { float Base, HF, LF; };

void CalcPanningAndFilters(Voice *voice, const float xpos, const float ypos, const float zpos,
    const float Distance, const float Spread, const GainTriplet &DryGain,
    const al::span<const GainTriplet,MAX_SENDS> WetGain, ALeffectslot *(&SendSlots)[MAX_SENDS],
    const VoiceProps *props, const ALlistener &Listener, const ALCdevice *Device)
{
    static const ChanMap MonoMap[1]{
        { FrontCenter, 0.0f, 0.0f }
    }, RearMap[2]{
        { BackLeft,  Deg2Rad(-150.0f), Deg2Rad(0.0f) },
        { BackRight, Deg2Rad( 150.0f), Deg2Rad(0.0f) }
    }, QuadMap[4]{
        { FrontLeft,  Deg2Rad( -45.0f), Deg2Rad(0.0f) },
        { FrontRight, Deg2Rad(  45.0f), Deg2Rad(0.0f) },
        { BackLeft,   Deg2Rad(-135.0f), Deg2Rad(0.0f) },
        { BackRight,  Deg2Rad( 135.0f), Deg2Rad(0.0f) }
    }, X51Map[6]{
        { FrontLeft,   Deg2Rad( -30.0f), Deg2Rad(0.0f) },
        { FrontRight,  Deg2Rad(  30.0f), Deg2Rad(0.0f) },
        { FrontCenter, Deg2Rad(   0.0f), Deg2Rad(0.0f) },
        { LFE, 0.0f, 0.0f },
        { SideLeft,    Deg2Rad(-110.0f), Deg2Rad(0.0f) },
        { SideRight,   Deg2Rad( 110.0f), Deg2Rad(0.0f) }
    }, X61Map[7]{
        { FrontLeft,   Deg2Rad(-30.0f), Deg2Rad(0.0f) },
        { FrontRight,  Deg2Rad( 30.0f), Deg2Rad(0.0f) },
        { FrontCenter, Deg2Rad(  0.0f), Deg2Rad(0.0f) },
        { LFE, 0.0f, 0.0f },
        { BackCenter,  Deg2Rad(180.0f), Deg2Rad(0.0f) },
        { SideLeft,    Deg2Rad(-90.0f), Deg2Rad(0.0f) },
        { SideRight,   Deg2Rad( 90.0f), Deg2Rad(0.0f) }
    }, X71Map[8]{
        { FrontLeft,   Deg2Rad( -30.0f), Deg2Rad(0.0f) },
        { FrontRight,  Deg2Rad(  30.0f), Deg2Rad(0.0f) },
        { FrontCenter, Deg2Rad(   0.0f), Deg2Rad(0.0f) },
        { LFE, 0.0f, 0.0f },
        { BackLeft,    Deg2Rad(-150.0f), Deg2Rad(0.0f) },
        { BackRight,   Deg2Rad( 150.0f), Deg2Rad(0.0f) },
        { SideLeft,    Deg2Rad( -90.0f), Deg2Rad(0.0f) },
        { SideRight,   Deg2Rad(  90.0f), Deg2Rad(0.0f) }
    };

    ChanMap StereoMap[2]{
        { FrontLeft,  Deg2Rad(-30.0f), Deg2Rad(0.0f) },
        { FrontRight, Deg2Rad( 30.0f), Deg2Rad(0.0f) }
    };

    const auto Frequency = static_cast<float>(Device->Frequency);
    const ALuint NumSends{Device->NumAuxSends};

    const size_t num_channels{voice->mChans.size()};
    ASSUME(num_channels > 0);

    for(auto &chandata : voice->mChans)
    {
        chandata.mDryParams.Hrtf.Target = HrtfFilter{};
        chandata.mDryParams.Gains.Target.fill(0.0f);
        std::for_each(chandata.mWetParams.begin(), chandata.mWetParams.begin()+NumSends,
            [](SendParams &params) -> void { params.Gains.Target.fill(0.0f); });
    }

    DirectMode DirectChannels{props->DirectChannels};
    const ChanMap *chans{nullptr};
    float downmix_gain{1.0f};
    switch(voice->mFmtChannels)
    {
    case FmtMono:
        chans = MonoMap;
        /* Mono buffers are never played direct. */
        DirectChannels = DirectMode::Off;
        break;

    case FmtStereo:
        if(DirectChannels == DirectMode::Off)
        {
            /* Convert counter-clockwise to clock-wise, and wrap between
             * [-pi,+pi].
             */
            StereoMap[0].angle = WrapRadians(-props->StereoPan[0]);
            StereoMap[1].angle = WrapRadians(-props->StereoPan[1]);
        }

        chans = StereoMap;
        downmix_gain = 1.0f / 2.0f;
        break;

    case FmtRear:
        chans = RearMap;
        downmix_gain = 1.0f / 2.0f;
        break;

    case FmtQuad:
        chans = QuadMap;
        downmix_gain = 1.0f / 4.0f;
        break;

    case FmtX51:
        chans = X51Map;
        /* NOTE: Excludes LFE. */
        downmix_gain = 1.0f / 5.0f;
        break;

    case FmtX61:
        chans = X61Map;
        /* NOTE: Excludes LFE. */
        downmix_gain = 1.0f / 6.0f;
        break;

    case FmtX71:
        chans = X71Map;
        /* NOTE: Excludes LFE. */
        downmix_gain = 1.0f / 7.0f;
        break;

    case FmtBFormat2D:
    case FmtBFormat3D:
        DirectChannels = DirectMode::Off;
        break;
    }

    voice->mFlags &= ~(VoiceHasHrtf | VoiceHasNfc);
    if(voice->mFmtChannels == FmtBFormat2D || voice->mFmtChannels == FmtBFormat3D)
    {
        /* Special handling for B-Format sources. */

        if(Device->AvgSpeakerDist > 0.0f)
        {
            if(!(Distance > std::numeric_limits<float>::epsilon()))
            {
                /* NOTE: The NFCtrlFilters were created with a w0 of 0, which
                 * is what we want for FOA input. The first channel may have
                 * been previously re-adjusted if panned, so reset it.
                 */
                voice->mChans[0].mDryParams.NFCtrlFilter.adjust(0.0f);
            }
            else
            {
                /* Clamp the distance for really close sources, to prevent
                 * excessive bass.
                 */
                const float mdist{maxf(Distance, Device->AvgSpeakerDist/4.0f)};
                const float w0{SpeedOfSoundMetersPerSec / (mdist * Frequency)};

                /* Only need to adjust the first channel of a B-Format source. */
                voice->mChans[0].mDryParams.NFCtrlFilter.adjust(w0);
            }

            voice->mFlags |= VoiceHasNfc;
        }

        /* Panning a B-Format sound toward some direction is easy. Just pan the
         * first (W) channel as a normal mono sound. The angular spread is used
         * as a directional scalar to blend between full coverage and full
         * panning.
         */
        const float coverage{!(Distance > std::numeric_limits<float>::epsilon()) ? 1.0f :
            (Spread * (1.0f/al::MathDefs<float>::Tau()))};

        auto calc_coeffs = [xpos,ypos,zpos](RenderMode mode)
        {
            if(mode != RenderMode::Pairwise)
                return CalcDirectionCoeffs({xpos, ypos, zpos}, 0.0f);

            /* Clamp Y, in case rounding errors caused it to end up outside
             * of -1...+1.
             */
            const float ev{std::asin(clampf(ypos, -1.0f, 1.0f))};
            /* Negate Z for right-handed coords with -Z in front. */
            const float az{std::atan2(xpos, -zpos)};

            /* A scalar of 1.5 for plain stereo results in +/-60 degrees
             * being moved to +/-90 degrees for direct right and left
             * speaker responses.
             */
            return CalcAngleCoeffs(ScaleAzimuthFront(az, 1.5f), ev, 0.0f);
        };
        auto coeffs = calc_coeffs(Device->mRenderMode);
        std::transform(coeffs.begin()+1, coeffs.end(), coeffs.begin()+1,
            std::bind(std::multiplies<float>{}, _1, 1.0f-coverage));

        /* NOTE: W needs to be scaled according to channel scaling. */
        const auto &scales = GetAmbiScales(voice->mAmbiScaling);
        ComputePanGains(&Device->Dry, coeffs.data(), DryGain.Base*scales[0],
            voice->mChans[0].mDryParams.Gains.Target);
        for(ALuint i{0};i < NumSends;i++)
        {
            if(const ALeffectslot *Slot{SendSlots[i]})
                ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base*scales[0],
                    voice->mChans[0].mWetParams[i].Gains.Target);
        }

        if(coverage > 0.0f)
        {
            /* Local B-Format sources have their XYZ channels rotated according
             * to the orientation.
             */
            /* AT then UP */
            alu::Vector N{props->OrientAt[0], props->OrientAt[1], props->OrientAt[2], 0.0f};
            N.normalize();
            alu::Vector V{props->OrientUp[0], props->OrientUp[1], props->OrientUp[2], 0.0f};
            V.normalize();
            if(!props->HeadRelative)
            {
                N = Listener.Params.Matrix * N;
                V = Listener.Params.Matrix * V;
            }
            /* Build and normalize right-vector */
            alu::Vector U{aluCrossproduct(N, V)};
            U.normalize();

            /* Build a rotation matrix. Manually fill the zeroth- and first-
             * order elements, then construct the rotation for the higher
             * orders.
             */
            std::array<std::array<float,MAX_AMBI_CHANNELS>,MAX_AMBI_CHANNELS> shrot{};
            shrot[0][0] = 1.0f;
            shrot[1][1] =  U[0]; shrot[1][2] = -V[0]; shrot[1][3] = -N[0];
            shrot[2][1] = -U[1]; shrot[2][2] =  V[1]; shrot[2][3] =  N[1];
            shrot[3][1] =  U[2]; shrot[3][2] = -V[2]; shrot[3][3] = -N[2];
            AmbiRotator(shrot, static_cast<int>(minu(voice->mAmbiOrder, Device->mAmbiOrder)));

            /* Convert the rotation matrix for input ordering and scaling, and
             * whether input is 2D or 3D.
             */
            const uint8_t *index_map{(voice->mFmtChannels == FmtBFormat2D) ?
                GetAmbi2DLayout(voice->mAmbiLayout).data() :
                GetAmbiLayout(voice->mAmbiLayout).data()};

            static const uint8_t ChansPerOrder[MAX_AMBI_ORDER+1]{1, 3, 5, 7,};
            static const uint8_t OrderOffset[MAX_AMBI_ORDER+1]{0, 1, 4, 9,};
            for(size_t c{1};c < num_channels;c++)
            {
                const size_t acn{index_map[c]};
                const size_t order{AmbiIndex::OrderFromChannel[acn]};
                const size_t tocopy{ChansPerOrder[order]};
                const size_t offset{OrderOffset[order]};
                const float scale{scales[acn] * coverage};
                auto in = shrot.cbegin() + offset;

                coeffs = std::array<float,MAX_AMBI_CHANNELS>{};
                for(size_t x{0};x < tocopy;++x)
                    coeffs[offset+x] = in[x][acn] * scale;

                ComputePanGains(&Device->Dry, coeffs.data(), DryGain.Base,
                    voice->mChans[c].mDryParams.Gains.Target);

                for(ALuint i{0};i < NumSends;i++)
                {
                    if(const ALeffectslot *Slot{SendSlots[i]})
                        ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base,
                            voice->mChans[c].mWetParams[i].Gains.Target);
                }
            }
        }
    }
    else if(DirectChannels != DirectMode::Off && Device->FmtChans != DevFmtAmbi3D)
    {
        /* Direct source channels always play local. Skip the virtual channels
         * and write inputs to the matching real outputs.
         */
        voice->mDirect.Buffer = Device->RealOut.Buffer;

        for(size_t c{0};c < num_channels;c++)
        {
            ALuint idx{GetChannelIdxByName(Device->RealOut, chans[c].channel)};
            if(idx != INVALID_CHANNEL_INDEX)
                voice->mChans[c].mDryParams.Gains.Target[idx] = DryGain.Base;
            else if(DirectChannels == DirectMode::RemixMismatch)
            {
                auto match_channel = [chans,c](const InputRemixMap &map) noexcept -> bool
                { return chans[c].channel == map.channel; };
                auto remap = std::find_if(Device->RealOut.RemixMap.cbegin(),
                    Device->RealOut.RemixMap.cend(), match_channel);
                if(remap != Device->RealOut.RemixMap.cend())
                    for(const auto &target : remap->targets)
                    {
                        idx = GetChannelIdxByName(Device->RealOut, target.channel);
                        if(idx != INVALID_CHANNEL_INDEX)
                            voice->mChans[c].mDryParams.Gains.Target[idx] = DryGain.Base *
                                target.mix;
                    }
            }
        }

        /* Auxiliary sends still use normal channel panning since they mix to
         * B-Format, which can't channel-match.
         */
        for(size_t c{0};c < num_channels;c++)
        {
            const auto coeffs = CalcAngleCoeffs(chans[c].angle, chans[c].elevation, 0.0f);

            for(ALuint i{0};i < NumSends;i++)
            {
                if(const ALeffectslot *Slot{SendSlots[i]})
                    ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base,
                        voice->mChans[c].mWetParams[i].Gains.Target);
            }
        }
    }
    else if(Device->mRenderMode == RenderMode::Hrtf)
    {
        /* Full HRTF rendering. Skip the virtual channels and render to the
         * real outputs.
         */
        voice->mDirect.Buffer = Device->RealOut.Buffer;

        if(Distance > std::numeric_limits<float>::epsilon())
        {
            const float ev{std::asin(clampf(ypos, -1.0f, 1.0f))};
            const float az{std::atan2(xpos, -zpos)};

            /* Get the HRIR coefficients and delays just once, for the given
             * source direction.
             */
            GetHrtfCoeffs(Device->mHrtf.get(), ev, az, Distance, Spread,
                voice->mChans[0].mDryParams.Hrtf.Target.Coeffs,
                voice->mChans[0].mDryParams.Hrtf.Target.Delay);
            voice->mChans[0].mDryParams.Hrtf.Target.Gain = DryGain.Base * downmix_gain;

            /* Remaining channels use the same results as the first. */
            for(size_t c{1};c < num_channels;c++)
            {
                /* Skip LFE */
                if(chans[c].channel == LFE) continue;
                voice->mChans[c].mDryParams.Hrtf.Target = voice->mChans[0].mDryParams.Hrtf.Target;
            }

            /* Calculate the directional coefficients once, which apply to all
             * input channels of the source sends.
             */
            const auto coeffs = CalcDirectionCoeffs({xpos, ypos, zpos}, Spread);

            for(size_t c{0};c < num_channels;c++)
            {
                /* Skip LFE */
                if(chans[c].channel == LFE)
                    continue;
                for(ALuint i{0};i < NumSends;i++)
                {
                    if(const ALeffectslot *Slot{SendSlots[i]})
                        ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base * downmix_gain,
                            voice->mChans[c].mWetParams[i].Gains.Target);
                }
            }
        }
        else
        {
            /* Local sources on HRTF play with each channel panned to its
             * relative location around the listener, providing "virtual
             * speaker" responses.
             */
            for(size_t c{0};c < num_channels;c++)
            {
                /* Skip LFE */
                if(chans[c].channel == LFE)
                    continue;

                /* Get the HRIR coefficients and delays for this channel
                 * position.
                 */
                GetHrtfCoeffs(Device->mHrtf.get(), chans[c].elevation, chans[c].angle,
                    std::numeric_limits<float>::infinity(), Spread,
                    voice->mChans[c].mDryParams.Hrtf.Target.Coeffs,
                    voice->mChans[c].mDryParams.Hrtf.Target.Delay);
                voice->mChans[c].mDryParams.Hrtf.Target.Gain = DryGain.Base;

                /* Normal panning for auxiliary sends. */
                const auto coeffs = CalcAngleCoeffs(chans[c].angle, chans[c].elevation, Spread);

                for(ALuint i{0};i < NumSends;i++)
                {
                    if(const ALeffectslot *Slot{SendSlots[i]})
                        ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base,
                            voice->mChans[c].mWetParams[i].Gains.Target);
                }
            }
        }

        voice->mFlags |= VoiceHasHrtf;
    }
    else
    {
        /* Non-HRTF rendering. Use normal panning to the output. */

        if(Distance > std::numeric_limits<float>::epsilon())
        {
            /* Calculate NFC filter coefficient if needed. */
            if(Device->AvgSpeakerDist > 0.0f)
            {
                /* Clamp the distance for really close sources, to prevent
                 * excessive bass.
                 */
                const float mdist{maxf(Distance, Device->AvgSpeakerDist/4.0f)};
                const float w0{SpeedOfSoundMetersPerSec / (mdist * Frequency)};

                /* Adjust NFC filters. */
                for(size_t c{0};c < num_channels;c++)
                    voice->mChans[c].mDryParams.NFCtrlFilter.adjust(w0);

                voice->mFlags |= VoiceHasNfc;
            }

            /* Calculate the directional coefficients once, which apply to all
             * input channels.
             */
            auto calc_coeffs = [xpos,ypos,zpos,Spread](RenderMode mode)
            {
                if(mode != RenderMode::Pairwise)
                    return CalcDirectionCoeffs({xpos, ypos, zpos}, Spread);
                const float ev{std::asin(clampf(ypos, -1.0f, 1.0f))};
                const float az{std::atan2(xpos, -zpos)};
                return CalcAngleCoeffs(ScaleAzimuthFront(az, 1.5f), ev, Spread);
            };
            const auto coeffs = calc_coeffs(Device->mRenderMode);

            for(size_t c{0};c < num_channels;c++)
            {
                /* Special-case LFE */
                if(chans[c].channel == LFE)
                {
                    if(Device->Dry.Buffer.data() == Device->RealOut.Buffer.data())
                    {
                        const ALuint idx{GetChannelIdxByName(Device->RealOut, chans[c].channel)};
                        if(idx != INVALID_CHANNEL_INDEX)
                            voice->mChans[c].mDryParams.Gains.Target[idx] = DryGain.Base;
                    }
                    continue;
                }

                ComputePanGains(&Device->Dry, coeffs.data(), DryGain.Base * downmix_gain,
                    voice->mChans[c].mDryParams.Gains.Target);
                for(ALuint i{0};i < NumSends;i++)
                {
                    if(const ALeffectslot *Slot{SendSlots[i]})
                        ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base * downmix_gain,
                            voice->mChans[c].mWetParams[i].Gains.Target);
                }
            }
        }
        else
        {
            if(Device->AvgSpeakerDist > 0.0f)
            {
                /* If the source distance is 0, simulate a plane-wave by using
                 * infinite distance, which results in a w0 of 0.
                 */
                constexpr float w0{0.0f};
                for(size_t c{0};c < num_channels;c++)
                    voice->mChans[c].mDryParams.NFCtrlFilter.adjust(w0);

                voice->mFlags |= VoiceHasNfc;
            }

            for(size_t c{0};c < num_channels;c++)
            {
                /* Special-case LFE */
                if(chans[c].channel == LFE)
                {
                    if(Device->Dry.Buffer.data() == Device->RealOut.Buffer.data())
                    {
                        const ALuint idx{GetChannelIdxByName(Device->RealOut, chans[c].channel)};
                        if(idx != INVALID_CHANNEL_INDEX)
                            voice->mChans[c].mDryParams.Gains.Target[idx] = DryGain.Base;
                    }
                    continue;
                }

                const auto coeffs = CalcAngleCoeffs((Device->mRenderMode == RenderMode::Pairwise)
                    ? ScaleAzimuthFront(chans[c].angle, 3.0f) : chans[c].angle,
                    chans[c].elevation, Spread);

                ComputePanGains(&Device->Dry, coeffs.data(), DryGain.Base,
                    voice->mChans[c].mDryParams.Gains.Target);
                for(ALuint i{0};i < NumSends;i++)
                {
                    if(const ALeffectslot *Slot{SendSlots[i]})
                        ComputePanGains(&Slot->Wet, coeffs.data(), WetGain[i].Base,
                            voice->mChans[c].mWetParams[i].Gains.Target);
                }
            }
        }
    }

    {
        const float hfNorm{props->Direct.HFReference / Frequency};
        const float lfNorm{props->Direct.LFReference / Frequency};

        voice->mDirect.FilterType = AF_None;
        if(DryGain.HF != 1.0f) voice->mDirect.FilterType |= AF_LowPass;
        if(DryGain.LF != 1.0f) voice->mDirect.FilterType |= AF_HighPass;

        auto &lowpass = voice->mChans[0].mDryParams.LowPass;
        auto &highpass = voice->mChans[0].mDryParams.HighPass;
        lowpass.setParamsFromSlope(BiquadType::HighShelf, hfNorm, DryGain.HF, 1.0f);
        highpass.setParamsFromSlope(BiquadType::LowShelf, lfNorm, DryGain.LF, 1.0f);
        for(size_t c{1};c < num_channels;c++)
        {
            voice->mChans[c].mDryParams.LowPass.copyParamsFrom(lowpass);
            voice->mChans[c].mDryParams.HighPass.copyParamsFrom(highpass);
        }
    }
    for(ALuint i{0};i < NumSends;i++)
    {
        const float hfNorm{props->Send[i].HFReference / Frequency};
        const float lfNorm{props->Send[i].LFReference / Frequency};

        voice->mSend[i].FilterType = AF_None;
        if(WetGain[i].HF != 1.0f) voice->mSend[i].FilterType |= AF_LowPass;
        if(WetGain[i].LF != 1.0f) voice->mSend[i].FilterType |= AF_HighPass;

        auto &lowpass = voice->mChans[0].mWetParams[i].LowPass;
        auto &highpass = voice->mChans[0].mWetParams[i].HighPass;
        lowpass.setParamsFromSlope(BiquadType::HighShelf, hfNorm, WetGain[i].HF, 1.0f);
        highpass.setParamsFromSlope(BiquadType::LowShelf, lfNorm, WetGain[i].LF, 1.0f);
        for(size_t c{1};c < num_channels;c++)
        {
            voice->mChans[c].mWetParams[i].LowPass.copyParamsFrom(lowpass);
            voice->mChans[c].mWetParams[i].HighPass.copyParamsFrom(highpass);
        }
    }
}

void CalcNonAttnSourceParams(Voice *voice, const VoiceProps *props, const ALCcontext *ALContext)
{
    const ALCdevice *Device{ALContext->mDevice.get()};
    ALeffectslot *SendSlots[MAX_SENDS];

    voice->mDirect.Buffer = Device->Dry.Buffer;
    for(ALuint i{0};i < Device->NumAuxSends;i++)
    {
        SendSlots[i] = props->Send[i].Slot;
        if(!SendSlots[i] && i == 0)
            SendSlots[i] = ALContext->mDefaultSlot.get();
        if(!SendSlots[i] || SendSlots[i]->Params.EffectType == AL_EFFECT_NULL)
        {
            SendSlots[i] = nullptr;
            voice->mSend[i].Buffer = {};
        }
        else
            voice->mSend[i].Buffer = SendSlots[i]->Wet.Buffer;
    }

    /* Calculate the stepping value */
    const auto Pitch = static_cast<float>(voice->mFrequency) /
        static_cast<float>(Device->Frequency) * props->Pitch;
    if(Pitch > float{MAX_PITCH})
        voice->mStep = MAX_PITCH<<MixerFracBits;
    else
        voice->mStep = maxu(fastf2u(Pitch * MixerFracOne), 1);
    voice->mResampler = PrepareResampler(props->mResampler, voice->mStep, &voice->mResampleState);

    /* Calculate gains */
    const ALlistener &Listener = ALContext->mListener;
    GainTriplet DryGain;
    DryGain.Base  = minf(clampf(props->Gain, props->MinGain, props->MaxGain) * props->Direct.Gain *
        Listener.Params.Gain, GainMixMax);
    DryGain.HF = props->Direct.GainHF;
    DryGain.LF = props->Direct.GainLF;
    GainTriplet WetGain[MAX_SENDS];
    for(ALuint i{0};i < Device->NumAuxSends;i++)
    {
        WetGain[i].Base = minf(clampf(props->Gain, props->MinGain, props->MaxGain) *
            props->Send[i].Gain * Listener.Params.Gain, GainMixMax);
        WetGain[i].HF = props->Send[i].GainHF;
        WetGain[i].LF = props->Send[i].GainLF;
    }

    CalcPanningAndFilters(voice, 0.0f, 0.0f, -1.0f, 0.0f, 0.0f, DryGain, WetGain, SendSlots, props,
        Listener, Device);
}

void CalcAttnSourceParams(Voice *voice, const VoiceProps *props, const ALCcontext *ALContext)
{
    const ALCdevice *Device{ALContext->mDevice.get()};
    const ALuint NumSends{Device->NumAuxSends};
    const ALlistener &Listener = ALContext->mListener;

    /* Set mixing buffers and get send parameters. */
    voice->mDirect.Buffer = Device->Dry.Buffer;
    ALeffectslot *SendSlots[MAX_SENDS];
    float RoomRolloff[MAX_SENDS];
    GainTriplet DecayDistance[MAX_SENDS];
    for(ALuint i{0};i < NumSends;i++)
    {
        SendSlots[i] = props->Send[i].Slot;
        if(!SendSlots[i] && i == 0)
            SendSlots[i] = ALContext->mDefaultSlot.get();
        if(!SendSlots[i] || SendSlots[i]->Params.EffectType == AL_EFFECT_NULL)
        {
            SendSlots[i] = nullptr;
            RoomRolloff[i] = 0.0f;
            DecayDistance[i].Base = 0.0f;
            DecayDistance[i].LF = 0.0f;
            DecayDistance[i].HF = 0.0f;
        }
        else if(SendSlots[i]->Params.AuxSendAuto)
        {
            RoomRolloff[i] = SendSlots[i]->Params.RoomRolloff + props->RoomRolloffFactor;
            /* Calculate the distances to where this effect's decay reaches
             * -60dB.
             */
            DecayDistance[i].Base = SendSlots[i]->Params.DecayTime * SpeedOfSoundMetersPerSec;
            DecayDistance[i].LF = DecayDistance[i].Base * SendSlots[i]->Params.DecayLFRatio;
            DecayDistance[i].HF = DecayDistance[i].Base * SendSlots[i]->Params.DecayHFRatio;
            if(SendSlots[i]->Params.DecayHFLimit)
            {
                const float airAbsorption{SendSlots[i]->Params.AirAbsorptionGainHF};
                if(airAbsorption < 1.0f)
                {
                    /* Calculate the distance to where this effect's air
                     * absorption reaches -60dB, and limit the effect's HF
                     * decay distance (so it doesn't take any longer to decay
                     * than the air would allow).
                     */
                    constexpr float log10_decaygain{-3.0f/*std::log10(ReverbDecayGain)*/};
                    const float absorb_dist{log10_decaygain / std::log10(airAbsorption)};
                    DecayDistance[i].HF = minf(absorb_dist, DecayDistance[i].HF);
                }
            }
        }
        else
        {
            /* If the slot's auxiliary send auto is off, the data sent to the
             * effect slot is the same as the dry path, sans filter effects */
            RoomRolloff[i] = props->RolloffFactor;
            DecayDistance[i].Base = 0.0f;
            DecayDistance[i].LF = 0.0f;
            DecayDistance[i].HF = 0.0f;
        }

        if(!SendSlots[i])
            voice->mSend[i].Buffer = {};
        else
            voice->mSend[i].Buffer = SendSlots[i]->Wet.Buffer;
    }

    /* Transform source to listener space (convert to head relative) */
    alu::Vector Position{props->Position[0], props->Position[1], props->Position[2], 1.0f};
    alu::Vector Velocity{props->Velocity[0], props->Velocity[1], props->Velocity[2], 0.0f};
    alu::Vector Direction{props->Direction[0], props->Direction[1], props->Direction[2], 0.0f};
    if(props->HeadRelative == AL_FALSE)
    {
        /* Transform source vectors */
        Position = Listener.Params.Matrix * Position;
        Velocity = Listener.Params.Matrix * Velocity;
        Direction = Listener.Params.Matrix * Direction;
    }
    else
    {
        /* Offset the source velocity to be relative of the listener velocity */
        Velocity += Listener.Params.Velocity;
    }

    const bool directional{Direction.normalize() > 0.0f};
    alu::Vector ToSource{Position[0], Position[1], Position[2], 0.0f};
    const float Distance{ToSource.normalize()};

    /* Initial source gain */
    GainTriplet DryGain{props->Gain, 1.0f, 1.0f};
    GainTriplet WetGain[MAX_SENDS];
    for(ALuint i{0};i < NumSends;i++)
        WetGain[i] = DryGain;

    /* Calculate distance attenuation */
    float ClampedDist{Distance};

    switch(Listener.Params.SourceDistanceModel ?
           props->mDistanceModel : Listener.Params.mDistanceModel)
    {
        case DistanceModel::InverseClamped:
            ClampedDist = clampf(ClampedDist, props->RefDistance, props->MaxDistance);
            if(props->MaxDistance < props->RefDistance) break;
            /*fall-through*/
        case DistanceModel::Inverse:
            if(!(props->RefDistance > 0.0f))
                ClampedDist = props->RefDistance;
            else
            {
                float dist{lerp(props->RefDistance, ClampedDist, props->RolloffFactor)};
                if(dist > 0.0f) DryGain.Base *= props->RefDistance / dist;
                for(ALuint i{0};i < NumSends;i++)
                {
                    dist = lerp(props->RefDistance, ClampedDist, RoomRolloff[i]);
                    if(dist > 0.0f) WetGain[i].Base *= props->RefDistance / dist;
                }
            }
            break;

        case DistanceModel::LinearClamped:
            ClampedDist = clampf(ClampedDist, props->RefDistance, props->MaxDistance);
            if(props->MaxDistance < props->RefDistance) break;
            /*fall-through*/
        case DistanceModel::Linear:
            if(!(props->MaxDistance != props->RefDistance))
                ClampedDist = props->RefDistance;
            else
            {
                float attn{props->RolloffFactor * (ClampedDist-props->RefDistance) /
                    (props->MaxDistance-props->RefDistance)};
                DryGain.Base *= maxf(1.0f - attn, 0.0f);
                for(ALuint i{0};i < NumSends;i++)
                {
                    attn = RoomRolloff[i] * (ClampedDist-props->RefDistance) /
                        (props->MaxDistance-props->RefDistance);
                    WetGain[i].Base *= maxf(1.0f - attn, 0.0f);
                }
            }
            break;

        case DistanceModel::ExponentClamped:
            ClampedDist = clampf(ClampedDist, props->RefDistance, props->MaxDistance);
            if(props->MaxDistance < props->RefDistance) break;
            /*fall-through*/
        case DistanceModel::Exponent:
            if(!(ClampedDist > 0.0f && props->RefDistance > 0.0f))
                ClampedDist = props->RefDistance;
            else
            {
                const float dist_ratio{ClampedDist/props->RefDistance};
                DryGain.Base *= std::pow(dist_ratio, -props->RolloffFactor);
                for(ALuint i{0};i < NumSends;i++)
                    WetGain[i].Base *= std::pow(dist_ratio, -RoomRolloff[i]);
            }
            break;

        case DistanceModel::Disable:
            ClampedDist = props->RefDistance;
            break;
    }

    /* Calculate directional soundcones */
    if(directional && props->InnerAngle < 360.0f)
    {
        const float Angle{Rad2Deg(std::acos(-aluDotproduct(Direction, ToSource)) *
            ConeScale * 2.0f)};

        float ConeGain, ConeHF;
        if(!(Angle > props->InnerAngle))
        {
            ConeGain = 1.0f;
            ConeHF = 1.0f;
        }
        else if(Angle < props->OuterAngle)
        {
            const float scale{(Angle-props->InnerAngle) / (props->OuterAngle-props->InnerAngle)};
            ConeGain = lerp(1.0f, props->OuterGain, scale);
            ConeHF = lerp(1.0f, props->OuterGainHF, scale);
        }
        else
        {
            ConeGain = props->OuterGain;
            ConeHF = props->OuterGainHF;
        }

        DryGain.Base *= ConeGain;
        if(props->DryGainHFAuto)
            DryGain.HF *= ConeHF;
        if(props->WetGainAuto)
            std::for_each(std::begin(WetGain), std::begin(WetGain)+NumSends,
                [ConeGain](GainTriplet &gain) noexcept -> void { gain.Base *= ConeGain; });
        if(props->WetGainHFAuto)
            std::for_each(std::begin(WetGain), std::begin(WetGain)+NumSends,
                [ConeHF](GainTriplet &gain) noexcept -> void { gain.HF *= ConeHF; });
    }

    /* Apply gain and frequency filters */
    DryGain.Base = minf(clampf(DryGain.Base, props->MinGain, props->MaxGain) * props->Direct.Gain *
        Listener.Params.Gain, GainMixMax);
    DryGain.HF *= props->Direct.GainHF;
    DryGain.LF *= props->Direct.GainLF;
    for(ALuint i{0};i < NumSends;i++)
    {
        WetGain[i].Base = minf(clampf(WetGain[i].Base, props->MinGain, props->MaxGain) *
            props->Send[i].Gain * Listener.Params.Gain, GainMixMax);
        WetGain[i].HF *= props->Send[i].GainHF;
        WetGain[i].LF *= props->Send[i].GainLF;
    }

    /* Distance-based air absorption and initial send decay. */
    if(ClampedDist > props->RefDistance && props->RolloffFactor > 0.0f)
    {
        const float meters_base{(ClampedDist-props->RefDistance) * props->RolloffFactor *
            Listener.Params.MetersPerUnit};
        if(props->AirAbsorptionFactor > 0.0f)
        {
            const float hfattn{std::pow(AirAbsorbGainHF, meters_base*props->AirAbsorptionFactor)};
            DryGain.HF *= hfattn;
            std::for_each(std::begin(WetGain), std::begin(WetGain)+NumSends,
                [hfattn](GainTriplet &gain) noexcept -> void { gain.HF *= hfattn; });
        }

        if(props->WetGainAuto)
        {
            /* Apply a decay-time transformation to the wet path, based on the
             * source distance in meters. The initial decay of the reverb
             * effect is calculated and applied to the wet path.
             */
            for(ALuint i{0};i < NumSends;i++)
            {
                if(!(DecayDistance[i].Base > 0.0f))
                    continue;

                const float gain{std::pow(ReverbDecayGain, meters_base/DecayDistance[i].Base)};
                WetGain[i].Base *= gain;
                /* Yes, the wet path's air absorption is applied with
                 * WetGainAuto on, rather than WetGainHFAuto.
                 */
                if(gain > 0.0f)
                {
                    float gainhf{std::pow(ReverbDecayGain, meters_base/DecayDistance[i].HF)};
                    WetGain[i].HF *= minf(gainhf / gain, 1.0f);
                    float gainlf{std::pow(ReverbDecayGain, meters_base/DecayDistance[i].LF)};
                    WetGain[i].LF *= minf(gainlf / gain, 1.0f);
                }
            }
        }
    }


    /* Initial source pitch */
    float Pitch{props->Pitch};

    /* Calculate velocity-based doppler effect */
    float DopplerFactor{props->DopplerFactor * Listener.Params.DopplerFactor};
    if(DopplerFactor > 0.0f)
    {
        const alu::Vector &lvelocity = Listener.Params.Velocity;
        float vss{aluDotproduct(Velocity, ToSource) * -DopplerFactor};
        float vls{aluDotproduct(lvelocity, ToSource) * -DopplerFactor};

        const float SpeedOfSound{Listener.Params.SpeedOfSound};
        if(!(vls < SpeedOfSound))
        {
            /* Listener moving away from the source at the speed of sound.
             * Sound waves can't catch it.
             */
            Pitch = 0.0f;
        }
        else if(!(vss < SpeedOfSound))
        {
            /* Source moving toward the listener at the speed of sound. Sound
             * waves bunch up to extreme frequencies.
             */
            Pitch = std::numeric_limits<float>::infinity();
        }
        else
        {
            /* Source and listener movement is nominal. Calculate the proper
             * doppler shift.
             */
            Pitch *= (SpeedOfSound-vls) / (SpeedOfSound-vss);
        }
    }

    /* Adjust pitch based on the buffer and output frequencies, and calculate
     * fixed-point stepping value.
     */
    Pitch *= static_cast<float>(voice->mFrequency) / static_cast<float>(Device->Frequency);
    if(Pitch > float{MAX_PITCH})
        voice->mStep = MAX_PITCH<<MixerFracBits;
    else
        voice->mStep = maxu(fastf2u(Pitch * MixerFracOne), 1);
    voice->mResampler = PrepareResampler(props->mResampler, voice->mStep, &voice->mResampleState);

    float spread{0.0f};
    if(props->Radius > Distance)
        spread = al::MathDefs<float>::Tau() - Distance/props->Radius*al::MathDefs<float>::Pi();
    else if(Distance > 0.0f)
        spread = std::asin(props->Radius/Distance) * 2.0f;

    CalcPanningAndFilters(voice, ToSource[0], ToSource[1], ToSource[2]*ZScale,
        Distance*Listener.Params.MetersPerUnit, spread, DryGain, WetGain, SendSlots, props,
        Listener, Device);
}

void CalcSourceParams(Voice *voice, ALCcontext *context, bool force)
{
    VoicePropsItem *props{voice->mUpdate.exchange(nullptr, std::memory_order_acq_rel)};
    if(!props && !force) return;

    if(props)
    {
        voice->mProps = *props;

        AtomicReplaceHead(context->mFreeVoiceProps, props);
    }

    if((voice->mProps.DirectChannels != DirectMode::Off && voice->mFmtChannels != FmtMono
            && voice->mFmtChannels != FmtBFormat2D && voice->mFmtChannels != FmtBFormat3D)
        || voice->mProps.mSpatializeMode==SpatializeMode::Off
        || (voice->mProps.mSpatializeMode==SpatializeMode::Auto && voice->mFmtChannels != FmtMono))
        CalcNonAttnSourceParams(voice, &voice->mProps, context);
    else
        CalcAttnSourceParams(voice, &voice->mProps, context);
}


void SendSourceStateEvent(ALCcontext *context, ALuint id, ALenum state)
{
    RingBuffer *ring{context->mAsyncEvents.get()};
    auto evt_vec = ring->getWriteVector();
    if(evt_vec.first.len < 1) return;

    AsyncEvent *evt{::new(evt_vec.first.buf) AsyncEvent{EventType_SourceStateChange}};
    evt->u.srcstate.id = id;
    evt->u.srcstate.state = state;

    ring->writeAdvance(1);
}

void ProcessVoiceChanges(ALCcontext *ctx)
{
    VoiceChange *cur{ctx->mCurrentVoiceChange.load(std::memory_order_acquire)};
    VoiceChange *next{cur->mNext.load(std::memory_order_acquire)};
    if(!next) return;

    const ALbitfieldSOFT enabledevt{ctx->mEnabledEvts.load(std::memory_order_acquire)};
    do {
        cur = next;

        bool sendevt{false};
        if(cur->mState == AL_INITIAL || cur->mState == AL_STOPPED)
        {
            if(Voice *voice{cur->mVoice})
            {
                voice->mCurrentBuffer.store(nullptr, std::memory_order_relaxed);
                voice->mLoopBuffer.store(nullptr, std::memory_order_relaxed);
                voice->mSourceID.store(0u, std::memory_order_relaxed);
                Voice::State oldvstate{Voice::Playing};
                sendevt = voice->mPlayState.compare_exchange_strong(oldvstate, Voice::Stopping,
                    std::memory_order_relaxed, std::memory_order_acquire);
                voice->mPendingChange.store(false, std::memory_order_release);
            }
            /* AL_INITIAL state change events are always sent, even if the
             * voice is already stopped or even if there is no voice.
             */
            sendevt |= (cur->mState == AL_INITIAL);
        }
        else if(cur->mState == AL_PAUSED)
        {
            Voice *voice{cur->mVoice};
            Voice::State oldvstate{Voice::Playing};
            sendevt = voice->mPlayState.compare_exchange_strong(oldvstate, Voice::Stopping,
                std::memory_order_release, std::memory_order_acquire);
        }
        else if(cur->mState == AL_PLAYING)
        {
            /* NOTE: When playing a voice, sending a source state change event
             * depends if there's an old voice to stop and if that stop is
             * successful. If there is no old voice, a playing event is always
             * sent. If there is an old voice, an event is sent only if the
             * voice is already stopped.
             */
            if(Voice *oldvoice{cur->mOldVoice})
            {
                oldvoice->mCurrentBuffer.store(nullptr, std::memory_order_relaxed);
                oldvoice->mLoopBuffer.store(nullptr, std::memory_order_relaxed);
                oldvoice->mSourceID.store(0u, std::memory_order_relaxed);
                Voice::State oldvstate{Voice::Playing};
                sendevt = !oldvoice->mPlayState.compare_exchange_strong(oldvstate, Voice::Stopping,
                    std::memory_order_relaxed, std::memory_order_acquire);
                oldvoice->mPendingChange.store(false, std::memory_order_release);
            }
            else
                sendevt = true;

            Voice *voice{cur->mVoice};
            voice->mPlayState.store(Voice::Playing, std::memory_order_release);
        }
        else if(cur->mState == AL_SAMPLE_OFFSET)
        {
            /* Changing a voice offset never sends a source change event. */
            Voice *oldvoice{cur->mOldVoice};
            oldvoice->mCurrentBuffer.store(nullptr, std::memory_order_relaxed);
            oldvoice->mLoopBuffer.store(nullptr, std::memory_order_relaxed);
            /* If there's no sourceID, the old voice finished so don't start
             * the new one at its new offset.
             */
            if(oldvoice->mSourceID.exchange(0u, std::memory_order_relaxed) != 0u)
            {
                /* Otherwise, set the voice to stopping if it's not already (it
                 * might already be, if paused), and play the new voice as
                 * appropriate.
                 */
                Voice::State oldvstate{Voice::Playing};
                oldvoice->mPlayState.compare_exchange_strong(oldvstate, Voice::Stopping,
                    std::memory_order_relaxed, std::memory_order_acquire);

                Voice *voice{cur->mVoice};
                voice->mPlayState.store((oldvstate == Voice::Playing) ? Voice::Playing
                    : Voice::Stopped, std::memory_order_release);
            }
            oldvoice->mPendingChange.store(false, std::memory_order_release);
        }
        if(sendevt && (enabledevt&EventType_SourceStateChange))
            SendSourceStateEvent(ctx, cur->mSourceID, cur->mState);

        next = cur->mNext.load(std::memory_order_acquire);
    } while(next);
    ctx->mCurrentVoiceChange.store(cur, std::memory_order_release);
}

void ProcessParamUpdates(ALCcontext *ctx, const ALeffectslotArray &slots,
    const al::span<Voice*> voices)
{
    ProcessVoiceChanges(ctx);

    IncrementRef(ctx->mUpdateCount);
    if LIKELY(!ctx->mHoldUpdates.load(std::memory_order_acquire))
    {
        bool force{CalcContextParams(ctx)};
        force |= CalcListenerParams(ctx);
        auto sorted_slots = const_cast<ALeffectslot**>(slots.data() + slots.size());
        for(ALeffectslot *slot : slots)
            force |= CalcEffectSlotParams(slot, sorted_slots, ctx);

        for(Voice *voice : voices)
        {
            /* Only update voices that have a source. */
            if(voice->mSourceID.load(std::memory_order_relaxed) != 0)
                CalcSourceParams(voice, ctx, force);
        }
    }
    IncrementRef(ctx->mUpdateCount);
}

void ProcessContexts(ALCdevice *device, const ALuint SamplesToDo)
{
    ASSUME(SamplesToDo > 0);

    for(ALCcontext *ctx : *device->mContexts.load(std::memory_order_acquire))
    {
        const ALeffectslotArray &auxslots = *ctx->mActiveAuxSlots.load(std::memory_order_acquire);
        const al::span<Voice*> voices{ctx->getVoicesSpanAcquired()};

        /* Process pending propery updates for objects on the context. */
        ProcessParamUpdates(ctx, auxslots, voices);

        /* Clear auxiliary effect slot mixing buffers. */
        for(ALeffectslot *slot : auxslots)
        {
            for(auto &buffer : slot->Wet.Buffer)
                buffer.fill(0.0f);
        }

        /* Process voices that have a playing source. */
        for(Voice *voice : voices)
        {
            const Voice::State vstate{voice->mPlayState.load(std::memory_order_acquire)};
            if(vstate != Voice::Stopped && vstate != Voice::Pending)
                voice->mix(vstate, ctx, SamplesToDo);
        }

        /* Process effects. */
        if(const size_t num_slots{auxslots.size()})
        {
            auto slots = auxslots.data();
            auto slots_end = slots + num_slots;

            /* First sort the slots into extra storage, so that effects come
             * before their effect target (or their targets' target).
             */
            auto sorted_slots = const_cast<ALeffectslot**>(slots_end);
            auto sorted_slots_end = sorted_slots;
            if(*sorted_slots)
            {
                /* Skip sorting if it has already been done. */
                sorted_slots_end += num_slots;
                goto skip_sorting;
            }

            *sorted_slots_end = *slots;
            ++sorted_slots_end;
            while(++slots != slots_end)
            {
                auto in_chain = [](const ALeffectslot *s1, const ALeffectslot *s2) noexcept -> bool
                {
                    while((s1=s1->Params.Target) != nullptr) {
                        if(s1 == s2) return true;
                    }
                    return false;
                };

                /* If this effect slot targets an effect slot already in the
                 * list (i.e. slots outputs to something in sorted_slots),
                 * directly or indirectly, insert it prior to that element.
                 */
                auto checker = sorted_slots;
                do {
                    if(in_chain(*slots, *checker)) break;
                } while(++checker != sorted_slots_end);

                checker = std::move_backward(checker, sorted_slots_end, sorted_slots_end+1);
                *--checker = *slots;
                ++sorted_slots_end;
            }

        skip_sorting:
            auto process_effect = [SamplesToDo](const ALeffectslot *slot) -> void
            {
                EffectState *state{slot->Params.mEffectState};
                state->process(SamplesToDo, slot->Wet.Buffer, state->mOutTarget);
            };
            std::for_each(sorted_slots, sorted_slots_end, process_effect);
        }

        /* Signal the event handler if there are any events to read. */
        RingBuffer *ring{ctx->mAsyncEvents.get()};
        if(ring->readSpace() > 0)
            ctx->mEventSem.post();
    }
}


void ApplyDistanceComp(const al::span<FloatBufferLine> Samples, const size_t SamplesToDo,
    const DistanceComp::DistData *distcomp)
{
    ASSUME(SamplesToDo > 0);

    for(auto &chanbuffer : Samples)
    {
        const float gain{distcomp->Gain};
        const size_t base{distcomp->Length};
        float *distbuf{al::assume_aligned<16>(distcomp->Buffer)};
        ++distcomp;

        if(base < 1)
            continue;

        float *inout{al::assume_aligned<16>(chanbuffer.data())};
        auto inout_end = inout + SamplesToDo;
        if LIKELY(SamplesToDo >= base)
        {
            auto delay_end = std::rotate(inout, inout_end - base, inout_end);
            std::swap_ranges(inout, delay_end, distbuf);
        }
        else
        {
            auto delay_start = std::swap_ranges(inout, inout_end, distbuf);
            std::rotate(distbuf, delay_start, distbuf + base);
        }
        std::transform(inout, inout_end, inout, std::bind(std::multiplies<float>{}, _1, gain));
    }
}

void ApplyDither(const al::span<FloatBufferLine> Samples, ALuint *dither_seed,
    const float quant_scale, const size_t SamplesToDo)
{
    ASSUME(SamplesToDo > 0);

    /* Dithering. Generate whitenoise (uniform distribution of random values
     * between -1 and +1) and add it to the sample values, after scaling up to
     * the desired quantization depth amd before rounding.
     */
    const float invscale{1.0f / quant_scale};
    ALuint seed{*dither_seed};
    auto dither_sample = [&seed,invscale,quant_scale](const float sample) noexcept -> float
    {
        float val{sample * quant_scale};
        ALuint rng0{dither_rng(&seed)};
        ALuint rng1{dither_rng(&seed)};
        val += static_cast<float>(rng0*(1.0/UINT_MAX) - rng1*(1.0/UINT_MAX));
        return fast_roundf(val) * invscale;
    };
    for(FloatBufferLine &inout : Samples)
        std::transform(inout.begin(), inout.begin()+SamplesToDo, inout.begin(), dither_sample);
    *dither_seed = seed;
}


/* Base template left undefined. Should be marked =delete, but Clang 3.8.1
 * chokes on that given the inline specializations.
 */
template<typename T>
inline T SampleConv(float) noexcept;

template<> inline float SampleConv(float val) noexcept
{ return val; }
template<> inline int32_t SampleConv(float val) noexcept
{
    /* Floats have a 23-bit mantissa, plus an implied 1 bit and a sign bit.
     * This means a normalized float has at most 25 bits of signed precision.
     * When scaling and clamping for a signed 32-bit integer, these following
     * values are the best a float can give.
     */
    return fastf2i(clampf(val*2147483648.0f, -2147483648.0f, 2147483520.0f));
}
template<> inline int16_t SampleConv(float val) noexcept
{ return static_cast<int16_t>(fastf2i(clampf(val*32768.0f, -32768.0f, 32767.0f))); }
template<> inline int8_t SampleConv(float val) noexcept
{ return static_cast<int8_t>(fastf2i(clampf(val*128.0f, -128.0f, 127.0f))); }

/* Define unsigned output variations. */
template<> inline uint32_t SampleConv(float val) noexcept
{ return static_cast<uint32_t>(SampleConv<int32_t>(val)) + 2147483648u; }
template<> inline uint16_t SampleConv(float val) noexcept
{ return static_cast<uint16_t>(SampleConv<int16_t>(val) + 32768); }
template<> inline uint8_t SampleConv(float val) noexcept
{ return static_cast<uint8_t>(SampleConv<int8_t>(val) + 128); }

template<DevFmtType T>
void Write(const al::span<const FloatBufferLine> InBuffer, void *OutBuffer, const size_t Offset,
    const size_t SamplesToDo, const size_t FrameStep)
{
    using SampleType = typename DevFmtTypeTraits<T>::Type;

    ASSUME(FrameStep > 0);
    ASSUME(SamplesToDo > 0);

    SampleType *outbase = static_cast<SampleType*>(OutBuffer) + Offset*FrameStep;
    for(const FloatBufferLine &inbuf : InBuffer)
    {
        SampleType *out{outbase++};
        auto conv_sample = [FrameStep,&out](const float s) noexcept -> void
        {
            *out = SampleConv<SampleType>(s);
            out += FrameStep;
        };
        std::for_each(inbuf.begin(), inbuf.begin()+SamplesToDo, conv_sample);
    }
}

} // namespace

void ALCdevice::renderSamples(void *outBuffer, const ALuint numSamples, const size_t frameStep)
{
    FPUCtl mixer_mode{};
    for(ALuint written{0u};written < numSamples;)
    {
        const ALuint samplesToDo{minu(numSamples-written, BUFFERSIZE)};

        /* Clear main mixing buffers. */
        for(FloatBufferLine &buffer : MixBuffer)
            buffer.fill(0.0f);

        /* Increment the mix count at the start (lsb should now be 1). */
        IncrementRef(MixCount);

        /* Process and mix each context's sources and effects. */
        ProcessContexts(this, samplesToDo);

        /* Increment the clock time. Every second's worth of samples is
         * converted and added to clock base so that large sample counts don't
         * overflow during conversion. This also guarantees a stable
         * conversion.
         */
        SamplesDone += samplesToDo;
        ClockBase += std::chrono::seconds{SamplesDone / Frequency};
        SamplesDone %= Frequency;

        /* Increment the mix count at the end (lsb should now be 0). */
        IncrementRef(MixCount);

        /* Apply any needed post-process for finalizing the Dry mix to the
         * RealOut (Ambisonic decode, UHJ encode, etc).
         */
        postProcess(samplesToDo);

        /* Apply compression, limiting sample amplitude if needed or desired. */
        if(Limiter) Limiter->process(samplesToDo, RealOut.Buffer.data());

        /* Apply delays and attenuation for mismatched speaker distances. */
        ApplyDistanceComp(RealOut.Buffer, samplesToDo, ChannelDelay.as_span().cbegin());

        /* Apply dithering. The compressor should have left enough headroom for
         * the dither noise to not saturate.
         */
        if(DitherDepth > 0.0f)
            ApplyDither(RealOut.Buffer, &DitherSeed, DitherDepth, samplesToDo);

        if LIKELY(outBuffer)
        {
            /* Finally, interleave and convert samples, writing to the device's
             * output buffer.
             */
            switch(FmtType)
            {
#define HANDLE_WRITE(T) case T:                                               \
    Write<T>(RealOut.Buffer, outBuffer, written, samplesToDo, frameStep); break;
            HANDLE_WRITE(DevFmtByte)
            HANDLE_WRITE(DevFmtUByte)
            HANDLE_WRITE(DevFmtShort)
            HANDLE_WRITE(DevFmtUShort)
            HANDLE_WRITE(DevFmtInt)
            HANDLE_WRITE(DevFmtUInt)
            HANDLE_WRITE(DevFmtFloat)
#undef HANDLE_WRITE
            }
        }

        written += samplesToDo;
    }
}

void ALCdevice::handleDisconnect(const char *msg, ...)
{
    if(!Connected.exchange(false, std::memory_order_acq_rel))
        return;

    AsyncEvent evt{EventType_Disconnected};
    evt.u.user.type = AL_EVENT_TYPE_DISCONNECTED_SOFT;
    evt.u.user.id = 0;
    evt.u.user.param = 0;

    va_list args;
    va_start(args, msg);
    int msglen{vsnprintf(evt.u.user.msg, sizeof(evt.u.user.msg), msg, args)};
    va_end(args);

    if(msglen < 0 || static_cast<size_t>(msglen) >= sizeof(evt.u.user.msg))
        evt.u.user.msg[sizeof(evt.u.user.msg)-1] = 0;

    IncrementRef(MixCount);
    for(ALCcontext *ctx : *mContexts.load())
    {
        const ALbitfieldSOFT enabledevt{ctx->mEnabledEvts.load(std::memory_order_acquire)};
        if((enabledevt&EventType_Disconnected))
        {
            RingBuffer *ring{ctx->mAsyncEvents.get()};
            auto evt_data = ring->getWriteVector().first;
            if(evt_data.len > 0)
            {
                ::new(evt_data.buf) AsyncEvent{evt};
                ring->writeAdvance(1);
                ctx->mEventSem.post();
            }
        }

        auto voicelist = ctx->getVoicesSpanAcquired();
        auto stop_voice = [](Voice *voice) -> void
        {
            voice->mCurrentBuffer.store(nullptr, std::memory_order_relaxed);
            voice->mLoopBuffer.store(nullptr, std::memory_order_relaxed);
            voice->mSourceID.store(0u, std::memory_order_relaxed);
            voice->mPlayState.store(Voice::Stopped, std::memory_order_release);
        };
        std::for_each(voicelist.begin(), voicelist.end(), stop_voice);
    }
    IncrementRef(MixCount);
}
