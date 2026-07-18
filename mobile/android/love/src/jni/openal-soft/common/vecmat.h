#ifndef COMMON_VECMAT_H
#define COMMON_VECMAT_H

#include <array>
#include <cmath>
#include <cstddef>
#include <limits>


namespace alu {

class Vector {
    alignas(16) std::array<float,4> mVals;

public:
    Vector() noexcept = default;
    constexpr Vector(float a, float b, float c, float d) noexcept
      : mVals{{a, b, c, d}}
    { }

    float& operator[](size_t idx) noexcept { return mVals[idx]; }
    constexpr const float& operator[](size_t idx) const noexcept { return mVals[idx]; }

    Vector& operator+=(const Vector &rhs) noexcept
    {
        mVals[0] += rhs.mVals[0];
        mVals[1] += rhs.mVals[1];
        mVals[2] += rhs.mVals[2];
        mVals[3] += rhs.mVals[3];
        return *this;
    }

    float normalize()
    {
        const float length{std::sqrt(mVals[0]*mVals[0] + mVals[1]*mVals[1] + mVals[2]*mVals[2])};
        if(length > std::numeric_limits<float>::epsilon())
        {
            float inv_length = 1.0f/length;
            mVals[0] *= inv_length;
            mVals[1] *= inv_length;
            mVals[2] *= inv_length;
            return length;
        }
        mVals[0] = mVals[1] = mVals[2] = 0.0f;
        return 0.0f;
    }
};

class Matrix {
    alignas(16) std::array<std::array<float,4>,4> mVals;

public:
    Matrix() noexcept = default;
    constexpr Matrix(float aa, float ab, float ac, float ad,
                     float ba, float bb, float bc, float bd,
                     float ca, float cb, float cc, float cd,
                     float da, float db, float dc, float dd) noexcept
      : mVals{{{{aa, ab, ac, ad}}, {{ba, bb, bc, bd}}, {{ca, cb, cc, cd}}, {{da, db, dc, dd}}}}
    { }

    std::array<float,4>& operator[](size_t idx) noexcept { return mVals[idx]; }
    constexpr const std::array<float,4>& operator[](size_t idx) const noexcept { return mVals[idx]; }

    void setRow(size_t idx, float a, float b, float c, float d) noexcept
    {
        mVals[idx][0] = a;
        mVals[idx][1] = b;
        mVals[idx][2] = c;
        mVals[idx][3] = d;
    }

    static constexpr Matrix Identity() noexcept
    {
        return Matrix{
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 0.0f, 0.0f, 1.0f
        };
    }
};

} // namespace alu

#endif /* COMMON_VECMAT_H */
