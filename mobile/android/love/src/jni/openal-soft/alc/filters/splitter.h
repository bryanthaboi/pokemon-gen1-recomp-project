#ifndef FILTER_SPLITTER_H
#define FILTER_SPLITTER_H

#include <cstddef>

#include "alspan.h"


/* Band splitter. Splits a signal into two phase-matching frequency bands. */
template<typename Real>
class BandSplitterR {
    Real mCoeff{0.0f};
    Real mLpZ1{0.0f};
    Real mLpZ2{0.0f};
    Real mApZ1{0.0f};

public:
    BandSplitterR() = default;
    BandSplitterR(const BandSplitterR&) = default;
    BandSplitterR(Real f0norm) { init(f0norm); }

    void init(Real f0norm);
    void clear() noexcept { mLpZ1 = mLpZ2 = mApZ1 = 0.0f; }
    void process(const al::span<const Real> input, Real *hpout, Real *lpout);

    void processHfScale(const al::span<Real> samples, const Real hfscale);

    /* The all-pass portion of the band splitter. Applies the same phase shift
     * without splitting the signal. Note that each use of this method is
     * indepedent, it does not track history between calls.
     */
    void applyAllpass(const al::span<Real> samples) const;
};
using BandSplitter = BandSplitterR<float>;

#endif /* FILTER_SPLITTER_H */
