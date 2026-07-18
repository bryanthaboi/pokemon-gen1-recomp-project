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

#include "voice.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <iterator>
#include <memory>
#include <new>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"

#include "al/buffer.h"
#include "al/event.h"
#include "al/source.h"
#include "alcmain.h"
#include "albyte.h"
#include "alconfig.h"
#include "alcontext.h"
#include "alnumeric.h"
#include "aloptional.h"
#include "alspan.h"
#include "alstring.h"
#include "alu.h"
#include "cpu_caps.h"
#include "devformat.h"
#include "filters/biquad.h"
#include "filters/nfc.h"
#include "filters/splitter.h"
#include "fmt_traits.h"
#include "hrtf.h"
#include "inprogext.h"
#include "logging.h"
#include "mixer/defs.h"
#include "opthelpers.h"
#include "ringbuffer.h"
#include "threads.h"
#include "vector.h"

struct CTag;
#ifdef HAVE_SSE
struct SSETag;
#endif
#ifdef HAVE_NEON
struct NEONTag;
#endif
struct CopyTag;


static_assert((BUFFERSIZE-1)/MAX_PITCH > 0, "MAX_PITCH is too large for BUFFERSIZE!");
static_assert((INT_MAX>>MixerFracBits)/MAX_PITCH > BUFFERSIZE,
    "MAX_PITCH and/or BUFFERSIZE are too large for MixerFracBits!");


Resampler ResamplerDefault{Resampler::Linear};

MixerFunc MixSamples{Mix_<CTag>};

namespace {

using HrtfMixerFunc = void(*)(const float *InSamples, float2 *AccumSamples, const ALuint IrSize,
    const MixHrtfFilter *hrtfparams, const size_t BufferSize);
using HrtfMixerBlendFunc = void(*)(const float *InSamples, float2 *AccumSamples,
    const ALuint IrSize, const HrtfFilter *oldparams, const MixHrtfFilter *newparams,
    const size_t BufferSize);

HrtfMixerFunc MixHrtfSamples{MixHrtf_<CTag>};
HrtfMixerBlendFunc MixHrtfBlendSamples{MixHrtfBlend_<CTag>};

inline MixerFunc SelectMixer()
{
#ifdef HAVE_NEON
    if((CPUCapFlags&CPU_CAP_NEON))
        return Mix_<NEONTag>;
#endif
#ifdef HAVE_SSE
    if((CPUCapFlags&CPU_CAP_SSE))
        return Mix_<SSETag>;
#endif
    return Mix_<CTag>;
}

inline HrtfMixerFunc SelectHrtfMixer()
{
#ifdef HAVE_NEON
    if((CPUCapFlags&CPU_CAP_NEON))
        return MixHrtf_<NEONTag>;
#endif
#ifdef HAVE_SSE
    if((CPUCapFlags&CPU_CAP_SSE))
        return MixHrtf_<SSETag>;
#endif
    return MixHrtf_<CTag>;
}

inline HrtfMixerBlendFunc SelectHrtfBlendMixer()
{
#ifdef HAVE_NEON
    if((CPUCapFlags&CPU_CAP_NEON))
        return MixHrtfBlend_<NEONTag>;
#endif
#ifdef HAVE_SSE
    if((CPUCapFlags&CPU_CAP_SSE))
        return MixHrtfBlend_<SSETag>;
#endif
    return MixHrtfBlend_<CTag>;
}

} // namespace


void aluInitMixer()
{
    if(auto resopt = ConfigValueStr(nullptr, nullptr, "resampler"))
    {
        struct ResamplerEntry {
            const char name[16];
            const Resampler resampler;
        };
        constexpr ResamplerEntry ResamplerList[]{
            { "none", Resampler::Point },
            { "point", Resampler::Point },
            { "linear", Resampler::Linear },
            { "cubic", Resampler::Cubic },
            { "bsinc12", Resampler::BSinc12 },
            { "fast_bsinc12", Resampler::FastBSinc12 },
            { "bsinc24", Resampler::BSinc24 },
            { "fast_bsinc24", Resampler::FastBSinc24 },
        };

        const char *str{resopt->c_str()};
        if(al::strcasecmp(str, "bsinc") == 0)
        {
            WARN("Resampler option \"%s\" is deprecated, using bsinc12\n", str);
            str = "bsinc12";
        }
        else if(al::strcasecmp(str, "sinc4") == 0 || al::strcasecmp(str, "sinc8") == 0)
        {
            WARN("Resampler option \"%s\" is deprecated, using cubic\n", str);
            str = "cubic";
        }

        auto iter = std::find_if(std::begin(ResamplerList), std::end(ResamplerList),
            [str](const ResamplerEntry &entry) -> bool
            { return al::strcasecmp(str, entry.name) == 0; });
        if(iter == std::end(ResamplerList))
            ERR("Invalid resampler: %s\n", str);
        else
            ResamplerDefault = iter->resampler;
    }

    MixSamples = SelectMixer();
    MixHrtfBlendSamples = SelectHrtfBlendMixer();
    MixHrtfSamples = SelectHrtfMixer();
}


namespace {

void SendSourceStoppedEvent(ALCcontext *context, ALuint id)
{
    RingBuffer *ring{context->mAsyncEvents.get()};
    auto evt_vec = ring->getWriteVector();
    if(evt_vec.first.len < 1) return;

    AsyncEvent *evt{::new(evt_vec.first.buf) AsyncEvent{EventType_SourceStateChange}};
    evt->u.srcstate.id = id;
    evt->u.srcstate.state = AL_STOPPED;

    ring->writeAdvance(1);
}


const float *DoFilters(BiquadFilter &lpfilter, BiquadFilter &hpfilter, float *dst,
    const al::span<const float> src, int type)
{
    switch(type)
    {
    case AF_None:
        lpfilter.clear();
        hpfilter.clear();
        break;

    case AF_LowPass:
        lpfilter.process(src, dst);
        hpfilter.clear();
        return dst;
    case AF_HighPass:
        lpfilter.clear();
        hpfilter.process(src, dst);
        return dst;

    case AF_BandPass:
        DualBiquad{lpfilter, hpfilter}.process(src, dst);
        return dst;
    }
    return src.data();
}


void LoadSamples(float *RESTRICT dst, const al::byte *src, const size_t srcstep, FmtType srctype,
    const size_t samples) noexcept
{
#define HANDLE_FMT(T)  case T: al::LoadSampleArray<T>(dst, src, srcstep, samples); break
    switch(srctype)
    {
    HANDLE_FMT(FmtUByte);
    HANDLE_FMT(FmtShort);
    HANDLE_FMT(FmtFloat);
    HANDLE_FMT(FmtDouble);
    HANDLE_FMT(FmtMulaw);
    HANDLE_FMT(FmtAlaw);
    }
#undef HANDLE_FMT
}

float *LoadBufferStatic(ALbufferlistitem *BufferListItem, ALbufferlistitem *&BufferLoopItem,
    const size_t NumChannels, const size_t SampleSize, const size_t chan, size_t DataPosInt,
    al::span<float> SrcBuffer)
{
    const ALbuffer *Buffer{BufferListItem->mBuffer};
    const ALuint LoopStart{Buffer->LoopStart};
    const ALuint LoopEnd{Buffer->LoopEnd};
    ASSUME(LoopEnd > LoopStart);

    /* If current pos is beyond the loop range, do not loop */
    if(!BufferLoopItem || DataPosInt >= LoopEnd)
    {
        BufferLoopItem = nullptr;

        /* Load what's left to play from the buffer */
        const size_t DataRem{minz(SrcBuffer.size(), Buffer->mBuffer.mSampleLen-DataPosInt)};

        const al::byte *Data{Buffer->mBuffer.mData.data()};
        Data += (DataPosInt*NumChannels + chan)*SampleSize;

        LoadSamples(SrcBuffer.data(), Data, NumChannels, Buffer->mBuffer.mType, DataRem);
        SrcBuffer = SrcBuffer.subspan(DataRem);
    }
    else
    {
        /* Load what's left of this loop iteration */
        const size_t DataRem{minz(SrcBuffer.size(), LoopEnd-DataPosInt)};

        const al::byte *Data{Buffer->mBuffer.mData.data()};
        Data += (DataPosInt*NumChannels + chan)*SampleSize;

        LoadSamples(SrcBuffer.data(), Data, NumChannels, Buffer->mBuffer.mType, DataRem);
        SrcBuffer = SrcBuffer.subspan(DataRem);

        /* Load any repeats of the loop we can to fill the buffer. */
        const auto LoopSize = static_cast<size_t>(LoopEnd - LoopStart);
        while(!SrcBuffer.empty())
        {
            const size_t DataSize{minz(SrcBuffer.size(), LoopSize)};

            Data = Buffer->mBuffer.mData.data() + (LoopStart*NumChannels + chan)*SampleSize;

            LoadSamples(SrcBuffer.data(), Data, NumChannels, Buffer->mBuffer.mType, DataSize);
            SrcBuffer = SrcBuffer.subspan(DataSize);
        }
    }
    return SrcBuffer.begin();
}

float *LoadBufferCallback(ALbufferlistitem *BufferListItem, const size_t NumChannels,
    const size_t SampleSize, const size_t chan, size_t NumCallbackSamples,
    al::span<float> SrcBuffer)
{
    const ALbuffer *Buffer{BufferListItem->mBuffer};

    /* Load what's left to play from the buffer */
    const size_t DataRem{minz(SrcBuffer.size(), NumCallbackSamples)};

    const al::byte *Data{Buffer->mBuffer.mData.data() + chan*SampleSize};

    LoadSamples(SrcBuffer.data(), Data, NumChannels, Buffer->mBuffer.mType, DataRem);
    SrcBuffer = SrcBuffer.subspan(DataRem);

    return SrcBuffer.begin();
}

float *LoadBufferQueue(ALbufferlistitem *BufferListItem, ALbufferlistitem *BufferLoopItem,
    const size_t NumChannels, const size_t SampleSize, const size_t chan, size_t DataPosInt,
    al::span<float> SrcBuffer)
{
    /* Crawl the buffer queue to fill in the temp buffer */
    while(BufferListItem && !SrcBuffer.empty())
    {
        ALbuffer *Buffer{BufferListItem->mBuffer};
        if(!(Buffer && DataPosInt < Buffer->mBuffer.mSampleLen))
        {
            if(Buffer) DataPosInt -= Buffer->mBuffer.mSampleLen;
            BufferListItem = BufferListItem->mNext.load(std::memory_order_acquire);
            if(!BufferListItem) BufferListItem = BufferLoopItem;
            continue;
        }

        const size_t DataSize{minz(SrcBuffer.size(), Buffer->mBuffer.mSampleLen-DataPosInt)};

        const al::byte *Data{Buffer->mBuffer.mData.data()};
        Data += (DataPosInt*NumChannels + chan)*SampleSize;

        LoadSamples(SrcBuffer.data(), Data, NumChannels, Buffer->mBuffer.mType, DataSize);
        SrcBuffer = SrcBuffer.subspan(DataSize);
        if(SrcBuffer.empty()) break;

        DataPosInt = 0;
        BufferListItem = BufferListItem->mNext.load(std::memory_order_acquire);
        if(!BufferListItem) BufferListItem = BufferLoopItem;
    }

    return SrcBuffer.begin();
}


void DoHrtfMix(const float *samples, const ALuint DstBufferSize, DirectParams &parms,
    const float TargetGain, const ALuint Counter, ALuint OutPos, const ALuint IrSize,
    ALCdevice *Device)
{
    auto &HrtfSamples = Device->HrtfSourceData;
    /* Source HRTF mixing needs to include the direct delay so it remains
     * aligned with the direct mix's HRTF filtering.
     */
    float2 *AccumSamples{Device->HrtfAccumData + HRTF_DIRECT_DELAY};

    /* Copy the HRTF history and new input samples into a temp buffer. */
    auto src_iter = std::copy(parms.Hrtf.History.begin(), parms.Hrtf.History.end(),
        std::begin(HrtfSamples));
    std::copy_n(samples, DstBufferSize, src_iter);
    /* Copy the last used samples back into the history buffer for later. */
    std::copy_n(std::begin(HrtfSamples) + DstBufferSize, parms.Hrtf.History.size(),
        parms.Hrtf.History.begin());

    /* If fading and this is the first mixing pass, fade between the IRs. */
    ALuint fademix{0u};
    if(Counter && OutPos == 0)
    {
        fademix = minu(DstBufferSize, Counter);

        float gain{TargetGain};

        /* The new coefficients need to fade in completely since they're
         * replacing the old ones. To keep the gain fading consistent,
         * interpolate between the old and new target gains given how much of
         * the fade time this mix handles.
         */
        if(Counter > fademix)
        {
            const float a{static_cast<float>(fademix) / static_cast<float>(Counter)};
            gain = lerp(parms.Hrtf.Old.Gain, TargetGain, a);
        }
        MixHrtfFilter hrtfparams;
        hrtfparams.Coeffs = &parms.Hrtf.Target.Coeffs;
        hrtfparams.Delay = parms.Hrtf.Target.Delay;
        hrtfparams.Gain = 0.0f;
        hrtfparams.GainStep = gain / static_cast<float>(fademix);

        MixHrtfBlendSamples(HrtfSamples, AccumSamples+OutPos, IrSize, &parms.Hrtf.Old, &hrtfparams,
            fademix);
        /* Update the old parameters with the result. */
        parms.Hrtf.Old = parms.Hrtf.Target;
        parms.Hrtf.Old.Gain = gain;
        OutPos += fademix;
    }

    if(fademix < DstBufferSize)
    {
        const ALuint todo{DstBufferSize - fademix};
        float gain{TargetGain};

        /* Interpolate the target gain if the gain fading lasts longer than
         * this mix.
         */
        if(Counter > DstBufferSize)
        {
            const float a{static_cast<float>(todo) / static_cast<float>(Counter-fademix)};
            gain = lerp(parms.Hrtf.Old.Gain, TargetGain, a);
        }

        MixHrtfFilter hrtfparams;
        hrtfparams.Coeffs = &parms.Hrtf.Target.Coeffs;
        hrtfparams.Delay = parms.Hrtf.Target.Delay;
        hrtfparams.Gain = parms.Hrtf.Old.Gain;
        hrtfparams.GainStep = (gain - parms.Hrtf.Old.Gain) / static_cast<float>(todo);
        MixHrtfSamples(HrtfSamples+fademix, AccumSamples+OutPos, IrSize, &hrtfparams, todo);
        /* Store the now-current gain for next time. */
        parms.Hrtf.Old.Gain = gain;
    }
}

void DoNfcMix(const al::span<const float> samples, FloatBufferLine *OutBuffer, DirectParams &parms,
    const float *TargetGains, const ALuint Counter, const ALuint OutPos, ALCdevice *Device)
{
    using FilterProc = void (NfcFilter::*)(const al::span<const float>, float*);
    static constexpr FilterProc NfcProcess[MAX_AMBI_ORDER+1]{
        nullptr, &NfcFilter::process1, &NfcFilter::process2, &NfcFilter::process3};

    float *CurrentGains{parms.Gains.Current.data()};
    MixSamples(samples, {OutBuffer, 1u}, CurrentGains, TargetGains, Counter, OutPos);
    ++OutBuffer;
    ++CurrentGains;
    ++TargetGains;

    const al::span<float> nfcsamples{Device->NfcSampleData, samples.size()};
    size_t order{1};
    while(const size_t chancount{Device->NumChannelsPerOrder[order]})
    {
        (parms.NFCtrlFilter.*NfcProcess[order])(samples, nfcsamples.data());
        MixSamples(nfcsamples, {OutBuffer, chancount}, CurrentGains, TargetGains, Counter, OutPos);
        OutBuffer += chancount;
        CurrentGains += chancount;
        TargetGains += chancount;
        if(++order == MAX_AMBI_ORDER+1)
            break;
    }
}

} // namespace

void Voice::mix(const State vstate, ALCcontext *Context, const ALuint SamplesToDo)
{
    static constexpr std::array<float,MAX_OUTPUT_CHANNELS> SilentTarget{};

    ASSUME(SamplesToDo > 0);

    /* Get voice info */
    ALuint DataPosInt{mPosition.load(std::memory_order_relaxed)};
    ALuint DataPosFrac{mPositionFrac.load(std::memory_order_relaxed)};
    ALbufferlistitem *BufferListItem{mCurrentBuffer.load(std::memory_order_relaxed)};
    ALbufferlistitem *BufferLoopItem{mLoopBuffer.load(std::memory_order_relaxed)};
    const ALuint SampleSize{mSampleSize};
    const ALuint increment{mStep};
    if UNLIKELY(increment < 1)
    {
        /* If the voice is supposed to be stopping but can't be mixed, just
         * stop it before bailing.
         */
        if(vstate == Stopping)
            mPlayState.store(Stopped, std::memory_order_release);
        return;
    }

    ASSUME(SampleSize > 0);

    const size_t FrameSize{mChans.size() * SampleSize};
    ASSUME(FrameSize > 0);

    ALCdevice *Device{Context->mDevice.get()};
    const ALuint NumSends{Device->NumAuxSends};
    const ALuint IrSize{Device->mHrtf ? Device->mHrtf->irSize : 0};

    ResamplerFunc Resample{(increment == MixerFracOne && DataPosFrac == 0) ?
                           Resample_<CopyTag,CTag> : mResampler};

    ALuint Counter{(mFlags&VoiceIsFading) ? SamplesToDo : 0};
    if(!Counter)
    {
        /* No fading, just overwrite the old/current params. */
        for(auto &chandata : mChans)
        {
            {
                DirectParams &parms = chandata.mDryParams;
                if(!(mFlags&VoiceHasHrtf))
                    parms.Gains.Current = parms.Gains.Target;
                else
                    parms.Hrtf.Old = parms.Hrtf.Target;
            }
            for(ALuint send{0};send < NumSends;++send)
            {
                if(mSend[send].Buffer.empty())
                    continue;

                SendParams &parms = chandata.mWetParams[send];
                parms.Gains.Current = parms.Gains.Target;
            }
        }
    }

    ALuint buffers_done{0u};
    ALuint OutPos{0u};
    do {
        /* Figure out how many buffer samples will be needed */
        ALuint DstBufferSize{SamplesToDo - OutPos};
        ALuint SrcBufferSize;

        if(increment <= MixerFracOne)
        {
            /* Calculate the last written dst sample pos. */
            uint64_t DataSize64{DstBufferSize - 1};
            /* Calculate the last read src sample pos. */
            DataSize64 = (DataSize64*increment + DataPosFrac) >> MixerFracBits;
            /* +1 to get the src sample count, include padding. */
            DataSize64 += 1 + MAX_RESAMPLER_PADDING;

            /* Result is guaranteed to be <= BUFFERSIZE+MAX_RESAMPLER_PADDING
             * since we won't use more src samples than dst samples+padding.
             */
            SrcBufferSize = static_cast<ALuint>(DataSize64);
        }
        else
        {
            uint64_t DataSize64{DstBufferSize};
            /* Calculate the end src sample pos, include padding. */
            DataSize64 = (DataSize64*increment + DataPosFrac) >> MixerFracBits;
            DataSize64 += MAX_RESAMPLER_PADDING;

            if(DataSize64 <= BUFFERSIZE + MAX_RESAMPLER_PADDING)
                SrcBufferSize = static_cast<ALuint>(DataSize64);
            else
            {
                /* If the source size got saturated, we can't fill the desired
                 * dst size. Figure out how many samples we can actually mix.
                 */
                SrcBufferSize = BUFFERSIZE + MAX_RESAMPLER_PADDING;

                DataSize64 = SrcBufferSize - MAX_RESAMPLER_PADDING;
                DataSize64 = ((DataSize64<<MixerFracBits) - DataPosFrac) / increment;
                if(DataSize64 < DstBufferSize)
                {
                    /* Some mixers require being 16-byte aligned, so also limit
                     * to a multiple of 4 samples to maintain alignment.
                     */
                    DstBufferSize = static_cast<ALuint>(DataSize64) & ~3u;
                }
            }
        }

        if((mFlags&(VoiceIsCallback|VoiceCallbackStopped)) == VoiceIsCallback && BufferListItem)
        {
            ALbuffer *buffer{BufferListItem->mBuffer};

            /* Exclude resampler pre-padding from the needed size. */
            const ALuint toLoad{SrcBufferSize - (MAX_RESAMPLER_PADDING>>1)};
            if(toLoad > mNumCallbackSamples)
            {
                const size_t byteOffset{mNumCallbackSamples*FrameSize};
                const size_t needBytes{toLoad*FrameSize - byteOffset};

                const ALsizei gotBytes{buffer->mBuffer.mCallback(buffer->mBuffer.mUserData,
                    &buffer->mBuffer.mData[byteOffset], static_cast<ALsizei>(needBytes))};
                if(gotBytes < 1)
                    mFlags |= VoiceCallbackStopped;
                else if(static_cast<ALuint>(gotBytes) < needBytes)
                {
                    mFlags |= VoiceCallbackStopped;
                    mNumCallbackSamples += static_cast<ALuint>(static_cast<ALuint>(gotBytes) /
                        FrameSize);
                }
                else
                    mNumCallbackSamples = toLoad;
            }
        }

        ASSUME(DstBufferSize > 0);
        for(auto &chandata : mChans)
        {
            const size_t num_chans{mChans.size()};
            const auto chan = static_cast<size_t>(std::distance(mChans.data(),
                std::addressof(chandata)));
            const al::span<float> SrcData{Device->SourceData, SrcBufferSize};

            /* Load the previous samples into the source data first, then load
             * what we can from the buffer queue.
             */
            auto srciter = std::copy_n(chandata.mPrevSamples.begin(), MAX_RESAMPLER_PADDING>>1,
                SrcData.begin());

            if UNLIKELY(!BufferListItem)
                srciter = std::copy(chandata.mPrevSamples.begin()+(MAX_RESAMPLER_PADDING>>1),
                    chandata.mPrevSamples.end(), srciter);
            else if((mFlags&VoiceIsStatic))
                srciter = LoadBufferStatic(BufferListItem, BufferLoopItem, num_chans,
                    SampleSize, chan, DataPosInt, {srciter, SrcData.end()});
            else if((mFlags&VoiceIsCallback))
                srciter = LoadBufferCallback(BufferListItem, num_chans, SampleSize, chan,
                    mNumCallbackSamples, {srciter, SrcData.end()});
            else
                srciter = LoadBufferQueue(BufferListItem, BufferLoopItem, num_chans,
                    SampleSize, chan, DataPosInt, {srciter, SrcData.end()});

            if UNLIKELY(srciter != SrcData.end())
            {
                /* If the source buffer wasn't filled, copy the last sample for
                 * the remaining buffer. Ideally it should have ended with
                 * silence, but if not the gain fading should help avoid clicks
                 * from sudden amplitude changes.
                 */
                const float sample{*(srciter-1)};
                std::fill(srciter, SrcData.end(), sample);
            }

            /* Store the last source samples used for next time. */
            std::copy_n(&SrcData[(increment*DstBufferSize + DataPosFrac)>>MixerFracBits],
                chandata.mPrevSamples.size(), chandata.mPrevSamples.begin());

            /* Resample, then apply ambisonic upsampling as needed. */
            const float *ResampledData{Resample(&mResampleState,
                &SrcData[MAX_RESAMPLER_PADDING>>1], DataPosFrac, increment,
                {Device->ResampledData, DstBufferSize})};
            if((mFlags&VoiceIsAmbisonic))
            {
                const float hfscale{chandata.mAmbiScale};
                /* Beware the evil const_cast. It's safe since it's pointing to
                 * either SourceData or ResampledData (both non-const), but the
                 * resample method takes the source as const float* and may
                 * return it without copying to output, making it currently
                 * unavoidable.
                 */
                const al::span<float> samples{const_cast<float*>(ResampledData), DstBufferSize};
                chandata.mAmbiSplitter.processHfScale(samples, hfscale);
            }

            /* Now filter and mix to the appropriate outputs. */
            float (&FilterBuf)[BUFFERSIZE] = Device->FilteredData;
            {
                DirectParams &parms = chandata.mDryParams;
                const float *samples{DoFilters(parms.LowPass, parms.HighPass, FilterBuf,
                    {ResampledData, DstBufferSize}, mDirect.FilterType)};

                if((mFlags&VoiceHasHrtf))
                {
                    const float TargetGain{UNLIKELY(vstate == Stopping) ? 0.0f :
                        parms.Hrtf.Target.Gain};
                    DoHrtfMix(samples, DstBufferSize, parms, TargetGain, Counter, OutPos, IrSize,
                        Device);
                }
                else if((mFlags&VoiceHasNfc))
                {
                    const float *TargetGains{UNLIKELY(vstate == Stopping) ? SilentTarget.data()
                        : parms.Gains.Target.data()};
                    DoNfcMix({samples, DstBufferSize}, mDirect.Buffer.data(), parms, TargetGains,
                        Counter, OutPos, Device);
                }
                else
                {
                    const float *TargetGains{UNLIKELY(vstate == Stopping) ? SilentTarget.data()
                        : parms.Gains.Target.data()};
                    MixSamples({samples, DstBufferSize}, mDirect.Buffer,
                        parms.Gains.Current.data(), TargetGains, Counter, OutPos);
                }
            }

            for(ALuint send{0};send < NumSends;++send)
            {
                if(mSend[send].Buffer.empty())
                    continue;

                SendParams &parms = chandata.mWetParams[send];
                const float *samples{DoFilters(parms.LowPass, parms.HighPass, FilterBuf,
                    {ResampledData, DstBufferSize}, mSend[send].FilterType)};

                const float *TargetGains{UNLIKELY(vstate == Stopping) ? SilentTarget.data()
                    : parms.Gains.Target.data()};
                MixSamples({samples, DstBufferSize}, mSend[send].Buffer,
                    parms.Gains.Current.data(), TargetGains, Counter, OutPos);
            }
        }
        /* Update positions */
        DataPosFrac += increment*DstBufferSize;
        const ALuint SrcSamplesDone{DataPosFrac>>MixerFracBits};
        DataPosInt  += SrcSamplesDone;
        DataPosFrac &= MixerFracMask;

        OutPos += DstBufferSize;
        Counter = maxu(DstBufferSize, Counter) - DstBufferSize;

        if UNLIKELY(!BufferListItem)
        {
            /* Do nothing extra when there's no buffers. */
        }
        else if((mFlags&VoiceIsStatic))
        {
            if(BufferLoopItem)
            {
                /* Handle looping static source */
                const ALbuffer *Buffer{BufferListItem->mBuffer};
                const ALuint LoopStart{Buffer->LoopStart};
                const ALuint LoopEnd{Buffer->LoopEnd};
                if(DataPosInt >= LoopEnd)
                {
                    assert(LoopEnd > LoopStart);
                    DataPosInt = ((DataPosInt-LoopStart)%(LoopEnd-LoopStart)) + LoopStart;
                }
            }
            else
            {
                /* Handle non-looping static source */
                if(DataPosInt >= BufferListItem->mSampleLen)
                {
                    BufferListItem = nullptr;
                    break;
                }
            }
        }
        else if((mFlags&VoiceIsCallback))
        {
            ALbuffer *buffer{BufferListItem->mBuffer};
            if(SrcSamplesDone < mNumCallbackSamples)
            {
                const size_t byteOffset{SrcSamplesDone*FrameSize};
                const size_t byteEnd{mNumCallbackSamples*FrameSize};
                al::byte *data{buffer->mBuffer.mData.data()};
                std::copy(data+byteOffset, data+byteEnd, data);
                mNumCallbackSamples -= SrcSamplesDone;
            }
            else
            {
                BufferListItem = nullptr;
                mNumCallbackSamples = 0;
            }
        }
        else
        {
            /* Handle streaming source */
            do {
                if(BufferListItem->mSampleLen > DataPosInt)
                    break;

                DataPosInt -= BufferListItem->mSampleLen;

                ++buffers_done;
                BufferListItem = BufferListItem->mNext.load(std::memory_order_relaxed);
                if(!BufferListItem) BufferListItem = BufferLoopItem;
            } while(BufferListItem);
        }
    } while(OutPos < SamplesToDo);

    mFlags |= VoiceIsFading;

    /* Don't update positions and buffers if we were stopping. */
    if UNLIKELY(vstate == Stopping)
    {
        mPlayState.store(Stopped, std::memory_order_release);
        return;
    }

    /* Capture the source ID in case it's reset for stopping. */
    const ALuint SourceID{mSourceID.load(std::memory_order_relaxed)};

    /* Update voice info */
    mPosition.store(DataPosInt, std::memory_order_relaxed);
    mPositionFrac.store(DataPosFrac, std::memory_order_relaxed);
    mCurrentBuffer.store(BufferListItem, std::memory_order_relaxed);
    if(!BufferListItem)
    {
        mLoopBuffer.store(nullptr, std::memory_order_relaxed);
        mSourceID.store(0u, std::memory_order_relaxed);
    }
    std::atomic_thread_fence(std::memory_order_release);

    /* Send any events now, after the position/buffer info was updated. */
    const ALbitfieldSOFT enabledevt{Context->mEnabledEvts.load(std::memory_order_acquire)};
    if(buffers_done > 0 && (enabledevt&EventType_BufferCompleted))
    {
        RingBuffer *ring{Context->mAsyncEvents.get()};
        auto evt_vec = ring->getWriteVector();
        if(evt_vec.first.len > 0)
        {
            AsyncEvent *evt{::new(evt_vec.first.buf) AsyncEvent{EventType_BufferCompleted}};
            evt->u.bufcomp.id = SourceID;
            evt->u.bufcomp.count = buffers_done;
            ring->writeAdvance(1);
        }
    }

    if(!BufferListItem)
    {
        /* If the voice just ended, set it to Stopping so the next render
         * ensures any residual noise fades to 0 amplitude.
         */
        mPlayState.store(Stopping, std::memory_order_release);
        if((enabledevt&EventType_SourceStateChange))
            SendSourceStoppedEvent(Context, SourceID);
    }
}
