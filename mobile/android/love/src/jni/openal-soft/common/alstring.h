#ifndef AL_STRING_H
#define AL_STRING_H

#include <cstddef>
#include <cstring>
#include <string>

#include "almalloc.h"


namespace al {

template<typename T, typename Tr=std::char_traits<T>>
using basic_string = std::basic_string<T, Tr, al::allocator<T>>;

using string = basic_string<char>;
using wstring = basic_string<wchar_t>;
using u16string = basic_string<char16_t>;
using u32string = basic_string<char32_t>;


/* These would be better served by using a string_view-like span/view with
 * case-insensitive char traits.
 */
int strcasecmp(const char *str0, const char *str1) noexcept;
int strncasecmp(const char *str0, const char *str1, std::size_t len) noexcept;

} // namespace al

#endif /* AL_STRING_H */
