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

#include "buffer.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <numeric>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/alext.h"

#include "albyte.h"
#include "alcmain.h"
#include "alcontext.h"
#include "alexcpt.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "aloptional.h"
#include "atomic.h"
#include "inprogext.h"
#include "opthelpers.h"


namespace {

constexpr int MaxAdpcmChannels{2};

/* IMA ADPCM Stepsize table */
constexpr int IMAStep_size[89] = {
       7,    8,    9,   10,   11,   12,   13,   14,   16,   17,   19,
      21,   23,   25,   28,   31,   34,   37,   41,   45,   50,   55,
      60,   66,   73,   80,   88,   97,  107,  118,  130,  143,  157,
     173,  190,  209,  230,  253,  279,  307,  337,  371,  408,  449,
     494,  544,  598,  658,  724,  796,  876,  963, 1060, 1166, 1282,
    1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
    4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,10442,
   11487,12635,13899,15289,16818,18500,20350,22358,24633,27086,29794,
   32767
};

/* IMA4 ADPCM Codeword decode table */
constexpr int IMA4Codeword[16] = {
    1, 3, 5, 7, 9, 11, 13, 15,
   -1,-3,-5,-7,-9,-11,-13,-15,
};

/* IMA4 ADPCM Step index adjust decode table */
constexpr int IMA4Index_adjust[16] = {
   -1,-1,-1,-1, 2, 4, 6, 8,
   -1,-1,-1,-1, 2, 4, 6, 8
};


/* MSADPCM Adaption table */
constexpr int MSADPCMAdaption[16] = {
    230, 230, 230, 230, 307, 409, 512, 614,
    768, 614, 512, 409, 307, 230, 230, 230
};

/* MSADPCM Adaption Coefficient tables */
constexpr int MSADPCMAdaptionCoeff[7][2] = {
    { 256,    0 },
    { 512, -256 },
    {   0,    0 },
    { 192,   64 },
    { 240,    0 },
    { 460, -208 },
    { 392, -232 }
};


void DecodeIMA4Block(int16_t *dst, const al::byte *src, size_t numchans, size_t align)
{
    int sample[MaxAdpcmChannels]{};
    int index[MaxAdpcmChannels]{};
    ALuint code[MaxAdpcmChannels]{};

    for(size_t c{0};c < numchans;c++)
    {
        sample[c] = al::to_integer<int>(src[0]) | (al::to_integer<int>(src[1])<<8);
        sample[c] = (sample[c]^0x8000) - 32768;
        src += 2;
        index[c] = al::to_integer<int>(src[0]) | (al::to_integer<int>(src[1])<<8);
        index[c] = clampi((index[c]^0x8000) - 32768, 0, 88);
        src += 2;

        *(dst++) = static_cast<int16_t>(sample[c]);
    }

    for(size_t i{1};i < align;i++)
    {
        if((i&7) == 1)
        {
            for(size_t c{0};c < numchans;c++)
            {
                code[c] = al::to_integer<ALuint>(src[0]) | (al::to_integer<ALuint>(src[1])<< 8) |
                    (al::to_integer<ALuint>(src[2])<<16) | (al::to_integer<ALuint>(src[3])<<24);
                src += 4;
            }
        }

        for(size_t c{0};c < numchans;c++)
        {
            const ALuint nibble{code[c]&0xf};
            code[c] >>= 4;

            sample[c] += IMA4Codeword[nibble] * IMAStep_size[index[c]] / 8;
            sample[c] = clampi(sample[c], -32768, 32767);

            index[c] += IMA4Index_adjust[nibble];
            index[c] = clampi(index[c], 0, 88);

            *(dst++) = static_cast<int16_t>(sample[c]);
        }
    }
}

void DecodeMSADPCMBlock(int16_t *dst, const al::byte *src, size_t numchans, size_t align)
{
    uint8_t blockpred[MaxAdpcmChannels]{};
    int delta[MaxAdpcmChannels]{};
    int16_t samples[MaxAdpcmChannels][2]{};

    for(size_t c{0};c < numchans;c++)
    {
        blockpred[c] = std::min<ALubyte>(al::to_integer<ALubyte>(src[0]), 6);
        ++src;
    }
    for(size_t c{0};c < numchans;c++)
    {
        delta[c] = al::to_integer<int>(src[0]) | (al::to_integer<int>(src[1])<<8);
        delta[c] = (delta[c]^0x8000) - 32768;
        src += 2;
    }
    for(size_t c{0};c < numchans;c++)
    {
        samples[c][0] = static_cast<ALshort>(al::to_integer<int>(src[0]) |
            (al::to_integer<int>(src[1])<<8));
        src += 2;
    }
    for(size_t c{0};c < numchans;c++)
    {
        samples[c][1] = static_cast<ALshort>(al::to_integer<int>(src[0]) |
            (al::to_integer<int>(src[1])<<8));
        src += 2;
    }

    /* Second sample is written first. */
    for(size_t c{0};c < numchans;c++)
        *(dst++) = samples[c][1];
    for(size_t c{0};c < numchans;c++)
        *(dst++) = samples[c][0];

    int num{0};
    for(size_t i{2};i < align;i++)
    {
        for(size_t c{0};c < numchans;c++)
        {
            /* Read the nibble (first is in the upper bits). */
            al::byte nibble;
            if(!(num++ & 1))
                nibble = *src >> 4;
            else
                nibble = *(src++) & 0x0f;

            int pred{(samples[c][0]*MSADPCMAdaptionCoeff[blockpred[c]][0] +
                samples[c][1]*MSADPCMAdaptionCoeff[blockpred[c]][1]) / 256};
            pred += (al::to_integer<int>(nibble^0x08) - 0x08) * delta[c];
            pred  = clampi(pred, -32768, 32767);

            samples[c][1] = samples[c][0];
            samples[c][0] = static_cast<int16_t>(pred);

            delta[c] = (MSADPCMAdaption[al::to_integer<ALubyte>(nibble)] * delta[c]) / 256;
            delta[c] = maxi(16, delta[c]);

            *(dst++) = static_cast<int16_t>(pred);
        }
    }
}

void Convert_int16_ima4(int16_t *dst, const al::byte *src, size_t numchans, size_t len,
    size_t align)
{
    assert(numchans <= MaxAdpcmChannels);
    const size_t byte_align{((align-1)/2 + 4) * numchans};

    len /= align;
    while(len--)
    {
        DecodeIMA4Block(dst, src, numchans, align);
        src += byte_align;
        dst += align*numchans;
    }
}

void Convert_int16_msadpcm(int16_t *dst, const al::byte *src, size_t numchans, size_t len,
    size_t align)
{
    assert(numchans <= MaxAdpcmChannels);
    const size_t byte_align{((align-2)/2 + 7) * numchans};

    len /= align;
    while(len--)
    {
        DecodeMSADPCMBlock(dst, src, numchans, align);
        src += byte_align;
        dst += align*numchans;
    }
}


ALuint BytesFromUserFmt(UserFmtType type) noexcept
{
    switch(type)
    {
    case UserFmtUByte: return sizeof(uint8_t);
    case UserFmtShort: return sizeof(int16_t);
    case UserFmtFloat: return sizeof(float);
    case UserFmtDouble: return sizeof(double);
    case UserFmtMulaw: return sizeof(uint8_t);
    case UserFmtAlaw: return sizeof(uint8_t);
    case UserFmtIMA4: break; /* not handled here */
    case UserFmtMSADPCM: break; /* not handled here */
    }
    return 0;
}
ALuint ChannelsFromUserFmt(UserFmtChannels chans, ALuint ambiorder) noexcept
{
    switch(chans)
    {
    case UserFmtMono: return 1;
    case UserFmtStereo: return 2;
    case UserFmtRear: return 2;
    case UserFmtQuad: return 4;
    case UserFmtX51: return 6;
    case UserFmtX61: return 7;
    case UserFmtX71: return 8;
    case UserFmtBFormat2D: return (ambiorder*2) + 1;
    case UserFmtBFormat3D: return (ambiorder+1) * (ambiorder+1);
    }
    return 0;
}


constexpr ALbitfieldSOFT INVALID_STORAGE_MASK{~unsigned(AL_MAP_READ_BIT_SOFT |
    AL_MAP_WRITE_BIT_SOFT | AL_MAP_PERSISTENT_BIT_SOFT | AL_PRESERVE_DATA_BIT_SOFT)};
constexpr ALbitfieldSOFT MAP_READ_WRITE_FLAGS{AL_MAP_READ_BIT_SOFT | AL_MAP_WRITE_BIT_SOFT};
constexpr ALbitfieldSOFT INVALID_MAP_FLAGS{~unsigned(AL_MAP_READ_BIT_SOFT | AL_MAP_WRITE_BIT_SOFT |
    AL_MAP_PERSISTENT_BIT_SOFT)};


bool EnsureBuffers(ALCdevice *device, size_t needed)
{
    size_t count{std::accumulate(device->BufferList.cbegin(), device->BufferList.cend(), size_t{0},
        [](size_t cur, const BufferSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(sublist.FreeMask)); })};

    while(needed > count)
    {
        if UNLIKELY(device->BufferList.size() >= 1<<25)
            return false;

        device->BufferList.emplace_back();
        auto sublist = device->BufferList.end() - 1;
        sublist->FreeMask = ~0_u64;
        sublist->Buffers = static_cast<ALbuffer*>(al_calloc(alignof(ALbuffer), sizeof(ALbuffer)*64));
        if UNLIKELY(!sublist->Buffers)
        {
            device->BufferList.pop_back();
            return false;
        }
        count += 64;
    }
    return true;
}

ALbuffer *AllocBuffer(ALCdevice *device)
{
    auto sublist = std::find_if(device->BufferList.begin(), device->BufferList.end(),
        [](const BufferSubList &entry) noexcept -> bool
        { return entry.FreeMask != 0; }
    );

    auto lidx = static_cast<ALuint>(std::distance(device->BufferList.begin(), sublist));
    auto slidx = static_cast<ALuint>(CountTrailingZeros(sublist->FreeMask));

    ALbuffer *buffer{::new (sublist->Buffers + slidx) ALbuffer{}};

    /* Add 1 to avoid buffer ID 0. */
    buffer->id = ((lidx<<6) | slidx) + 1;

    sublist->FreeMask &= ~(1_u64 << slidx);

    return buffer;
}

void FreeBuffer(ALCdevice *device, ALbuffer *buffer)
{
    const ALuint id{buffer->id - 1};
    const size_t lidx{id >> 6};
    const ALuint slidx{id & 0x3f};

    al::destroy_at(buffer);

    device->BufferList[lidx].FreeMask |= 1_u64 << slidx;
}

inline ALbuffer *LookupBuffer(ALCdevice *device, ALuint id)
{
    const size_t lidx{(id-1) >> 6};
    const ALuint slidx{(id-1) & 0x3f};

    if UNLIKELY(lidx >= device->BufferList.size())
        return nullptr;
    BufferSubList &sublist = device->BufferList[lidx];
    if UNLIKELY(sublist.FreeMask & (1_u64 << slidx))
        return nullptr;
    return sublist.Buffers + slidx;
}


ALuint SanitizeAlignment(UserFmtType type, ALuint align)
{
    if(align == 0)
    {
        if(type == UserFmtIMA4)
        {
            /* Here is where things vary:
             * nVidia and Apple use 64+1 sample frames per block -> block_size=36 bytes per channel
             * Most PC sound software uses 2040+1 sample frames per block -> block_size=1024 bytes per channel
             */
            return 65;
        }
        if(type == UserFmtMSADPCM)
            return 64;
        return 1;
    }

    if(type == UserFmtIMA4)
    {
        /* IMA4 block alignment must be a multiple of 8, plus 1. */
        if((align&7) == 1) return static_cast<ALuint>(align);
        return 0;
    }
    if(type == UserFmtMSADPCM)
    {
        /* MSADPCM block alignment must be a multiple of 2. */
        if((align&1) == 0) return static_cast<ALuint>(align);
        return 0;
    }

    return static_cast<ALuint>(align);
}


const ALchar *NameFromUserFmtType(UserFmtType type)
{
    switch(type)
    {
    case UserFmtUByte: return "UInt8";
    case UserFmtShort: return "Int16";
    case UserFmtFloat: return "Float32";
    case UserFmtDouble: return "Float64";
    case UserFmtMulaw: return "muLaw";
    case UserFmtAlaw: return "aLaw";
    case UserFmtIMA4: return "IMA4 ADPCM";
    case UserFmtMSADPCM: return "MSADPCM";
    }
    return "<internal type error>";
}

/** Loads the specified data into the buffer, using the specified format. */
void LoadData(ALCcontext *context, ALbuffer *ALBuf, ALsizei freq, ALuint size,
    UserFmtChannels SrcChannels, UserFmtType SrcType, const al::byte *SrcData,
    ALbitfieldSOFT access)
{
    if UNLIKELY(ReadRef(ALBuf->ref) != 0 || ALBuf->MappedAccess != 0)
        SETERR_RETURN(context, AL_INVALID_OPERATION,, "Modifying storage for in-use buffer %u",
                      ALBuf->id);

    /* Currently no channel configurations need to be converted. */
    FmtChannels DstChannels{FmtMono};
    switch(SrcChannels)
    {
    case UserFmtMono: DstChannels = FmtMono; break;
    case UserFmtStereo: DstChannels = FmtStereo; break;
    case UserFmtRear: DstChannels = FmtRear; break;
    case UserFmtQuad: DstChannels = FmtQuad; break;
    case UserFmtX51: DstChannels = FmtX51; break;
    case UserFmtX61: DstChannels = FmtX61; break;
    case UserFmtX71: DstChannels = FmtX71; break;
    case UserFmtBFormat2D: DstChannels = FmtBFormat2D; break;
    case UserFmtBFormat3D: DstChannels = FmtBFormat3D; break;
    }
    if UNLIKELY(static_cast<long>(SrcChannels) != static_cast<long>(DstChannels))
        SETERR_RETURN(context, AL_INVALID_ENUM, , "Invalid format");

    /* IMA4 and MSADPCM convert to 16-bit short. */
    FmtType DstType{FmtUByte};
    switch(SrcType)
    {
    case UserFmtUByte: DstType = FmtUByte; break;
    case UserFmtShort: DstType = FmtShort; break;
    case UserFmtFloat: DstType = FmtFloat; break;
    case UserFmtDouble: DstType = FmtDouble; break;
    case UserFmtAlaw: DstType = FmtAlaw; break;
    case UserFmtMulaw: DstType = FmtMulaw; break;
    case UserFmtIMA4: DstType = FmtShort; break;
    case UserFmtMSADPCM: DstType = FmtShort; break;
    }

    /* TODO: Currently we can only map samples when they're not converted. To
     * allow it would need some kind of double-buffering to hold onto a copy of
     * the original data.
     */
    if((access&MAP_READ_WRITE_FLAGS))
    {
        if UNLIKELY(static_cast<long>(SrcType) != static_cast<long>(DstType))
            SETERR_RETURN(context, AL_INVALID_VALUE,, "%s samples cannot be mapped",
                NameFromUserFmtType(SrcType));
    }

    const ALuint unpackalign{ALBuf->UnpackAlign};
    const ALuint align{SanitizeAlignment(SrcType, unpackalign)};
    if UNLIKELY(align < 1)
        SETERR_RETURN(context, AL_INVALID_VALUE,, "Invalid unpack alignment %u for %s samples",
            unpackalign, NameFromUserFmtType(SrcType));

    const ALuint ambiorder{(DstChannels == FmtBFormat2D || DstChannels == FmtBFormat3D) ?
        ALBuf->UnpackAmbiOrder : 0};

    if((access&AL_PRESERVE_DATA_BIT_SOFT))
    {
        /* Can only preserve data with the same format and alignment. */
        if UNLIKELY(ALBuf->mBuffer.mChannels != DstChannels || ALBuf->OriginalType != SrcType)
            SETERR_RETURN(context, AL_INVALID_VALUE,, "Preserving data of mismatched format");
        if UNLIKELY(ALBuf->OriginalAlign != align)
            SETERR_RETURN(context, AL_INVALID_VALUE,, "Preserving data of mismatched alignment");
        if(ALBuf->mBuffer.mAmbiOrder != ambiorder)
            SETERR_RETURN(context, AL_INVALID_VALUE,, "Preserving data of mismatched order");
    }

    /* Convert the input/source size in bytes to sample frames using the unpack
     * block alignment.
     */
    const ALuint SrcByteAlign{ChannelsFromUserFmt(SrcChannels, ambiorder) *
        ((SrcType == UserFmtIMA4) ? (align-1)/2 + 4 :
        (SrcType == UserFmtMSADPCM) ? (align-2)/2 + 7 :
        (align * BytesFromUserFmt(SrcType)))};
    if UNLIKELY((size%SrcByteAlign) != 0)
        SETERR_RETURN(context, AL_INVALID_VALUE,,
            "Data size %d is not a multiple of frame size %d (%d unpack alignment)",
            size, SrcByteAlign, align);

    if UNLIKELY(size/SrcByteAlign > std::numeric_limits<ALsizei>::max()/align)
        SETERR_RETURN(context, AL_OUT_OF_MEMORY,,
            "Buffer size overflow, %d blocks x %d samples per block", size/SrcByteAlign, align);
    const ALuint frames{size / SrcByteAlign * align};

    /* Convert the sample frames to the number of bytes needed for internal
     * storage.
     */
    ALuint NumChannels{ChannelsFromFmt(DstChannels, ambiorder)};
    ALuint FrameSize{NumChannels * BytesFromFmt(DstType)};
    if UNLIKELY(frames > std::numeric_limits<size_t>::max()/FrameSize)
        SETERR_RETURN(context, AL_OUT_OF_MEMORY,,
            "Buffer size overflow, %d frames x %d bytes per frame", frames, FrameSize);
    size_t newsize{static_cast<size_t>(frames) * FrameSize};

    /* Round up to the next 16-byte multiple. This could reallocate only when
     * increasing or the new size is less than half the current, but then the
     * buffer's AL_SIZE would not be very reliable for accounting buffer memory
     * usage, and reporting the real size could cause problems for apps that
     * use AL_SIZE to try to get the buffer's play length.
     */
    newsize = RoundUp(newsize, 16);
    if(newsize != ALBuf->mBuffer.mData.size())
    {
        auto newdata = al::vector<al::byte,16>(newsize, al::byte{});
        if((access&AL_PRESERVE_DATA_BIT_SOFT))
        {
            const size_t tocopy{minz(newdata.size(), ALBuf->mBuffer.mData.size())};
            std::copy_n(ALBuf->mBuffer.mData.begin(), tocopy, newdata.begin());
        }
        newdata.swap(ALBuf->mBuffer.mData);
    }

    if(SrcType == UserFmtIMA4)
    {
        assert(DstType == FmtShort);
        if(SrcData != nullptr && !ALBuf->mBuffer.mData.empty())
            Convert_int16_ima4(reinterpret_cast<int16_t*>(ALBuf->mBuffer.mData.data()), SrcData,
                NumChannels, frames, align);
        ALBuf->OriginalAlign = align;
    }
    else if(SrcType == UserFmtMSADPCM)
    {
        assert(DstType == FmtShort);
        if(SrcData != nullptr && !ALBuf->mBuffer.mData.empty())
            Convert_int16_msadpcm(reinterpret_cast<int16_t*>(ALBuf->mBuffer.mData.data()), SrcData,
                NumChannels, frames, align);
        ALBuf->OriginalAlign = align;
    }
    else
    {
        assert(static_cast<long>(SrcType) == static_cast<long>(DstType));
        if(SrcData != nullptr && !ALBuf->mBuffer.mData.empty())
            std::copy_n(SrcData, frames*FrameSize, ALBuf->mBuffer.mData.begin());
        ALBuf->OriginalAlign = 1;
    }
    ALBuf->OriginalSize = size;
    ALBuf->OriginalType = SrcType;

    ALBuf->mBuffer.mSampleRate = static_cast<ALuint>(freq);
    ALBuf->mBuffer.mChannels = DstChannels;
    ALBuf->mBuffer.mType = DstType;
    ALBuf->Access = access;
    ALBuf->mBuffer.mAmbiOrder = ambiorder;

    ALBuf->mBuffer.mCallback = nullptr;
    ALBuf->mBuffer.mUserData = nullptr;

    ALBuf->mBuffer.mSampleLen = frames;
    ALBuf->LoopStart = 0;
    ALBuf->LoopEnd = ALBuf->mBuffer.mSampleLen;
}

/** Prepares the buffer to use the specified callback, using the specified format. */
void PrepareCallback(ALCcontext *context, ALbuffer *ALBuf, ALsizei freq,
    UserFmtChannels SrcChannels, UserFmtType SrcType, LPALBUFFERCALLBACKTYPESOFT callback,
    void *userptr)
{
    if UNLIKELY(ReadRef(ALBuf->ref) != 0 || ALBuf->MappedAccess != 0)
        SETERR_RETURN(context, AL_INVALID_OPERATION,, "Modifying callback for in-use buffer %u",
            ALBuf->id);

    /* Currently no channel configurations need to be converted. */
    FmtChannels DstChannels{FmtMono};
    switch(SrcChannels)
    {
    case UserFmtMono: DstChannels = FmtMono; break;
    case UserFmtStereo: DstChannels = FmtStereo; break;
    case UserFmtRear: DstChannels = FmtRear; break;
    case UserFmtQuad: DstChannels = FmtQuad; break;
    case UserFmtX51: DstChannels = FmtX51; break;
    case UserFmtX61: DstChannels = FmtX61; break;
    case UserFmtX71: DstChannels = FmtX71; break;
    case UserFmtBFormat2D: DstChannels = FmtBFormat2D; break;
    case UserFmtBFormat3D: DstChannels = FmtBFormat3D; break;
    }
    if UNLIKELY(static_cast<long>(SrcChannels) != static_cast<long>(DstChannels))
        SETERR_RETURN(context, AL_INVALID_ENUM,, "Invalid format");

    /* IMA4 and MSADPCM convert to 16-bit short. Not supported with callbacks. */
    FmtType DstType{FmtUByte};
    switch(SrcType)
    {
    case UserFmtUByte: DstType = FmtUByte; break;
    case UserFmtShort: DstType = FmtShort; break;
    case UserFmtFloat: DstType = FmtFloat; break;
    case UserFmtDouble: DstType = FmtDouble; break;
    case UserFmtAlaw: DstType = FmtAlaw; break;
    case UserFmtMulaw: DstType = FmtMulaw; break;
    case UserFmtIMA4: DstType = FmtShort; break;
    case UserFmtMSADPCM: DstType = FmtShort; break;
    }
    if UNLIKELY(static_cast<long>(SrcType) != static_cast<long>(DstType))
        SETERR_RETURN(context, AL_INVALID_ENUM,, "Unsupported callback format");

    const ALuint ambiorder{(DstChannels == FmtBFormat2D || DstChannels == FmtBFormat3D) ?
        ALBuf->UnpackAmbiOrder : 0};

    al::vector<al::byte,16>(FrameSizeFromFmt(DstChannels, DstType, ambiorder) *
        size_t{BUFFERSIZE + (MAX_RESAMPLER_PADDING>>1)}).swap(ALBuf->mBuffer.mData);

    ALBuf->mBuffer.mCallback = callback;
    ALBuf->mBuffer.mUserData = userptr;

    ALBuf->OriginalType = SrcType;
    ALBuf->OriginalSize = 0;
    ALBuf->OriginalAlign = 1;

    ALBuf->mBuffer.mSampleRate = static_cast<ALuint>(freq);
    ALBuf->mBuffer.mChannels = DstChannels;
    ALBuf->mBuffer.mType = DstType;
    ALBuf->Access = 0;
    ALBuf->mBuffer.mAmbiOrder = ambiorder;

    ALBuf->mBuffer.mSampleLen = 0;
    ALBuf->LoopStart = 0;
    ALBuf->LoopEnd = ALBuf->mBuffer.mSampleLen;
}


struct DecompResult { UserFmtChannels channels; UserFmtType type; };
al::optional<DecompResult> DecomposeUserFormat(ALenum format)
{
    struct FormatMap {
        ALenum format;
        UserFmtChannels channels;
        UserFmtType type;
    };
    static const std::array<FormatMap,46> UserFmtList{{
        { AL_FORMAT_MONO8,             UserFmtMono, UserFmtUByte   },
        { AL_FORMAT_MONO16,            UserFmtMono, UserFmtShort   },
        { AL_FORMAT_MONO_FLOAT32,      UserFmtMono, UserFmtFloat   },
        { AL_FORMAT_MONO_DOUBLE_EXT,   UserFmtMono, UserFmtDouble  },
        { AL_FORMAT_MONO_IMA4,         UserFmtMono, UserFmtIMA4    },
        { AL_FORMAT_MONO_MSADPCM_SOFT, UserFmtMono, UserFmtMSADPCM },
        { AL_FORMAT_MONO_MULAW,        UserFmtMono, UserFmtMulaw   },
        { AL_FORMAT_MONO_ALAW_EXT,     UserFmtMono, UserFmtAlaw    },

        { AL_FORMAT_STEREO8,             UserFmtStereo, UserFmtUByte   },
        { AL_FORMAT_STEREO16,            UserFmtStereo, UserFmtShort   },
        { AL_FORMAT_STEREO_FLOAT32,      UserFmtStereo, UserFmtFloat   },
        { AL_FORMAT_STEREO_DOUBLE_EXT,   UserFmtStereo, UserFmtDouble  },
        { AL_FORMAT_STEREO_IMA4,         UserFmtStereo, UserFmtIMA4    },
        { AL_FORMAT_STEREO_MSADPCM_SOFT, UserFmtStereo, UserFmtMSADPCM },
        { AL_FORMAT_STEREO_MULAW,        UserFmtStereo, UserFmtMulaw   },
        { AL_FORMAT_STEREO_ALAW_EXT,     UserFmtStereo, UserFmtAlaw    },

        { AL_FORMAT_REAR8,      UserFmtRear, UserFmtUByte },
        { AL_FORMAT_REAR16,     UserFmtRear, UserFmtShort },
        { AL_FORMAT_REAR32,     UserFmtRear, UserFmtFloat },
        { AL_FORMAT_REAR_MULAW, UserFmtRear, UserFmtMulaw },

        { AL_FORMAT_QUAD8_LOKI,  UserFmtQuad, UserFmtUByte },
        { AL_FORMAT_QUAD16_LOKI, UserFmtQuad, UserFmtShort },

        { AL_FORMAT_QUAD8,      UserFmtQuad, UserFmtUByte },
        { AL_FORMAT_QUAD16,     UserFmtQuad, UserFmtShort },
        { AL_FORMAT_QUAD32,     UserFmtQuad, UserFmtFloat },
        { AL_FORMAT_QUAD_MULAW, UserFmtQuad, UserFmtMulaw },

        { AL_FORMAT_51CHN8,      UserFmtX51, UserFmtUByte },
        { AL_FORMAT_51CHN16,     UserFmtX51, UserFmtShort },
        { AL_FORMAT_51CHN32,     UserFmtX51, UserFmtFloat },
        { AL_FORMAT_51CHN_MULAW, UserFmtX51, UserFmtMulaw },

        { AL_FORMAT_61CHN8,      UserFmtX61, UserFmtUByte },
        { AL_FORMAT_61CHN16,     UserFmtX61, UserFmtShort },
        { AL_FORMAT_61CHN32,     UserFmtX61, UserFmtFloat },
        { AL_FORMAT_61CHN_MULAW, UserFmtX61, UserFmtMulaw },

        { AL_FORMAT_71CHN8,      UserFmtX71, UserFmtUByte },
        { AL_FORMAT_71CHN16,     UserFmtX71, UserFmtShort },
        { AL_FORMAT_71CHN32,     UserFmtX71, UserFmtFloat },
        { AL_FORMAT_71CHN_MULAW, UserFmtX71, UserFmtMulaw },

        { AL_FORMAT_BFORMAT2D_8,       UserFmtBFormat2D, UserFmtUByte },
        { AL_FORMAT_BFORMAT2D_16,      UserFmtBFormat2D, UserFmtShort },
        { AL_FORMAT_BFORMAT2D_FLOAT32, UserFmtBFormat2D, UserFmtFloat },
        { AL_FORMAT_BFORMAT2D_MULAW,   UserFmtBFormat2D, UserFmtMulaw },

        { AL_FORMAT_BFORMAT3D_8,       UserFmtBFormat3D, UserFmtUByte },
        { AL_FORMAT_BFORMAT3D_16,      UserFmtBFormat3D, UserFmtShort },
        { AL_FORMAT_BFORMAT3D_FLOAT32, UserFmtBFormat3D, UserFmtFloat },
        { AL_FORMAT_BFORMAT3D_MULAW,   UserFmtBFormat3D, UserFmtMulaw },
    }};

    for(const auto &fmt : UserFmtList)
    {
        if(fmt.format == format)
            return al::make_optional<DecompResult>({fmt.channels, fmt.type});
    }
    return al::nullopt;
}

} // namespace


AL_API void AL_APIENTRY alGenBuffers(ALsizei n, ALuint *buffers)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if UNLIKELY(n < 0)
        context->setError(AL_INVALID_VALUE, "Generating %d buffers", n);
    if UNLIKELY(n <= 0) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    if(!EnsureBuffers(device, static_cast<ALuint>(n)))
    {
        context->setError(AL_OUT_OF_MEMORY, "Failed to allocate %d buffer%s", n, (n==1)?"":"s");
        return;
    }

    if LIKELY(n == 1)
    {
        /* Special handling for the easy and normal case. */
        ALbuffer *buffer{AllocBuffer(device)};
        buffers[0] = buffer->id;
    }
    else
    {
        /* Store the allocated buffer IDs in a separate local list, to avoid
         * modifying the user storage in case of failure.
         */
        al::vector<ALuint> ids;
        ids.reserve(static_cast<ALuint>(n));
        do {
            ALbuffer *buffer{AllocBuffer(device)};
            ids.emplace_back(buffer->id);
        } while(--n);
        std::copy(ids.begin(), ids.end(), buffers);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alDeleteBuffers(ALsizei n, const ALuint *buffers)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    if UNLIKELY(n < 0)
        context->setError(AL_INVALID_VALUE, "Deleting %d buffers", n);
    if UNLIKELY(n <= 0) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    /* First try to find any buffers that are invalid or in-use. */
    auto validate_buffer = [device, &context](const ALuint bid) -> bool
    {
        if(!bid) return true;
        ALbuffer *ALBuf{LookupBuffer(device, bid)};
        if UNLIKELY(!ALBuf)
        {
            context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", bid);
            return false;
        }
        if UNLIKELY(ReadRef(ALBuf->ref) != 0)
        {
            context->setError(AL_INVALID_OPERATION, "Deleting in-use buffer %u", bid);
            return false;
        }
        return true;
    };
    const ALuint *buffers_end = buffers + n;
    auto invbuf = std::find_if_not(buffers, buffers_end, validate_buffer);
    if UNLIKELY(invbuf != buffers_end) return;

    /* All good. Delete non-0 buffer IDs. */
    auto delete_buffer = [device](const ALuint bid) -> void
    {
        ALbuffer *buffer{bid ? LookupBuffer(device, bid) : nullptr};
        if(buffer) FreeBuffer(device, buffer);
    };
    std::for_each(buffers, buffers_end, delete_buffer);
}
END_API_FUNC

AL_API ALboolean AL_APIENTRY alIsBuffer(ALuint buffer)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if LIKELY(context)
    {
        ALCdevice *device{context->mDevice.get()};
        std::lock_guard<std::mutex> _{device->BufferLock};
        if(!buffer || LookupBuffer(device, buffer))
            return AL_TRUE;
    }
    return AL_FALSE;
}
END_API_FUNC


AL_API void AL_APIENTRY alBufferData(ALuint buffer, ALenum format, const ALvoid *data, ALsizei size, ALsizei freq)
START_API_FUNC
{ alBufferStorageSOFT(buffer, format, data, size, freq, 0); }
END_API_FUNC

AL_API void AL_APIENTRY alBufferStorageSOFT(ALuint buffer, ALenum format, const ALvoid *data, ALsizei size, ALsizei freq, ALbitfieldSOFT flags)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(size < 0)
        context->setError(AL_INVALID_VALUE, "Negative storage size %d", size);
    else if UNLIKELY(freq < 1)
        context->setError(AL_INVALID_VALUE, "Invalid sample rate %d", freq);
    else if UNLIKELY((flags&INVALID_STORAGE_MASK) != 0)
        context->setError(AL_INVALID_VALUE, "Invalid storage flags 0x%x",
            flags&INVALID_STORAGE_MASK);
    else if UNLIKELY((flags&AL_MAP_PERSISTENT_BIT_SOFT) && !(flags&MAP_READ_WRITE_FLAGS))
        context->setError(AL_INVALID_VALUE,
            "Declaring persistently mapped storage without read or write access");
    else
    {
        auto usrfmt = DecomposeUserFormat(format);
        if UNLIKELY(!usrfmt)
            context->setError(AL_INVALID_ENUM, "Invalid format 0x%04x", format);
        else
            LoadData(context.get(), albuf, freq, static_cast<ALuint>(size), usrfmt->channels,
                usrfmt->type, static_cast<const al::byte*>(data), flags);
    }
}
END_API_FUNC

AL_API void* AL_APIENTRY alMapBufferSOFT(ALuint buffer, ALsizei offset, ALsizei length, ALbitfieldSOFT access)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return nullptr;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY((access&INVALID_MAP_FLAGS) != 0)
        context->setError(AL_INVALID_VALUE, "Invalid map flags 0x%x", access&INVALID_MAP_FLAGS);
    else if UNLIKELY(!(access&MAP_READ_WRITE_FLAGS))
        context->setError(AL_INVALID_VALUE, "Mapping buffer %u without read or write access",
            buffer);
    else
    {
        ALbitfieldSOFT unavailable = (albuf->Access^access) & access;
        if UNLIKELY(ReadRef(albuf->ref) != 0 && !(access&AL_MAP_PERSISTENT_BIT_SOFT))
            context->setError(AL_INVALID_OPERATION,
                "Mapping in-use buffer %u without persistent mapping", buffer);
        else if UNLIKELY(albuf->MappedAccess != 0)
            context->setError(AL_INVALID_OPERATION, "Mapping already-mapped buffer %u", buffer);
        else if UNLIKELY((unavailable&AL_MAP_READ_BIT_SOFT))
            context->setError(AL_INVALID_VALUE,
                "Mapping buffer %u for reading without read access", buffer);
        else if UNLIKELY((unavailable&AL_MAP_WRITE_BIT_SOFT))
            context->setError(AL_INVALID_VALUE,
                "Mapping buffer %u for writing without write access", buffer);
        else if UNLIKELY((unavailable&AL_MAP_PERSISTENT_BIT_SOFT))
            context->setError(AL_INVALID_VALUE,
                "Mapping buffer %u persistently without persistent access", buffer);
        else if UNLIKELY(offset < 0 || length <= 0
            || static_cast<ALuint>(offset) >= albuf->OriginalSize
            || static_cast<ALuint>(length) > albuf->OriginalSize - static_cast<ALuint>(offset))
            context->setError(AL_INVALID_VALUE, "Mapping invalid range %d+%d for buffer %u",
                offset, length, buffer);
        else
        {
            void *retval{albuf->mBuffer.mData.data() + offset};
            albuf->MappedAccess = access;
            albuf->MappedOffset = offset;
            albuf->MappedSize = length;
            return retval;
        }
    }

    return nullptr;
}
END_API_FUNC

AL_API void AL_APIENTRY alUnmapBufferSOFT(ALuint buffer)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(albuf->MappedAccess == 0)
        context->setError(AL_INVALID_OPERATION, "Unmapping unmapped buffer %u", buffer);
    else
    {
        albuf->MappedAccess = 0;
        albuf->MappedOffset = 0;
        albuf->MappedSize = 0;
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alFlushMappedBufferSOFT(ALuint buffer, ALsizei offset, ALsizei length)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!(albuf->MappedAccess&AL_MAP_WRITE_BIT_SOFT))
        context->setError(AL_INVALID_OPERATION, "Flushing buffer %u while not mapped for writing",
            buffer);
    else if UNLIKELY(offset < albuf->MappedOffset || length <= 0
        || offset >= albuf->MappedOffset+albuf->MappedSize
        || length > albuf->MappedOffset+albuf->MappedSize-offset)
        context->setError(AL_INVALID_VALUE, "Flushing invalid range %d+%d on buffer %u", offset,
            length, buffer);
    else
    {
        /* FIXME: Need to use some method of double-buffering for the mixer and
         * app to hold separate memory, which can be safely transfered
         * asynchronously. Currently we just say the app shouldn't write where
         * OpenAL's reading, and hope for the best...
         */
        std::atomic_thread_fence(std::memory_order_seq_cst);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alBufferSubDataSOFT(ALuint buffer, ALenum format, const ALvoid *data, ALsizei offset, ALsizei length)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
    {
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
        return;
    }

    auto usrfmt = DecomposeUserFormat(format);
    if UNLIKELY(!usrfmt)
    {
        context->setError(AL_INVALID_ENUM, "Invalid format 0x%04x", format);
        return;
    }

    ALuint unpack_align{albuf->UnpackAlign};
    ALuint align{SanitizeAlignment(usrfmt->type, unpack_align)};
    if UNLIKELY(align < 1)
        context->setError(AL_INVALID_VALUE, "Invalid unpack alignment %u", unpack_align);
    else if UNLIKELY(long{usrfmt->channels} != long{albuf->mBuffer.mChannels}
        || usrfmt->type != albuf->OriginalType)
        context->setError(AL_INVALID_ENUM, "Unpacking data with mismatched format");
    else if UNLIKELY(align != albuf->OriginalAlign)
        context->setError(AL_INVALID_VALUE,
            "Unpacking data with alignment %u does not match original alignment %u", align,
            albuf->OriginalAlign);
    else if UNLIKELY(albuf->mBuffer.isBFormat()
        && albuf->UnpackAmbiOrder != albuf->mBuffer.mAmbiOrder)
        context->setError(AL_INVALID_VALUE, "Unpacking data with mismatched ambisonic order");
    else if UNLIKELY(albuf->MappedAccess != 0)
        context->setError(AL_INVALID_OPERATION, "Unpacking data into mapped buffer %u", buffer);
    else
    {
        ALuint num_chans{albuf->channelsFromFmt()};
        ALuint frame_size{num_chans * albuf->bytesFromFmt()};
        ALuint byte_align{
            (albuf->OriginalType == UserFmtIMA4) ? ((align-1)/2 + 4) * num_chans :
            (albuf->OriginalType == UserFmtMSADPCM) ? ((align-2)/2 + 7) * num_chans :
            (align * frame_size)
        };

        if UNLIKELY(offset < 0 || length < 0 || static_cast<ALuint>(offset) > albuf->OriginalSize
            || static_cast<ALuint>(length) > albuf->OriginalSize-static_cast<ALuint>(offset))
            context->setError(AL_INVALID_VALUE, "Invalid data sub-range %d+%d on buffer %u",
                offset, length, buffer);
        else if UNLIKELY((static_cast<ALuint>(offset)%byte_align) != 0)
            context->setError(AL_INVALID_VALUE,
                "Sub-range offset %d is not a multiple of frame size %d (%d unpack alignment)",
                offset, byte_align, align);
        else if UNLIKELY((static_cast<ALuint>(length)%byte_align) != 0)
            context->setError(AL_INVALID_VALUE,
                "Sub-range length %d is not a multiple of frame size %d (%d unpack alignment)",
                length, byte_align, align);
        else
        {
            /* offset -> byte offset, length -> sample count */
            size_t byteoff{static_cast<ALuint>(offset)/byte_align * align * frame_size};
            size_t samplen{static_cast<ALuint>(length)/byte_align * align};

            void *dst = albuf->mBuffer.mData.data() + byteoff;
            if(usrfmt->type == UserFmtIMA4 && albuf->mBuffer.mType == FmtShort)
                Convert_int16_ima4(static_cast<int16_t*>(dst), static_cast<const al::byte*>(data),
                    num_chans, samplen, align);
            else if(usrfmt->type == UserFmtMSADPCM && albuf->mBuffer.mType == FmtShort)
                Convert_int16_msadpcm(static_cast<int16_t*>(dst),
                    static_cast<const al::byte*>(data), num_chans, samplen, align);
            else
            {
                assert(long{usrfmt->type} == long{albuf->mBuffer.mType});
                memcpy(dst, data, size_t{samplen} * frame_size);
            }
        }
    }
}
END_API_FUNC


AL_API void AL_APIENTRY alBufferSamplesSOFT(ALuint /*buffer*/, ALuint /*samplerate*/,
    ALenum /*internalformat*/, ALsizei /*samples*/, ALenum /*channels*/, ALenum /*type*/,
    const ALvoid* /*data*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    context->setError(AL_INVALID_OPERATION, "alBufferSamplesSOFT not supported");
}
END_API_FUNC

AL_API void AL_APIENTRY alBufferSubSamplesSOFT(ALuint /*buffer*/, ALsizei /*offset*/,
    ALsizei /*samples*/, ALenum /*channels*/, ALenum /*type*/, const ALvoid* /*data*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    context->setError(AL_INVALID_OPERATION, "alBufferSubSamplesSOFT not supported");
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBufferSamplesSOFT(ALuint /*buffer*/, ALsizei /*offset*/,
    ALsizei /*samples*/, ALenum /*channels*/, ALenum /*type*/, ALvoid* /*data*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    context->setError(AL_INVALID_OPERATION, "alGetBufferSamplesSOFT not supported");
}
END_API_FUNC

AL_API ALboolean AL_APIENTRY alIsBufferFormatSupportedSOFT(ALenum /*format*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return AL_FALSE;

    context->setError(AL_INVALID_OPERATION, "alIsBufferFormatSupportedSOFT not supported");
    return AL_FALSE;
}
END_API_FUNC


AL_API void AL_APIENTRY alBufferf(ALuint buffer, ALenum param, ALfloat /*value*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer float property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alBuffer3f(ALuint buffer, ALenum param,
    ALfloat /*value1*/, ALfloat /*value2*/, ALfloat /*value3*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer 3-float property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alBufferfv(ALuint buffer, ALenum param, const ALfloat *values)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!values)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer float-vector property 0x%04x", param);
    }
}
END_API_FUNC


AL_API void AL_APIENTRY alBufferi(ALuint buffer, ALenum param, ALint value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else switch(param)
    {
    case AL_UNPACK_BLOCK_ALIGNMENT_SOFT:
        if UNLIKELY(value < 0)
            context->setError(AL_INVALID_VALUE, "Invalid unpack block alignment %d", value);
        else
            albuf->UnpackAlign = static_cast<ALuint>(value);
        break;

    case AL_PACK_BLOCK_ALIGNMENT_SOFT:
        if UNLIKELY(value < 0)
            context->setError(AL_INVALID_VALUE, "Invalid pack block alignment %d", value);
        else
            albuf->PackAlign = static_cast<ALuint>(value);
        break;

    case AL_AMBISONIC_LAYOUT_SOFT:
        if UNLIKELY(ReadRef(albuf->ref) != 0)
            context->setError(AL_INVALID_OPERATION, "Modifying in-use buffer %u's ambisonic layout",
                buffer);
        else if UNLIKELY(value != AL_FUMA_SOFT && value != AL_ACN_SOFT)
            context->setError(AL_INVALID_VALUE, "Invalid unpack ambisonic layout %04x", value);
        else
            albuf->mBuffer.mAmbiLayout = static_cast<AmbiLayout>(value);
        break;

    case AL_AMBISONIC_SCALING_SOFT:
        if UNLIKELY(ReadRef(albuf->ref) != 0)
            context->setError(AL_INVALID_OPERATION, "Modifying in-use buffer %u's ambisonic scaling",
                buffer);
        else if UNLIKELY(value != AL_FUMA_SOFT && value != AL_SN3D_SOFT && value != AL_N3D_SOFT)
            context->setError(AL_INVALID_VALUE, "Invalid unpack ambisonic scaling %04x", value);
        else
            albuf->mBuffer.mAmbiScaling = static_cast<AmbiScaling>(value);
        break;

    case AL_UNPACK_AMBISONIC_ORDER_SOFT:
        if UNLIKELY(value < 1 || value > 14)
            context->setError(AL_INVALID_VALUE, "Invalid unpack ambisonic order %d", value);
        else
            albuf->UnpackAmbiOrder = static_cast<ALuint>(value);
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer integer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alBuffer3i(ALuint buffer, ALenum param,
    ALint /*value1*/, ALint /*value2*/, ALint /*value3*/)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer 3-integer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alBufferiv(ALuint buffer, ALenum param, const ALint *values)
START_API_FUNC
{
    if(values)
    {
        switch(param)
        {
        case AL_UNPACK_BLOCK_ALIGNMENT_SOFT:
        case AL_PACK_BLOCK_ALIGNMENT_SOFT:
        case AL_AMBISONIC_LAYOUT_SOFT:
        case AL_AMBISONIC_SCALING_SOFT:
        case AL_UNPACK_AMBISONIC_ORDER_SOFT:
            alBufferi(buffer, param, values[0]);
            return;
        }
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!values)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    case AL_LOOP_POINTS_SOFT:
        if UNLIKELY(ReadRef(albuf->ref) != 0)
            context->setError(AL_INVALID_OPERATION, "Modifying in-use buffer %u's loop points",
                buffer);
        else if UNLIKELY(values[0] < 0 || values[0] >= values[1]
            || static_cast<ALuint>(values[1]) > albuf->mBuffer.mSampleLen)
            context->setError(AL_INVALID_VALUE, "Invalid loop point range %d -> %d on buffer %u",
                values[0], values[1], buffer);
        else
        {
            albuf->LoopStart = static_cast<ALuint>(values[0]);
            albuf->LoopEnd = static_cast<ALuint>(values[1]);
        }
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer integer-vector property 0x%04x", param);
    }
}
END_API_FUNC


AL_API void AL_APIENTRY alGetBufferf(ALuint buffer, ALenum param, ALfloat *value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!value)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer float property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBuffer3f(ALuint buffer, ALenum param, ALfloat *value1, ALfloat *value2, ALfloat *value3)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!value1 || !value2 || !value3)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer 3-float property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBufferfv(ALuint buffer, ALenum param, ALfloat *values)
START_API_FUNC
{
    switch(param)
    {
    case AL_SEC_LENGTH_SOFT:
        alGetBufferf(buffer, param, values);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!values)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer float-vector property 0x%04x", param);
    }
}
END_API_FUNC


AL_API void AL_APIENTRY alGetBufferi(ALuint buffer, ALenum param, ALint *value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!value)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    case AL_FREQUENCY:
        *value = static_cast<ALint>(albuf->mBuffer.mSampleRate);
        break;

    case AL_BITS:
        *value = static_cast<ALint>(albuf->bytesFromFmt() * 8);
        break;

    case AL_CHANNELS:
        *value = static_cast<ALint>(albuf->channelsFromFmt());
        break;

    case AL_SIZE:
        *value = static_cast<ALint>(albuf->mBuffer.mSampleLen * albuf->frameSizeFromFmt());
        break;

    case AL_UNPACK_BLOCK_ALIGNMENT_SOFT:
        *value = static_cast<ALint>(albuf->UnpackAlign);
        break;

    case AL_PACK_BLOCK_ALIGNMENT_SOFT:
        *value = static_cast<ALint>(albuf->PackAlign);
        break;

    case AL_AMBISONIC_LAYOUT_SOFT:
        *value = static_cast<int>(albuf->mBuffer.mAmbiLayout);
        break;

    case AL_AMBISONIC_SCALING_SOFT:
        *value = static_cast<int>(albuf->mBuffer.mAmbiScaling);
        break;

    case AL_UNPACK_AMBISONIC_ORDER_SOFT:
        *value = static_cast<int>(albuf->UnpackAmbiOrder);
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer integer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBuffer3i(ALuint buffer, ALenum param, ALint *value1, ALint *value2, ALint *value3)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!value1 || !value2 || !value3)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer 3-integer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBufferiv(ALuint buffer, ALenum param, ALint *values)
START_API_FUNC
{
    switch(param)
    {
    case AL_FREQUENCY:
    case AL_BITS:
    case AL_CHANNELS:
    case AL_SIZE:
    case AL_INTERNAL_FORMAT_SOFT:
    case AL_BYTE_LENGTH_SOFT:
    case AL_SAMPLE_LENGTH_SOFT:
    case AL_UNPACK_BLOCK_ALIGNMENT_SOFT:
    case AL_PACK_BLOCK_ALIGNMENT_SOFT:
    case AL_AMBISONIC_LAYOUT_SOFT:
    case AL_AMBISONIC_SCALING_SOFT:
    case AL_UNPACK_AMBISONIC_ORDER_SOFT:
        alGetBufferi(buffer, param, values);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!values)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    case AL_LOOP_POINTS_SOFT:
        values[0] = static_cast<ALint>(albuf->LoopStart);
        values[1] = static_cast<ALint>(albuf->LoopEnd);
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer integer-vector property 0x%04x", param);
    }
}
END_API_FUNC


AL_API void AL_APIENTRY alBufferCallbackSOFT(ALuint buffer, ALenum format, ALsizei freq,
    LPALBUFFERCALLBACKTYPESOFT callback, ALvoid *userptr, ALbitfieldSOFT flags)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};

    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(freq < 1)
        context->setError(AL_INVALID_VALUE, "Invalid sample rate %d", freq);
    else if UNLIKELY(callback == nullptr)
        context->setError(AL_INVALID_VALUE, "NULL callback");
    else if UNLIKELY(flags != 0)
        context->setError(AL_INVALID_VALUE, "Invalid callback flags 0x%x", flags);
    else
    {
        auto usrfmt = DecomposeUserFormat(format);
        if UNLIKELY(!usrfmt)
            context->setError(AL_INVALID_ENUM, "Invalid format 0x%04x", format);
        else
            PrepareCallback(context.get(), albuf, freq, usrfmt->channels, usrfmt->type, callback,
                userptr);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBufferPtrSOFT(ALuint buffer, ALenum param, ALvoid **value)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    ALbuffer *albuf = LookupBuffer(device, buffer);
    if UNLIKELY(!albuf)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!value)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    case AL_BUFFER_CALLBACK_FUNCTION_SOFT:
        *value = reinterpret_cast<void*>(albuf->mBuffer.mCallback);
        break;
    case AL_BUFFER_CALLBACK_USER_PARAM_SOFT:
        *value = albuf->mBuffer.mUserData;
        break;

    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer pointer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBuffer3PtrSOFT(ALuint buffer, ALenum param, ALvoid **value1, ALvoid **value2, ALvoid **value3)
START_API_FUNC
{
    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!value1 || !value2 || !value3)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer 3-pointer property 0x%04x", param);
    }
}
END_API_FUNC

AL_API void AL_APIENTRY alGetBufferPtrvSOFT(ALuint buffer, ALenum param, ALvoid **values)
START_API_FUNC
{
    switch(param)
    {
    case AL_BUFFER_CALLBACK_FUNCTION_SOFT:
    case AL_BUFFER_CALLBACK_USER_PARAM_SOFT:
        alGetBufferPtrSOFT(buffer, param, values);
        return;
    }

    ContextRef context{GetContextRef()};
    if UNLIKELY(!context) return;

    ALCdevice *device{context->mDevice.get()};
    std::lock_guard<std::mutex> _{device->BufferLock};
    if UNLIKELY(LookupBuffer(device, buffer) == nullptr)
        context->setError(AL_INVALID_NAME, "Invalid buffer ID %u", buffer);
    else if UNLIKELY(!values)
        context->setError(AL_INVALID_VALUE, "NULL pointer");
    else switch(param)
    {
    default:
        context->setError(AL_INVALID_ENUM, "Invalid buffer pointer-vector property 0x%04x", param);
    }
}
END_API_FUNC


BufferSubList::~BufferSubList()
{
    uint64_t usemask{~FreeMask};
    while(usemask)
    {
        const ALsizei idx{CountTrailingZeros(usemask)};
        al::destroy_at(Buffers+idx);
        usemask &= ~(1_u64 << idx);
    }
    FreeMask = ~usemask;
    al_free(Buffers);
    Buffers = nullptr;
}
