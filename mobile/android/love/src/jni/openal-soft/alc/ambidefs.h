#ifndef AMBIDEFS_H
#define AMBIDEFS_H

#include <array>
#include <cstdint>

/* The maximum number of Ambisonics channels. For a given order (o), the size
 * needed will be (o+1)**2, thus zero-order has 1, first-order has 4, second-
 * order has 9, third-order has 16, and fourth-order has 25.
 */
#define MAX_AMBI_ORDER 3
constexpr inline size_t AmbiChannelsFromOrder(size_t order) noexcept
{ return (order+1) * (order+1); }
#define MAX_AMBI_CHANNELS AmbiChannelsFromOrder(MAX_AMBI_ORDER)

/* A bitmask of ambisonic channels for 0 to 4th order. This only specifies up
 * to 4th order, which is the highest order a 32-bit mask value can specify (a
 * 64-bit mask could handle up to 7th order).
 */
#define AMBI_0ORDER_MASK 0x00000001
#define AMBI_1ORDER_MASK 0x0000000f
#define AMBI_2ORDER_MASK 0x000001ff
#define AMBI_3ORDER_MASK 0x0000ffff
#define AMBI_4ORDER_MASK 0x01ffffff

/* A bitmask of ambisonic channels with height information. If none of these
 * channels are used/needed, there's no height (e.g. with most surround sound
 * speaker setups). This is ACN ordering, with bit 0 being ACN 0, etc.
 */
#define AMBI_PERIPHONIC_MASK 0xfe7ce4

/* The maximum number of ambisonic channels for 2D (non-periphonic)
 * representation. This is 2 per each order above zero-order, plus 1 for zero-
 * order. Or simply, o*2 + 1.
 */
constexpr inline size_t Ambi2DChannelsFromOrder(size_t order) noexcept
{ return order*2 + 1; }
#define MAX_AMBI2D_CHANNELS Ambi2DChannelsFromOrder(MAX_AMBI_ORDER)


/* NOTE: These are scale factors as applied to Ambisonics content. Decoder
 * coefficients should be divided by these values to get proper scalings.
 */
struct AmbiScale {
    static constexpr std::array<float,MAX_AMBI_CHANNELS> FromN3D{{
        1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f,
        1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f
    }};
    static constexpr std::array<float,MAX_AMBI_CHANNELS> FromSN3D{{
        1.000000000f, /* ACN  0, sqrt(1) */
        1.732050808f, /* ACN  1, sqrt(3) */
        1.732050808f, /* ACN  2, sqrt(3) */
        1.732050808f, /* ACN  3, sqrt(3) */
        2.236067978f, /* ACN  4, sqrt(5) */
        2.236067978f, /* ACN  5, sqrt(5) */
        2.236067978f, /* ACN  6, sqrt(5) */
        2.236067978f, /* ACN  7, sqrt(5) */
        2.236067978f, /* ACN  8, sqrt(5) */
        2.645751311f, /* ACN  9, sqrt(7) */
        2.645751311f, /* ACN 10, sqrt(7) */
        2.645751311f, /* ACN 11, sqrt(7) */
        2.645751311f, /* ACN 12, sqrt(7) */
        2.645751311f, /* ACN 13, sqrt(7) */
        2.645751311f, /* ACN 14, sqrt(7) */
        2.645751311f, /* ACN 15, sqrt(7) */
    }};
    static constexpr std::array<float,MAX_AMBI_CHANNELS> FromFuMa{{
        1.414213562f, /* ACN  0 (W), sqrt(2) */
        1.732050808f, /* ACN  1 (Y), sqrt(3) */
        1.732050808f, /* ACN  2 (Z), sqrt(3) */
        1.732050808f, /* ACN  3 (X), sqrt(3) */
        1.936491673f, /* ACN  4 (V), sqrt(15)/2 */
        1.936491673f, /* ACN  5 (T), sqrt(15)/2 */
        2.236067978f, /* ACN  6 (R), sqrt(5) */
        1.936491673f, /* ACN  7 (S), sqrt(15)/2 */
        1.936491673f, /* ACN  8 (U), sqrt(15)/2 */
        2.091650066f, /* ACN  9 (Q), sqrt(35/8) */
        1.972026594f, /* ACN 10 (O), sqrt(35)/3 */
        2.231093404f, /* ACN 11 (M), sqrt(224/45) */
        2.645751311f, /* ACN 12 (K), sqrt(7) */
        2.231093404f, /* ACN 13 (L), sqrt(224/45) */
        1.972026594f, /* ACN 14 (N), sqrt(35)/3 */
        2.091650066f, /* ACN 15 (P), sqrt(35/8) */
    }};
};

struct AmbiIndex {
    static constexpr std::array<uint8_t,MAX_AMBI_CHANNELS> FromFuMa{{
        0,  /* W */
        3,  /* X */
        1,  /* Y */
        2,  /* Z */
        6,  /* R */
        7,  /* S */
        5,  /* T */
        8,  /* U */
        4,  /* V */
        12, /* K */
        13, /* L */
        11, /* M */
        14, /* N */
        10, /* O */
        15, /* P */
        9,  /* Q */
    }};
    static constexpr std::array<uint8_t,MAX_AMBI2D_CHANNELS> FromFuMa2D{{
        0,  /* W */
        3,  /* X */
        1,  /* Y */
        8,  /* U */
        4,  /* V */
        15, /* P */
        9,  /* Q */
    }};

    static constexpr std::array<uint8_t,MAX_AMBI_CHANNELS> FromACN{{
        0,  1,  2,  3,  4,  5,  6,  7,
        8,  9, 10, 11, 12, 13, 14, 15
    }};
    static constexpr std::array<uint8_t,MAX_AMBI2D_CHANNELS> From2D{{
        0, 1,3, 4,8, 9,15
    }};

    static constexpr std::array<uint8_t,MAX_AMBI_CHANNELS> OrderFromChannel{{
        0, 1,1,1, 2,2,2,2,2, 3,3,3,3,3,3,3,
    }};
    static constexpr std::array<uint8_t,MAX_AMBI2D_CHANNELS> OrderFrom2DChannel{{
        0, 1,1, 2,2, 3,3,
    }};
};

#endif /* AMBIDEFS_H */
