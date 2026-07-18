#ifndef CONVERTER_H
#define CONVERTER_H

#include <cstddef>
#include <memory>

#include "AL/al.h"

#include "alcmain.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "alu.h"
#include "devformat.h"
#include "voice.h"


struct SampleConverter {
    DevFmtType mSrcType{};
    DevFmtType mDstType{};
    ALuint mSrcTypeSize{};
    ALuint mDstTypeSize{};

    int mSrcPrepCount{};

    ALuint mFracOffset{};
    ALuint mIncrement{};
    InterpState mState{};
    ResamplerFunc mResample{};

    alignas(16) float mSrcSamples[BUFFERSIZE]{};
    alignas(16) float mDstSamples[BUFFERSIZE]{};

    struct ChanSamples {
        alignas(16) float PrevSamples[MAX_RESAMPLER_PADDING];
    };
    al::FlexArray<ChanSamples> mChan;

    SampleConverter(size_t numchans) : mChan{numchans} { }

    ALuint convert(const void **src, ALuint *srcframes, void *dst, ALuint dstframes);
    ALuint availableOut(ALuint srcframes) const;

    DEF_FAM_NEWDEL(SampleConverter, mChan)
};
using SampleConverterPtr = std::unique_ptr<SampleConverter>;

SampleConverterPtr CreateSampleConverter(DevFmtType srcType, DevFmtType dstType, size_t numchans,
    ALuint srcRate, ALuint dstRate, Resampler resampler);


struct ChannelConverter {
    DevFmtType mSrcType{};
    ALuint mSrcStep{};
    ALuint mChanMask{};
    DevFmtChannels mDstChans{};

    bool is_active() const noexcept { return mChanMask != 0; }

    void convert(const void *src, float *dst, ALuint frames) const;
};

#endif /* CONVERTER_H */
