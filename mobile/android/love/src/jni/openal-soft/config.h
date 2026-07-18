/* API declaration export attribute */
#define AL_API  __attribute__((visibility("default")))
#define ALC_API __attribute__((visibility("default")))

/* Define a restrict macro for non-aliased pointers */
#define RESTRICT __restrict

/* Define if HRTF data is embedded in the library */
#define ALSOFT_EMBED_HRTF_DATA

/* Define if we have the std::aligned_alloc function */
/* #undef HAVE_STD_ALIGNED_ALLOC */

/* Define if we have the posix_memalign function */
/* #undef HAVE_POSIX_MEMALIGN */ /* arm64-v8a/x86_64: define */

/* Define if we have the _aligned_malloc function */
/* #undef HAVE__ALIGNED_MALLOC */

/* Define if we have the proc_pidpath function */
/* #undef HAVE_PROC_PIDPATH */

/* Define if we have the getopt function */
#define HAVE_GETOPT

/* Define if we have SSE CPU extensions */
/* #undef HAVE_SSE */ /* x86(_64): define */
/* #undef HAVE_SSE2 */ /* x86(_64): define */
/* #undef HAVE_SSE3 */ /* x86(_64): define */
/* #undef HAVE_SSE4_1 */ /* x86_64: define */

/* Define if we have ARM Neon CPU extensions */
/* #undef HAVE_NEON */ /* armeabi-v7a/arm64-v8a: define */

/* Define if we have the ALSA backend */
/* #undef HAVE_ALSA */

/* Define if we have the OSS backend */
/* #undef HAVE_OSS */

/* Define if we have the Solaris backend */
/* #undef HAVE_SOLARIS */

/* Define if we have the SndIO backend */
/* #undef HAVE_SNDIO */

/* Define if we have the WASAPI backend */
/* #undef HAVE_WASAPI */

/* Define if we have the DSound backend */
/* #undef HAVE_DSOUND */

/* Define if we have the Windows Multimedia backend */
/* #undef HAVE_WINMM */

/* Define if we have the PortAudio backend */
/* #undef HAVE_PORTAUDIO */

/* Define if we have the PulseAudio backend */
/* #undef HAVE_PULSEAUDIO */

/* Define if we have the JACK backend */
/* #undef HAVE_JACK */

/* Define if we have the CoreAudio backend */
/* #undef HAVE_COREAUDIO */

/* Define if we have the OpenSL backend */
/* #undef HAVE_OPENSL */

/* Define if we have the Oboe backend */
/* #undef HAVE_OBOE */

/* Define if we have the Wave Writer backend */
#define HAVE_WAVE

/* Define if we have the SDL2 backend */
/* #undef HAVE_SDL2 */

/* Define if we have dlfcn.h */
#define HAVE_DLFCN_H

/* Define if we have pthread_np.h */
/* #undef HAVE_PTHREAD_NP_H */

/* Define if we have malloc.h */
#define HAVE_MALLOC_H

/* Define if we have cpuid.h */
/* #undef HAVE_CPUID_H */ /* x86(_64): define */

/* Define if we have intrin.h */
/* #undef HAVE_INTRIN_H */

/* Define if we have guiddef.h */
/* #undef HAVE_GUIDDEF_H */

/* Define if we have initguid.h */
/* #undef HAVE_INITGUID_H */

/* Define if we have GCC's __get_cpuid() */
/* #undef HAVE_GCC_GET_CPUID */ /* x86(_64): define */

/* Define if we have the __cpuid() intrinsic */
/* #undef HAVE_CPUID_INTRINSIC */

/* Define if we have SSE intrinsics */
/* #undef HAVE_SSE_INTRINSICS */ /* x86(_64): define */

/* Define if we have pthread_setschedparam() */
#define HAVE_PTHREAD_SETSCHEDPARAM

/* Define if we have pthread_setname_np() */
#define HAVE_PTHREAD_SETNAME_NP

/* Define if pthread_setname_np() only accepts one parameter */
/* #undef PTHREAD_SETNAME_NP_ONE_PARAM */

/* Define if pthread_setname_np() accepts three parameters */
/* #undef PTHREAD_SETNAME_NP_THREE_PARAMS */

/* Define if we have pthread_set_name_np() */
/* #undef HAVE_PTHREAD_SET_NAME_NP */
