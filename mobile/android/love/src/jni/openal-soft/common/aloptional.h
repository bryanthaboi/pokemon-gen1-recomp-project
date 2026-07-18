#ifndef AL_OPTIONAL_H
#define AL_OPTIONAL_H

#include <initializer_list>
#include <type_traits>
#include <utility>

#include "almalloc.h"

namespace al {

#define REQUIRES(...) bool rt_=true, std::enable_if_t<rt_ && (__VA_ARGS__),bool> = true

struct nullopt_t { };
struct in_place_t { };

constexpr nullopt_t nullopt{};
constexpr in_place_t in_place{};

template<typename T>
class optional {
    bool mHasValue{false};
    union {
        char mDummy[sizeof(T)]{};
        T mValue;
    };

    template<typename... Args>
    void DoConstruct(Args&& ...args)
    {
        ::new (std::addressof(mValue)) T{std::forward<Args>(args)...};
        mHasValue = true;
    }

public:
    using value_type = T;

    optional() noexcept = default;
    optional(nullopt_t) noexcept { }
    template<REQUIRES(std::is_copy_constructible<T>::value)>
    optional(const optional &rhs) { if(rhs) DoConstruct(*rhs); }
    template<REQUIRES(std::is_move_constructible<T>::value)>
    optional(optional&& rhs) { if(rhs) DoConstruct(std::move(*rhs)); }
    template<typename... Args, REQUIRES(std::is_constructible<T, Args...>::value)>
    explicit optional(in_place_t, Args&& ...args) : mHasValue{true}
      , mValue{std::forward<Args>(args)...}
    { }
    template<typename U, typename... Args, REQUIRES(std::is_constructible<T, std::initializer_list<U>&, Args...>::value)>
    explicit optional(in_place_t, std::initializer_list<U> il, Args&& ...args)
      : mHasValue{true}, mValue{il, std::forward<Args>(args)...}
    { }
    template<typename U=value_type, REQUIRES(std::is_constructible<T, U&&>::value &&
        !std::is_same<typename std::decay<U>::type, in_place_t>::value &&
        !std::is_same<typename std::decay<U>::type, optional<T>>::value &&
        std::is_constructible<U&&, T>::value)>
    constexpr explicit optional(U&& value) : mHasValue{true}, mValue{std::forward<U>(value)}
    { }
    template<typename U=value_type, REQUIRES(std::is_constructible<T, U&&>::value &&
        !std::is_same<typename std::decay<U>::type, in_place_t>::value &&
        !std::is_same<typename std::decay<U>::type, optional<T>>::value &&
        !std::is_constructible<U&&, T>::value)>
    constexpr optional(U&& value) : mHasValue{true}, mValue{std::forward<U>(value)}
    { }
    ~optional() { if(mHasValue) al::destroy_at(std::addressof(mValue)); }

    optional& operator=(nullopt_t) noexcept { reset(); return *this; }
    template<REQUIRES(std::is_copy_constructible<T>::value && std::is_copy_assignable<T>::value)>
    optional& operator=(const optional &rhs)
    {
        if(!rhs)
            reset();
        else if(*this)
            mValue = *rhs;
        else
            DoConstruct(*rhs);
        return *this;
    }
    template<REQUIRES(std::is_move_constructible<T>::value && std::is_move_assignable<T>::value)>
    optional& operator=(optional&& rhs)
    {
        if(!rhs)
            reset();
        else if(*this)
            mValue = std::move(*rhs);
        else
            DoConstruct(std::move(*rhs));
        return *this;
    }
    template<typename U=T, REQUIRES(std::is_constructible<T, U>::value &&
        std::is_assignable<T&, U>::value &&
        !std::is_same<typename std::decay<U>::type, optional<T>>::value &&
        (!std::is_same<typename std::decay<U>::type, T>::value ||
        !std::is_scalar<U>::value))>
    optional& operator=(U&& rhs)
    {
        if(*this)
            mValue = std::forward<U>(rhs);
        else
            DoConstruct(std::forward<U>(rhs));
        return *this;
    }

    const T* operator->() const { return std::addressof(mValue); }
    T* operator->() { return std::addressof(mValue); }
    const T& operator*() const& { return mValue; }
    T& operator*() & { return mValue; }
    const T&& operator*() const&& { return std::move(mValue); }
    T&& operator*() && { return std::move(mValue); }

    operator bool() const noexcept { return mHasValue; }
    bool has_value() const noexcept { return mHasValue; }

    T& value() & { return mValue; }
    const T& value() const& { return mValue; }
    T&& value() && { return std::move(mValue); }
    const T&& value() const&& { return std::move(mValue); }

    template<typename U>
    T value_or(U&& defval) const&
    { return bool{*this} ? **this : static_cast<T>(std::forward<U>(defval)); }
    template<typename U>
    T value_or(U&& defval) &&
    { return bool{*this} ? std::move(**this) : static_cast<T>(std::forward<U>(defval)); }

    void reset() noexcept
    {
        if(mHasValue)
            al::destroy_at(std::addressof(mValue));
        mHasValue = false;
    }
};

template<typename T>
inline optional<std::decay_t<T>> make_optional(T&& arg)
{ return optional<std::decay_t<T>>{in_place, std::forward<T>(arg)}; }

template<typename T, typename... Args>
inline optional<T> make_optional(Args&& ...args)
{ return optional<T>{in_place, std::forward<Args>(args)...}; }

template<typename T, typename U, typename... Args>
inline optional<T> make_optional(std::initializer_list<U> il, Args&& ...args)
{ return optional<T>{in_place, il, std::forward<Args>(args)...}; }

#undef REQUIRES

} // namespace al

#endif /* AL_SPAN_H */
