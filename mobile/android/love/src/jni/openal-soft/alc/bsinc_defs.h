#ifndef BSINC_DEFS_H
#define BSINC_DEFS_H

/* The number of distinct scale and phase intervals within the filter table. */
constexpr unsigned int BSincScaleBits{4};
constexpr unsigned int BSincScaleCount{1 << BSincScaleBits};
constexpr unsigned int BSincPhaseBits{5};
constexpr unsigned int BSincPhaseCount{1 << BSincPhaseBits};

/* The maximum number of sample points for the bsinc filters. The max points
 * includes the doubling for downsampling, so the maximum number of base sample
 * points is 24, which is 23rd order.
 */
constexpr unsigned int BSincPointsMax{48};

#endif /* BSINC_DEFS_H */
