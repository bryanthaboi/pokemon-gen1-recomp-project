#ifndef AL_MALLOC_H
#define AL_MALLOC_H

#include <algorithm>
#include <cstddef>
#include <iterator>
#include <limits>
#include <memory>
#include <new>
#include <type_traits>
#include <utility>

#include "pragmadefs.h"


[[gnu::alloc_align(1), gnu::alloc_size(2)]] void *al_malloc(size_t alignment, size_t size);
[[gnu::alloc_align(1), gnu::alloc_size(2)]] void *al_calloc(size_t alignment, size_t size);
void al_free(void *ptr) noexcept;


#define DISABLE_ALLOC()                                                       \
    void *operator new(size_t) = delete;                                      \
    void *operator new[](size_t) = delete;                                    \
    void operator delete(void*) noexcept = delete;                            \
    void operator delete[](void*) noexcept = delete;

#define DEF_NEWDEL(T)                                                         \
    void *operator new(size_t size)                                           \
    {                                                                         \
        void *ret = al_malloc(alignof(T), size);                              \
        if(!ret) throw std::bad_alloc();                                      \
        return ret;                                                           \
    }                                                                         \
    void *operator new[](size_t size) { return operator new(size); }          \
    void operator delete(void *block) noexcept { al_free(block); }            \
    void operator delete[](void *block) noexcept { operator delete(block); }

#define DEF_PLACE_NEWDEL()                                                    \
    void *operator new(size_t /*size*/, void *ptr) noexcept { return ptr; }   \
    void *operator new[](size_t /*size*/, void *ptr) noexcept { return ptr; } \
    void operator delete(void *block, void*) noexcept { al_free(block); }     \
    void operator delete(void *block) noexcept { al_free(block); }            \
    void operator delete[](void *block, void*) noexcept { al_free(block); }   \
    void operator delete[](void *block) noexcept { al_free(block); }

enum FamCount : size_t { };

#define DEF_FAM_NEWDEL(T, FamMem)                                             \
    static constexpr size_t Sizeof(size_t count) noexcept                     \
    {                                                                         \
        return std::max<size_t>(sizeof(T),                                    \
            decltype(FamMem)::Sizeof(count, offsetof(T, FamMem)));            \
    }                                                                         \
                                                                              \
    void *operator new(size_t /*size*/, FamCount count)                       \
    {                                                                         \
        if(void *ret{al_malloc(alignof(T), T::Sizeof(count))})                \
            return ret;                                                       \
        throw std::bad_alloc();                                               \
    }                                                                         \
    void *operator new[](size_t /*size*/) = delete;                           \
    void operator delete(void *block, FamCount) { al_free(block); }           \
    void operator delete(void *block) noexcept { al_free(block); }            \
    void operator delete[](void* /*block*/) = delete;


namespace al {

#define REQUIRES(...) typename std::enable_if<(__VA_ARGS__),int>::type = 0

template<typename T, std::size_t alignment=alignof(T)>
struct allocator {
    using value_type = T;
    using reference = T&;
    using const_reference = const T&;
    using pointer = T*;
    using const_pointer = const T*;
    using size_type = std::size_t;
    using difference_type = std::ptrdiff_t;
    using is_always_equal = std::true_type;

    template<typename U>
    struct rebind {
        using other = allocator<U, (alignment<alignof(U))?alignof(U):alignment>;
    };

    allocator() noexcept = default;
    template<typename U, std::size_t N>
    constexpr allocator(const allocator<U,N>&) noexcept { }

    [[gnu::assume_aligned(alignment), gnu::alloc_size(2)]] T *allocate(std::size_t n)
    {
        if(n > std::numeric_limits<std::size_t>::max()/sizeof(T)) throw std::bad_alloc();
        if(auto p = static_cast<T*>(al_malloc(alignment, n*sizeof(T)))) return p;
        throw std::bad_alloc();
    }
    void deallocate(T *p, std::size_t) noexcept { al_free(p); }
};
template<typename T, std::size_t N, typename U, std::size_t M>
bool operator==(const allocator<T,N>&, const allocator<U,M>&) noexcept { return true; }
template<typename T, std::size_t N, typename U, std::size_t M>
bool operator!=(const allocator<T,N>&, const allocator<U,M>&) noexcept { return false; }

template<size_t alignment, typename T>
[[gnu::assume_aligned(alignment)]] inline T* assume_aligned(T *ptr) noexcept { return ptr; }

/* At least VS 2015 complains that 'ptr' is unused when the given type's
 * destructor is trivial (a no-op). So disable that warning for this call.
 */
DIAGNOSTIC_PUSH
msc_pragma(warning(disable : 4100))
template<typename T>
inline void destroy_at(T *ptr) { ptr->~T(); }
DIAGNOSTIC_POP

template<typename T>
inline void destroy(T first, const T end)
{
    while(first != end)
    {
        al::destroy_at(std::addressof(*first));
        ++first;
    }
}

template<typename T, typename N, REQUIRES(std::is_integral<N>::value)>
inline T destroy_n(T first, N count)
{
    if(count != 0)
    {
        do {
            al::destroy_at(std::addressof(*first));
            ++first;
        } while(--count);
    }
    return first;
}


template<typename T, typename N, REQUIRES(std::is_integral<N>::value)>
inline T uninitialized_default_construct_n(T first, N count)
{
    using ValueT = typename std::iterator_traits<T>::value_type;
    T current{first};
    if(count != 0)
    {
        try {
            do {
                ::new(static_cast<void*>(std::addressof(*current))) ValueT;
                ++current;
            } while(--count);
        }
        catch(...) {
            al::destroy(first, current);
            throw;
        }
    }
    return current;
}


/* A flexible array type. Used either standalone or at the end of a parent
 * struct, with placement new, to have a run-time-sized array that's embedded
 * with its size.
 */
template<typename T, size_t alignment=alignof(T)>
struct FlexArray {
    using element_type = T;
    using value_type = std::remove_cv_t<T>;
    using index_type = size_t;
    using difference_type = ptrdiff_t;

    using pointer = T*;
    using const_pointer = const T*;
    using reference = T&;
    using const_reference = const T&;

    using iterator = pointer;
    using const_iterator = const_pointer;
    using reverse_iterator = std::reverse_iterator<iterator>;
    using const_reverse_iterator = std::reverse_iterator<const_iterator>;


    const index_type mSize;
    union {
        char mDummy;
        alignas(alignment) element_type mArray[1];
    };

    static std::unique_ptr<FlexArray> Create(index_type count)
    {
        void *ptr{al_calloc(alignof(FlexArray), Sizeof(count))};
        return std::unique_ptr<FlexArray>{new(ptr) FlexArray{count}};
    }
    static constexpr index_type Sizeof(index_type count, index_type base=0u) noexcept
    {
        return base +
            std::max<index_type>(offsetof(FlexArray, mArray) + sizeof(T)*count, sizeof(FlexArray));
    }

    FlexArray(index_type size) : mSize{size}
    { al::uninitialized_default_construct_n(mArray, mSize); }
    ~FlexArray() { al::destroy_n(mArray, mSize); }

    FlexArray(const FlexArray&) = delete;
    FlexArray& operator=(const FlexArray&) = delete;

    index_type size() const noexcept { return mSize; }
    bool empty() const noexcept { return mSize == 0; }

    pointer data() noexcept { return mArray; }
    const_pointer data() const noexcept { return mArray; }

    reference operator[](index_type i) noexcept { return mArray[i]; }
    const_reference operator[](index_type i) const noexcept { return mArray[i]; }

    reference front() noexcept { return mArray[0]; }
    const_reference front() const noexcept { return mArray[0]; }

    reference back() noexcept { return mArray[mSize-1]; }
    const_reference back() const noexcept { return mArray[mSize-1]; }

    iterator begin() noexcept { return mArray; }
    const_iterator begin() const noexcept { return mArray; }
    const_iterator cbegin() const noexcept { return mArray; }
    iterator end() noexcept { return mArray + mSize; }
    const_iterator end() const noexcept { return mArray + mSize; }
    const_iterator cend() const noexcept { return mArray + mSize; }

    reverse_iterator rbegin() noexcept { return end(); }
    const_reverse_iterator rbegin() const noexcept { return end(); }
    const_reverse_iterator crbegin() const noexcept { return cend(); }
    reverse_iterator rend() noexcept { return begin(); }
    const_reverse_iterator rend() const noexcept { return begin(); }
    const_reverse_iterator crend() const noexcept { return cbegin(); }

    DEF_PLACE_NEWDEL()
};

#undef REQUIRES

} // namespace al

#endif /* AL_MALLOC_H */
