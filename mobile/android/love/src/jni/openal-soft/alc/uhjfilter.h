#ifndef UHJFILTER_H
#define UHJFILTER_H

#include <array>

#include "alcmain.h"
#include "almalloc.h"


struct Uhj2Encoder {
    /* A particular property of the filter allows it to cover nearly twice its
     * length, so the filter size is also the effective delay (despite being
     * center-aligned).
     */
    constexpr static size_t sFilterSize{128};

    /* Delays for the unfiltered signal. */
    alignas(16) std::array<float,sFilterSize> mMidDelay{};
    alignas(16) std::array<float,sFilterSize> mSideDelay{};

    alignas(16) std::array<float,BUFFERSIZE+sFilterSize> mMid{};
    alignas(16) std::array<float,BUFFERSIZE+sFilterSize> mSide{};

    /* History for the FIR filter. */
    alignas(16) std::array<float,sFilterSize*2 - 1> mSideHistory{};

    alignas(16) std::array<float,BUFFERSIZE + sFilterSize*2> mTemp{};

    /**
     * Encodes a 2-channel UHJ (stereo-compatible) signal from a B-Format input
     * signal. The input must use FuMa channel ordering and scaling.
     */
    void encode(FloatBufferLine &LeftOut, FloatBufferLine &RightOut,
        const FloatBufferLine *InSamples, const size_t SamplesToDo);

    DEF_NEWDEL(Uhj2Encoder)
};

#endif /* UHJFILTER_H */
