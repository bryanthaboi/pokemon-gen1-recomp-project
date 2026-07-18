#ifndef AL_BYTE_H
#define AL_BYTE_H

#include <cstddef>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace al {

/* The "canonical" way to store raw byte data. Like C++17's std::byte, it's not
 * treated as a character type and does not work with arithmatic ops. Only
 * bitwise ops are allowed.
 */
enum class byte : unsigned char { };

#define REQUIRES(...) std::enable_if_t<(__VA_ARGS__),bool> = true

template<typename T, REQUIRES(std::is_integral<T>::value)>
inline constexpr T to_integer(al::byte b) noexcept { return T(b); }


template<typename T, REQUIRES(std::is_integral<T>::value)>
inline constexpr al::byte operator<<(al::byte lhs, T rhs) noexcept
{ return al::byte(to_integer<unsigned int>(lhs) << rhs); }

template<typename T, REQUIRES(std::is_integral<T>::value)>
inline constexpr al::byte operator>>(al::byte lhs, T rhs) noexcept
{ return al::byte(to_integer<unsigned int>(lhs) >> rhs); }

template<typename T, REQUIRES(std::is_integral<T>::value)>
inline al::byte& operator<<=(al::byte &lhs, T rhs) noexcept
{ lhs = lhs << rhs; return lhs; }

template<typename T, REQUIRES(std::is_integral<T>::value)>
inline al::byte& operator>>=(al::byte &lhs, T rhs) noexcept
{ lhs = lhs >> rhs; return lhs; }

#define AL_DECL_OP(op, opeq)                                                  \
template<typename T, REQUIRES(std::is_integral<T>::value)>                    \
inline constexpr al::byte operator op (al::byte lhs, T rhs) noexcept          \
{ return al::byte(to_integer<unsigned int>(lhs) op static_cast<unsigned int>(rhs)); } \
template<typename T, REQUIRES(std::is_integral<T>::value)>                    \
inline constexpr al::byte& operator opeq (al::byte &lhs, T rhs) noexcept      \
{ lhs = lhs op rhs; return lhs; }                                             \
inline constexpr al::byte operator op (al::byte lhs, al::byte rhs) noexcept   \
{ return al::byte(lhs op to_integer<unsigned int>(rhs)); }                    \
inline constexpr al::byte& operator opeq (al::byte &lhs, al::byte rhs) noexcept \
{ lhs = lhs op rhs; return lhs; }

AL_DECL_OP(|, |=)
AL_DECL_OP(&, &=)
AL_DECL_OP(^, ^=)

#undef AL_DECL_OP

inline constexpr al::byte operator~(al::byte b) noexcept
{ return al::byte(~to_integer<unsigned int>(b)); }


namespace detail_ {
    template<size_t> struct Elem { };
    template<> struct Elem<1> { using type = uint8_t; };
    template<> struct Elem<2> { using type = uint16_t; };
    template<> struct Elem<3> { using type = uint32_t; };
    template<> struct Elem<4> { using type = uint32_t; };

    template<size_t N> using ElemT = typename Elem<N>::type;
} // namespace detail_

template<size_t N>
class bitfield {
    static constexpr size_t bits_per_byte{std::numeric_limits<unsigned char>::digits};
    static constexpr size_t NumElems{(N+bits_per_byte-1) / bits_per_byte};

    using storage_type = detail_::ElemT<NumElems>;
    storage_type vals{};

public:
    template<size_t b>
    inline void set() noexcept
    {
        static_assert(b < N, "Bit index out of range");
        vals |= 1 << b;
    }
    template<size_t b>
    inline void unset() noexcept
    {
        static_assert(b < N, "Bit index out of range");
        vals &= static_cast<storage_type>(~(1 << b));
    }
    template<size_t b>
    inline bool get() const noexcept
    {
        static_assert(b < N, "Bit index out of range");
        return (vals & (1 << b)) != 0;
    }

    template<size_t b, size_t ...args, REQUIRES(sizeof...(args) > 0)>
    void set() noexcept
    {
        set<b>();
        set<args...>();
    }
};

#undef REQUIRES

} // namespace al

#endif /* AL_BYTE_H */
