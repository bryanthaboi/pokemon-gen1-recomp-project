
#include "config.h"

#include "alcomplex.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <utility>

#include "math_defs.h"


void complex_fft(const al::span<std::complex<double>> buffer, const double sign)
{
    const size_t fftsize{buffer.size()};
    /* Bit-reversal permutation applied to a sequence of FFTSize items */
    for(size_t i{1u};i < fftsize-1;i++)
    {
        size_t j{0u};
        for(size_t imask{i + fftsize};imask;imask >>= 1)
            j = (j<<1) + (imask&1);
        j >>= 1;

        if(i < j)
            std::swap(buffer[i], buffer[j]);
    }

    /* Iterative form of Danielson-Lanczos lemma */
    size_t step{2u};
    for(size_t i{1u};i < fftsize;i<<=1, step<<=1)
    {
        const size_t step2{step >> 1};
        const double arg{al::MathDefs<double>::Pi() / static_cast<double>(step2)};

        const std::complex<double> w{std::cos(arg), std::sin(arg)*sign};
        std::complex<double> u{1.0, 0.0};
        for(size_t j{0};j < step2;j++)
        {
            for(size_t k{j};k < fftsize;k+=step)
            {
                std::complex<double> temp{buffer[k+step2] * u};
                buffer[k+step2] = buffer[k] - temp;
                buffer[k] += temp;
            }

            u *= w;
        }
    }
}

void complex_hilbert(const al::span<std::complex<double>> buffer)
{
    inverse_fft(buffer);

    const double inverse_size = 1.0/static_cast<double>(buffer.size());
    auto bufiter = buffer.begin();
    const auto halfiter = bufiter + (buffer.size()>>1);

    *bufiter *= inverse_size; ++bufiter;
    bufiter = std::transform(bufiter, halfiter, bufiter,
        [inverse_size](const std::complex<double> &c) -> std::complex<double>
        { return c * (2.0*inverse_size); });
    *bufiter *= inverse_size; ++bufiter;

    std::fill(bufiter, buffer.end(), std::complex<double>{});

    forward_fft(buffer);
}
