#ifndef OPTHELPERS_H
#define OPTHELPERS_H

#ifdef __has_builtin
#define HAS_BUILTIN __has_builtin
#else
#define HAS_BUILTIN(x) (0)
#endif

#ifdef __GNUC__
/* LIKELY optimizes the case where the condition is true. The condition is not
 * required to be true, but it can result in more optimal code for the true
 * path at the expense of a less optimal false path.
 */
#define LIKELY(x) (__builtin_expect(!!(x), !false))
/* The opposite of LIKELY, optimizing the case where the condition is false. */
#define UNLIKELY(x) (__builtin_expect(!!(x), false))
/* Unlike LIKELY, ASSUME requires the condition to be true or else it invokes
 * undefined behavior. It's essentially an assert without actually checking the
 * condition at run-time, allowing for stronger optimizations than LIKELY.
 */
#if HAS_BUILTIN(__builtin_assume)
#define ASSUME __builtin_assume
#else
#define ASSUME(x) do { if(!(x)) __builtin_unreachable(); } while(0)
#endif

#else /* __GNUC__ */

#define LIKELY(x) (!!(x))
#define UNLIKELY(x) (!!(x))
#ifdef _MSC_VER
#define ASSUME __assume
#else
#define ASSUME(x) ((void)0)
#endif /* _MSC_VER */
#endif /* __GNUC__ */

#endif /* OPTHELPERS_H */
