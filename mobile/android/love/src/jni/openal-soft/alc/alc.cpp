/**
 * OpenAL cross platform audio library
 * Copyright (C) 1999-2007 by authors.
 * This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Library General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 *  License along with this library; if not, write to the
 *  Free Software Foundation, Inc.,
 *  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 * Or go to http://www.gnu.org/copyleft/lgpl.html
 */

#include "config.h"

#include "version.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <exception>
#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cinttypes>
#include <climits>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <numeric>
#include <string>
#include <thread>
#include <utility>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/alext.h"
#include "AL/efx.h"

#include "al/auxeffectslot.h"
#include "al/effect.h"
#include "al/event.h"
#include "al/filter.h"
#include "al/listener.h"
#include "al/source.h"
#include "alcmain.h"
#include "albyte.h"
#include "alconfig.h"
#include "alcontext.h"
#include "alexcpt.h"
#include "almalloc.h"
#include "alnumeric.h"
#include "aloptional.h"
#include "alspan.h"
#include "alstring.h"
#include "alu.h"
#include "ambidefs.h"
#include "atomic.h"
#include "bformatdec.h"
#include "bs2b.h"
#include "compat.h"
#include "cpu_caps.h"
#include "devformat.h"
#include "effects/base.h"
#include "filters/nfc.h"
#include "filters/splitter.h"
#include "fpu_ctrl.h"
#include "front_stablizer.h"
#include "hrtf.h"
#include "inprogext.h"
#include "intrusive_ptr.h"
#include "logging.h"
#include "mastering.h"
#include "opthelpers.h"
#include "pragmadefs.h"
#include "ringbuffer.h"
#include "strutils.h"
#include "threads.h"
#include "uhjfilter.h"
#include "vecmat.h"
#include "vector.h"

#include "backends/base.h"
#include "backends/null.h"
#include "backends/loopback.h"
#ifdef HAVE_JACK
#include "backends/jack.h"
#endif
#ifdef HAVE_PULSEAUDIO
#include "backends/pulseaudio.h"
#endif
#ifdef HAVE_ALSA
#include "backends/alsa.h"
#endif
#ifdef HAVE_WASAPI
#include "backends/wasapi.h"
#endif
#ifdef HAVE_COREAUDIO
#include "backends/coreaudio.h"
#endif
#ifdef HAVE_OPENSL
#include "backends/opensl.h"
#endif
#ifdef HAVE_OBOE
#include "backends/oboe.h"
#endif
#ifdef HAVE_SOLARIS
#include "backends/solaris.h"
#endif
#ifdef HAVE_SNDIO
#include "backends/sndio.h"
#endif
#ifdef HAVE_OSS
#include "backends/oss.h"
#endif
#ifdef HAVE_DSOUND
#include "backends/dsound.h"
#endif
#ifdef HAVE_WINMM
#include "backends/winmm.h"
#endif
#ifdef HAVE_PORTAUDIO
#include "backends/portaudio.h"
#endif
#ifdef HAVE_SDL2
#include "backends/sdl2.h"
#endif
#ifdef HAVE_WAVE
#include "backends/wave.h"
#endif


namespace {

using namespace std::placeholders;
using std::chrono::seconds;
using std::chrono::nanoseconds;


/************************************************
 * Backends
 ************************************************/
struct BackendInfo {
    const char *name;
    BackendFactory& (*getFactory)(void);
};

BackendInfo BackendList[] = {
#ifdef HAVE_JACK
    { "jack", JackBackendFactory::getFactory },
#endif
#ifdef HAVE_PULSEAUDIO
    { "pulse", PulseBackendFactory::getFactory },
#endif
#ifdef HAVE_ALSA
    { "alsa", AlsaBackendFactory::getFactory },
#endif
#ifdef HAVE_WASAPI
    { "wasapi", WasapiBackendFactory::getFactory },
#endif
#ifdef HAVE_COREAUDIO
    { "core", CoreAudioBackendFactory::getFactory },
#endif
#ifdef HAVE_OBOE
    { "oboe", OboeBackendFactory::getFactory },
#endif
#ifdef HAVE_OPENSL
    { "opensl", OSLBackendFactory::getFactory },
#endif
#ifdef HAVE_SOLARIS
    { "solaris", SolarisBackendFactory::getFactory },
#endif
#ifdef HAVE_SNDIO
    { "sndio", SndIOBackendFactory::getFactory },
#endif
#ifdef HAVE_OSS
    { "oss", OSSBackendFactory::getFactory },
#endif
#ifdef HAVE_DSOUND
    { "dsound", DSoundBackendFactory::getFactory },
#endif
#ifdef HAVE_WINMM
    { "winmm", WinMMBackendFactory::getFactory },
#endif
#ifdef HAVE_PORTAUDIO
    { "port", PortBackendFactory::getFactory },
#endif
#ifdef HAVE_SDL2
    { "sdl2", SDL2BackendFactory::getFactory },
#endif

    { "null", NullBackendFactory::getFactory },
#ifdef HAVE_WAVE
    { "wave", WaveBackendFactory::getFactory },
#endif
};

BackendFactory *PlaybackFactory{};
BackendFactory *CaptureFactory{};


/************************************************
 * Functions, enums, and errors
 ************************************************/
#define DECL(x) { #x, reinterpret_cast<void*>(x) }
const struct {
    const char *funcName;
    void *address;
} alcFunctions[] = {
    DECL(alcCreateContext),
    DECL(alcMakeContextCurrent),
    DECL(alcProcessContext),
    DECL(alcSuspendContext),
    DECL(alcDestroyContext),
    DECL(alcGetCurrentContext),
    DECL(alcGetContextsDevice),
    DECL(alcOpenDevice),
    DECL(alcCloseDevice),
    DECL(alcGetError),
    DECL(alcIsExtensionPresent),
    DECL(alcGetProcAddress),
    DECL(alcGetEnumValue),
    DECL(alcGetString),
    DECL(alcGetIntegerv),
    DECL(alcCaptureOpenDevice),
    DECL(alcCaptureCloseDevice),
    DECL(alcCaptureStart),
    DECL(alcCaptureStop),
    DECL(alcCaptureSamples),

    DECL(alcSetThreadContext),
    DECL(alcGetThreadContext),

    DECL(alcLoopbackOpenDeviceSOFT),
    DECL(alcIsRenderFormatSupportedSOFT),
    DECL(alcRenderSamplesSOFT),

    DECL(alcDevicePauseSOFT),
    DECL(alcDeviceResumeSOFT),

    DECL(alcGetStringiSOFT),
    DECL(alcResetDeviceSOFT),

    DECL(alcGetInteger64vSOFT),

    DECL(alEnable),
    DECL(alDisable),
    DECL(alIsEnabled),
    DECL(alGetString),
    DECL(alGetBooleanv),
    DECL(alGetIntegerv),
    DECL(alGetFloatv),
    DECL(alGetDoublev),
    DECL(alGetBoolean),
    DECL(alGetInteger),
    DECL(alGetFloat),
    DECL(alGetDouble),
    DECL(alGetError),
    DECL(alIsExtensionPresent),
    DECL(alGetProcAddress),
    DECL(alGetEnumValue),
    DECL(alListenerf),
    DECL(alListener3f),
    DECL(alListenerfv),
    DECL(alListeneri),
    DECL(alListener3i),
    DECL(alListeneriv),
    DECL(alGetListenerf),
    DECL(alGetListener3f),
    DECL(alGetListenerfv),
    DECL(alGetListeneri),
    DECL(alGetListener3i),
    DECL(alGetListeneriv),
    DECL(alGenSources),
    DECL(alDeleteSources),
    DECL(alIsSource),
    DECL(alSourcef),
    DECL(alSource3f),
    DECL(alSourcefv),
    DECL(alSourcei),
    DECL(alSource3i),
    DECL(alSourceiv),
    DECL(alGetSourcef),
    DECL(alGetSource3f),
    DECL(alGetSourcefv),
    DECL(alGetSourcei),
    DECL(alGetSource3i),
    DECL(alGetSourceiv),
    DECL(alSourcePlayv),
    DECL(alSourceStopv),
    DECL(alSourceRewindv),
    DECL(alSourcePausev),
    DECL(alSourcePlay),
    DECL(alSourceStop),
    DECL(alSourceRewind),
    DECL(alSourcePause),
    DECL(alSourceQueueBuffers),
    DECL(alSourceUnqueueBuffers),
    DECL(alGenBuffers),
    DECL(alDeleteBuffers),
    DECL(alIsBuffer),
    DECL(alBufferData),
    DECL(alBufferf),
    DECL(alBuffer3f),
    DECL(alBufferfv),
    DECL(alBufferi),
    DECL(alBuffer3i),
    DECL(alBufferiv),
    DECL(alGetBufferf),
    DECL(alGetBuffer3f),
    DECL(alGetBufferfv),
    DECL(alGetBufferi),
    DECL(alGetBuffer3i),
    DECL(alGetBufferiv),
    DECL(alDopplerFactor),
    DECL(alDopplerVelocity),
    DECL(alSpeedOfSound),
    DECL(alDistanceModel),

    DECL(alGenFilters),
    DECL(alDeleteFilters),
    DECL(alIsFilter),
    DECL(alFilteri),
    DECL(alFilteriv),
    DECL(alFilterf),
    DECL(alFilterfv),
    DECL(alGetFilteri),
    DECL(alGetFilteriv),
    DECL(alGetFilterf),
    DECL(alGetFilterfv),
    DECL(alGenEffects),
    DECL(alDeleteEffects),
    DECL(alIsEffect),
    DECL(alEffecti),
    DECL(alEffectiv),
    DECL(alEffectf),
    DECL(alEffectfv),
    DECL(alGetEffecti),
    DECL(alGetEffectiv),
    DECL(alGetEffectf),
    DECL(alGetEffectfv),
    DECL(alGenAuxiliaryEffectSlots),
    DECL(alDeleteAuxiliaryEffectSlots),
    DECL(alIsAuxiliaryEffectSlot),
    DECL(alAuxiliaryEffectSloti),
    DECL(alAuxiliaryEffectSlotiv),
    DECL(alAuxiliaryEffectSlotf),
    DECL(alAuxiliaryEffectSlotfv),
    DECL(alGetAuxiliaryEffectSloti),
    DECL(alGetAuxiliaryEffectSlotiv),
    DECL(alGetAuxiliaryEffectSlotf),
    DECL(alGetAuxiliaryEffectSlotfv),

    DECL(alDeferUpdatesSOFT),
    DECL(alProcessUpdatesSOFT),

    DECL(alSourcedSOFT),
    DECL(alSource3dSOFT),
    DECL(alSourcedvSOFT),
    DECL(alGetSourcedSOFT),
    DECL(alGetSource3dSOFT),
    DECL(alGetSourcedvSOFT),
    DECL(alSourcei64SOFT),
    DECL(alSource3i64SOFT),
    DECL(alSourcei64vSOFT),
    DECL(alGetSourcei64SOFT),
    DECL(alGetSource3i64SOFT),
    DECL(alGetSourcei64vSOFT),

    DECL(alGetStringiSOFT),

    DECL(alBufferStorageSOFT),
    DECL(alMapBufferSOFT),
    DECL(alUnmapBufferSOFT),
    DECL(alFlushMappedBufferSOFT),

    DECL(alEventControlSOFT),
    DECL(alEventCallbackSOFT),
    DECL(alGetPointerSOFT),
    DECL(alGetPointervSOFT),

    DECL(alBufferCallbackSOFT),
    DECL(alGetBufferPtrSOFT),
    DECL(alGetBuffer3PtrSOFT),
    DECL(alGetBufferPtrvSOFT),

    DECL(alAuxiliaryEffectSlotPlaySOFT),
    DECL(alAuxiliaryEffectSlotPlayvSOFT),
    DECL(alAuxiliaryEffectSlotStopSOFT),
    DECL(alAuxiliaryEffectSlotStopvSOFT),
};
#undef DECL

#define DECL(x) { #x, (x) }
constexpr struct {
    const ALCchar *enumName;
    ALCenum value;
} alcEnumerations[] = {
    DECL(ALC_INVALID),
    DECL(ALC_FALSE),
    DECL(ALC_TRUE),

    DECL(ALC_MAJOR_VERSION),
    DECL(ALC_MINOR_VERSION),
    DECL(ALC_ATTRIBUTES_SIZE),
    DECL(ALC_ALL_ATTRIBUTES),
    DECL(ALC_DEFAULT_DEVICE_SPECIFIER),
    DECL(ALC_DEVICE_SPECIFIER),
    DECL(ALC_ALL_DEVICES_SPECIFIER),
    DECL(ALC_DEFAULT_ALL_DEVICES_SPECIFIER),
    DECL(ALC_EXTENSIONS),
    DECL(ALC_FREQUENCY),
    DECL(ALC_REFRESH),
    DECL(ALC_SYNC),
    DECL(ALC_MONO_SOURCES),
    DECL(ALC_STEREO_SOURCES),
    DECL(ALC_CAPTURE_DEVICE_SPECIFIER),
    DECL(ALC_CAPTURE_DEFAULT_DEVICE_SPECIFIER),
    DECL(ALC_CAPTURE_SAMPLES),
    DECL(ALC_CONNECTED),

    DECL(ALC_EFX_MAJOR_VERSION),
    DECL(ALC_EFX_MINOR_VERSION),
    DECL(ALC_MAX_AUXILIARY_SENDS),

    DECL(ALC_FORMAT_CHANNELS_SOFT),
    DECL(ALC_FORMAT_TYPE_SOFT),

    DECL(ALC_MONO_SOFT),
    DECL(ALC_STEREO_SOFT),
    DECL(ALC_QUAD_SOFT),
    DECL(ALC_5POINT1_SOFT),
    DECL(ALC_6POINT1_SOFT),
    DECL(ALC_7POINT1_SOFT),
    DECL(ALC_BFORMAT3D_SOFT),

    DECL(ALC_BYTE_SOFT),
    DECL(ALC_UNSIGNED_BYTE_SOFT),
    DECL(ALC_SHORT_SOFT),
    DECL(ALC_UNSIGNED_SHORT_SOFT),
    DECL(ALC_INT_SOFT),
    DECL(ALC_UNSIGNED_INT_SOFT),
    DECL(ALC_FLOAT_SOFT),

    DECL(ALC_HRTF_SOFT),
    DECL(ALC_DONT_CARE_SOFT),
    DECL(ALC_HRTF_STATUS_SOFT),
    DECL(ALC_HRTF_DISABLED_SOFT),
    DECL(ALC_HRTF_ENABLED_SOFT),
    DECL(ALC_HRTF_DENIED_SOFT),
    DECL(ALC_HRTF_REQUIRED_SOFT),
    DECL(ALC_HRTF_HEADPHONES_DETECTED_SOFT),
    DECL(ALC_HRTF_UNSUPPORTED_FORMAT_SOFT),
    DECL(ALC_NUM_HRTF_SPECIFIERS_SOFT),
    DECL(ALC_HRTF_SPECIFIER_SOFT),
    DECL(ALC_HRTF_ID_SOFT),

    DECL(ALC_AMBISONIC_LAYOUT_SOFT),
    DECL(ALC_AMBISONIC_SCALING_SOFT),
    DECL(ALC_AMBISONIC_ORDER_SOFT),
    DECL(ALC_ACN_SOFT),
    DECL(ALC_FUMA_SOFT),
    DECL(ALC_N3D_SOFT),
    DECL(ALC_SN3D_SOFT),

    DECL(ALC_OUTPUT_LIMITER_SOFT),

    DECL(ALC_NO_ERROR),
    DECL(ALC_INVALID_DEVICE),
    DECL(ALC_INVALID_CONTEXT),
    DECL(ALC_INVALID_ENUM),
    DECL(ALC_INVALID_VALUE),
    DECL(ALC_OUT_OF_MEMORY),


    DECL(AL_INVALID),
    DECL(AL_NONE),
    DECL(AL_FALSE),
    DECL(AL_TRUE),

    DECL(AL_SOURCE_RELATIVE),
    DECL(AL_CONE_INNER_ANGLE),
    DECL(AL_CONE_OUTER_ANGLE),
    DECL(AL_PITCH),
    DECL(AL_POSITION),
    DECL(AL_DIRECTION),
    DECL(AL_VELOCITY),
    DECL(AL_LOOPING),
    DECL(AL_BUFFER),
    DECL(AL_GAIN),
    DECL(AL_MIN_GAIN),
    DECL(AL_MAX_GAIN),
    DECL(AL_ORIENTATION),
    DECL(AL_REFERENCE_DISTANCE),
    DECL(AL_ROLLOFF_FACTOR),
    DECL(AL_CONE_OUTER_GAIN),
    DECL(AL_MAX_DISTANCE),
    DECL(AL_SEC_OFFSET),
    DECL(AL_SAMPLE_OFFSET),
    DECL(AL_BYTE_OFFSET),
    DECL(AL_SOURCE_TYPE),
    DECL(AL_STATIC),
    DECL(AL_STREAMING),
    DECL(AL_UNDETERMINED),
    DECL(AL_METERS_PER_UNIT),
    DECL(AL_LOOP_POINTS_SOFT),
    DECL(AL_DIRECT_CHANNELS_SOFT),

    DECL(AL_DIRECT_FILTER),
    DECL(AL_AUXILIARY_SEND_FILTER),
    DECL(AL_AIR_ABSORPTION_FACTOR),
    DECL(AL_ROOM_ROLLOFF_FACTOR),
    DECL(AL_CONE_OUTER_GAINHF),
    DECL(AL_DIRECT_FILTER_GAINHF_AUTO),
    DECL(AL_AUXILIARY_SEND_FILTER_GAIN_AUTO),
    DECL(AL_AUXILIARY_SEND_FILTER_GAINHF_AUTO),

    DECL(AL_SOURCE_STATE),
    DECL(AL_INITIAL),
    DECL(AL_PLAYING),
    DECL(AL_PAUSED),
    DECL(AL_STOPPED),

    DECL(AL_BUFFERS_QUEUED),
    DECL(AL_BUFFERS_PROCESSED),

    DECL(AL_FORMAT_MONO8),
    DECL(AL_FORMAT_MONO16),
    DECL(AL_FORMAT_MONO_FLOAT32),
    DECL(AL_FORMAT_MONO_DOUBLE_EXT),
    DECL(AL_FORMAT_STEREO8),
    DECL(AL_FORMAT_STEREO16),
    DECL(AL_FORMAT_STEREO_FLOAT32),
    DECL(AL_FORMAT_STEREO_DOUBLE_EXT),
    DECL(AL_FORMAT_MONO_IMA4),
    DECL(AL_FORMAT_STEREO_IMA4),
    DECL(AL_FORMAT_MONO_MSADPCM_SOFT),
    DECL(AL_FORMAT_STEREO_MSADPCM_SOFT),
    DECL(AL_FORMAT_QUAD8_LOKI),
    DECL(AL_FORMAT_QUAD16_LOKI),
    DECL(AL_FORMAT_QUAD8),
    DECL(AL_FORMAT_QUAD16),
    DECL(AL_FORMAT_QUAD32),
    DECL(AL_FORMAT_51CHN8),
    DECL(AL_FORMAT_51CHN16),
    DECL(AL_FORMAT_51CHN32),
    DECL(AL_FORMAT_61CHN8),
    DECL(AL_FORMAT_61CHN16),
    DECL(AL_FORMAT_61CHN32),
    DECL(AL_FORMAT_71CHN8),
    DECL(AL_FORMAT_71CHN16),
    DECL(AL_FORMAT_71CHN32),
    DECL(AL_FORMAT_REAR8),
    DECL(AL_FORMAT_REAR16),
    DECL(AL_FORMAT_REAR32),
    DECL(AL_FORMAT_MONO_MULAW),
    DECL(AL_FORMAT_MONO_MULAW_EXT),
    DECL(AL_FORMAT_STEREO_MULAW),
    DECL(AL_FORMAT_STEREO_MULAW_EXT),
    DECL(AL_FORMAT_QUAD_MULAW),
    DECL(AL_FORMAT_51CHN_MULAW),
    DECL(AL_FORMAT_61CHN_MULAW),
    DECL(AL_FORMAT_71CHN_MULAW),
    DECL(AL_FORMAT_REAR_MULAW),
    DECL(AL_FORMAT_MONO_ALAW_EXT),
    DECL(AL_FORMAT_STEREO_ALAW_EXT),

    DECL(AL_FORMAT_BFORMAT2D_8),
    DECL(AL_FORMAT_BFORMAT2D_16),
    DECL(AL_FORMAT_BFORMAT2D_FLOAT32),
    DECL(AL_FORMAT_BFORMAT2D_MULAW),
    DECL(AL_FORMAT_BFORMAT3D_8),
    DECL(AL_FORMAT_BFORMAT3D_16),
    DECL(AL_FORMAT_BFORMAT3D_FLOAT32),
    DECL(AL_FORMAT_BFORMAT3D_MULAW),

    DECL(AL_FREQUENCY),
    DECL(AL_BITS),
    DECL(AL_CHANNELS),
    DECL(AL_SIZE),
    DECL(AL_UNPACK_BLOCK_ALIGNMENT_SOFT),
    DECL(AL_PACK_BLOCK_ALIGNMENT_SOFT),

    DECL(AL_SOURCE_RADIUS),

    DECL(AL_STEREO_ANGLES),

    DECL(AL_UNUSED),
    DECL(AL_PENDING),
    DECL(AL_PROCESSED),

    DECL(AL_NO_ERROR),
    DECL(AL_INVALID_NAME),
    DECL(AL_INVALID_ENUM),
    DECL(AL_INVALID_VALUE),
    DECL(AL_INVALID_OPERATION),
    DECL(AL_OUT_OF_MEMORY),

    DECL(AL_VENDOR),
    DECL(AL_VERSION),
    DECL(AL_RENDERER),
    DECL(AL_EXTENSIONS),

    DECL(AL_DOPPLER_FACTOR),
    DECL(AL_DOPPLER_VELOCITY),
    DECL(AL_DISTANCE_MODEL),
    DECL(AL_SPEED_OF_SOUND),
    DECL(AL_SOURCE_DISTANCE_MODEL),
    DECL(AL_DEFERRED_UPDATES_SOFT),
    DECL(AL_GAIN_LIMIT_SOFT),

    DECL(AL_INVERSE_DISTANCE),
    DECL(AL_INVERSE_DISTANCE_CLAMPED),
    DECL(AL_LINEAR_DISTANCE),
    DECL(AL_LINEAR_DISTANCE_CLAMPED),
    DECL(AL_EXPONENT_DISTANCE),
    DECL(AL_EXPONENT_DISTANCE_CLAMPED),

    DECL(AL_FILTER_TYPE),
    DECL(AL_FILTER_NULL),
    DECL(AL_FILTER_LOWPASS),
    DECL(AL_FILTER_HIGHPASS),
    DECL(AL_FILTER_BANDPASS),

    DECL(AL_LOWPASS_GAIN),
    DECL(AL_LOWPASS_GAINHF),

    DECL(AL_HIGHPASS_GAIN),
    DECL(AL_HIGHPASS_GAINLF),

    DECL(AL_BANDPASS_GAIN),
    DECL(AL_BANDPASS_GAINHF),
    DECL(AL_BANDPASS_GAINLF),

    DECL(AL_EFFECT_TYPE),
    DECL(AL_EFFECT_NULL),
    DECL(AL_EFFECT_REVERB),
    DECL(AL_EFFECT_EAXREVERB),
    DECL(AL_EFFECT_CHORUS),
    DECL(AL_EFFECT_DISTORTION),
    DECL(AL_EFFECT_ECHO),
    DECL(AL_EFFECT_FLANGER),
    DECL(AL_EFFECT_PITCH_SHIFTER),
    DECL(AL_EFFECT_FREQUENCY_SHIFTER),
    DECL(AL_EFFECT_VOCAL_MORPHER),
    DECL(AL_EFFECT_RING_MODULATOR),
    DECL(AL_EFFECT_AUTOWAH),
    DECL(AL_EFFECT_COMPRESSOR),
    DECL(AL_EFFECT_EQUALIZER),
    DECL(AL_EFFECT_DEDICATED_LOW_FREQUENCY_EFFECT),
    DECL(AL_EFFECT_DEDICATED_DIALOGUE),

    DECL(AL_EFFECTSLOT_EFFECT),
    DECL(AL_EFFECTSLOT_GAIN),
    DECL(AL_EFFECTSLOT_AUXILIARY_SEND_AUTO),
    DECL(AL_EFFECTSLOT_NULL),

    DECL(AL_EAXREVERB_DENSITY),
    DECL(AL_EAXREVERB_DIFFUSION),
    DECL(AL_EAXREVERB_GAIN),
    DECL(AL_EAXREVERB_GAINHF),
    DECL(AL_EAXREVERB_GAINLF),
    DECL(AL_EAXREVERB_DECAY_TIME),
    DECL(AL_EAXREVERB_DECAY_HFRATIO),
    DECL(AL_EAXREVERB_DECAY_LFRATIO),
    DECL(AL_EAXREVERB_REFLECTIONS_GAIN),
    DECL(AL_EAXREVERB_REFLECTIONS_DELAY),
    DECL(AL_EAXREVERB_REFLECTIONS_PAN),
    DECL(AL_EAXREVERB_LATE_REVERB_GAIN),
    DECL(AL_EAXREVERB_LATE_REVERB_DELAY),
    DECL(AL_EAXREVERB_LATE_REVERB_PAN),
    DECL(AL_EAXREVERB_ECHO_TIME),
    DECL(AL_EAXREVERB_ECHO_DEPTH),
    DECL(AL_EAXREVERB_MODULATION_TIME),
    DECL(AL_EAXREVERB_MODULATION_DEPTH),
    DECL(AL_EAXREVERB_AIR_ABSORPTION_GAINHF),
    DECL(AL_EAXREVERB_HFREFERENCE),
    DECL(AL_EAXREVERB_LFREFERENCE),
    DECL(AL_EAXREVERB_ROOM_ROLLOFF_FACTOR),
    DECL(AL_EAXREVERB_DECAY_HFLIMIT),

    DECL(AL_REVERB_DENSITY),
    DECL(AL_REVERB_DIFFUSION),
    DECL(AL_REVERB_GAIN),
    DECL(AL_REVERB_GAINHF),
    DECL(AL_REVERB_DECAY_TIME),
    DECL(AL_REVERB_DECAY_HFRATIO),
    DECL(AL_REVERB_REFLECTIONS_GAIN),
    DECL(AL_REVERB_REFLECTIONS_DELAY),
    DECL(AL_REVERB_LATE_REVERB_GAIN),
    DECL(AL_REVERB_LATE_REVERB_DELAY),
    DECL(AL_REVERB_AIR_ABSORPTION_GAINHF),
    DECL(AL_REVERB_ROOM_ROLLOFF_FACTOR),
    DECL(AL_REVERB_DECAY_HFLIMIT),

    DECL(AL_CHORUS_WAVEFORM),
    DECL(AL_CHORUS_PHASE),
    DECL(AL_CHORUS_RATE),
    DECL(AL_CHORUS_DEPTH),
    DECL(AL_CHORUS_FEEDBACK),
    DECL(AL_CHORUS_DELAY),

    DECL(AL_DISTORTION_EDGE),
    DECL(AL_DISTORTION_GAIN),
    DECL(AL_DISTORTION_LOWPASS_CUTOFF),
    DECL(AL_DISTORTION_EQCENTER),
    DECL(AL_DISTORTION_EQBANDWIDTH),

    DECL(AL_ECHO_DELAY),
    DECL(AL_ECHO_LRDELAY),
    DECL(AL_ECHO_DAMPING),
    DECL(AL_ECHO_FEEDBACK),
    DECL(AL_ECHO_SPREAD),

    DECL(AL_FLANGER_WAVEFORM),
    DECL(AL_FLANGER_PHASE),
    DECL(AL_FLANGER_RATE),
    DECL(AL_FLANGER_DEPTH),
    DECL(AL_FLANGER_FEEDBACK),
    DECL(AL_FLANGER_DELAY),

    DECL(AL_FREQUENCY_SHIFTER_FREQUENCY),
    DECL(AL_FREQUENCY_SHIFTER_LEFT_DIRECTION),
    DECL(AL_FREQUENCY_SHIFTER_RIGHT_DIRECTION),

    DECL(AL_RING_MODULATOR_FREQUENCY),
    DECL(AL_RING_MODULATOR_HIGHPASS_CUTOFF),
    DECL(AL_RING_MODULATOR_WAVEFORM),

    DECL(AL_PITCH_SHIFTER_COARSE_TUNE),
    DECL(AL_PITCH_SHIFTER_FINE_TUNE),

    DECL(AL_COMPRESSOR_ONOFF),

    DECL(AL_EQUALIZER_LOW_GAIN),
    DECL(AL_EQUALIZER_LOW_CUTOFF),
    DECL(AL_EQUALIZER_MID1_GAIN),
    DECL(AL_EQUALIZER_MID1_CENTER),
    DECL(AL_EQUALIZER_MID1_WIDTH),
    DECL(AL_EQUALIZER_MID2_GAIN),
    DECL(AL_EQUALIZER_MID2_CENTER),
    DECL(AL_EQUALIZER_MID2_WIDTH),
    DECL(AL_EQUALIZER_HIGH_GAIN),
    DECL(AL_EQUALIZER_HIGH_CUTOFF),

    DECL(AL_DEDICATED_GAIN),

    DECL(AL_AUTOWAH_ATTACK_TIME),
    DECL(AL_AUTOWAH_RELEASE_TIME),
    DECL(AL_AUTOWAH_RESONANCE),
    DECL(AL_AUTOWAH_PEAK_GAIN),

    DECL(AL_VOCAL_MORPHER_PHONEMEA),
    DECL(AL_VOCAL_MORPHER_PHONEMEB_COARSE_TUNING),
    DECL(AL_VOCAL_MORPHER_PHONEMEB),
    DECL(AL_VOCAL_MORPHER_PHONEMEB_COARSE_TUNING),
    DECL(AL_VOCAL_MORPHER_WAVEFORM),
    DECL(AL_VOCAL_MORPHER_RATE),

    DECL(AL_EFFECTSLOT_TARGET_SOFT),

    DECL(AL_NUM_RESAMPLERS_SOFT),
    DECL(AL_DEFAULT_RESAMPLER_SOFT),
    DECL(AL_SOURCE_RESAMPLER_SOFT),
    DECL(AL_RESAMPLER_NAME_SOFT),

    DECL(AL_SOURCE_SPATIALIZE_SOFT),
    DECL(AL_AUTO_SOFT),

    DECL(AL_MAP_READ_BIT_SOFT),
    DECL(AL_MAP_WRITE_BIT_SOFT),
    DECL(AL_MAP_PERSISTENT_BIT_SOFT),
    DECL(AL_PRESERVE_DATA_BIT_SOFT),

    DECL(AL_EVENT_CALLBACK_FUNCTION_SOFT),
    DECL(AL_EVENT_CALLBACK_USER_PARAM_SOFT),
    DECL(AL_EVENT_TYPE_BUFFER_COMPLETED_SOFT),
    DECL(AL_EVENT_TYPE_SOURCE_STATE_CHANGED_SOFT),
    DECL(AL_EVENT_TYPE_DISCONNECTED_SOFT),

    DECL(AL_DROP_UNMATCHED_SOFT),
    DECL(AL_REMIX_UNMATCHED_SOFT),

    DECL(AL_AMBISONIC_LAYOUT_SOFT),
    DECL(AL_AMBISONIC_SCALING_SOFT),
    DECL(AL_FUMA_SOFT),
    DECL(AL_ACN_SOFT),
    DECL(AL_SN3D_SOFT),
    DECL(AL_N3D_SOFT),

    DECL(AL_BUFFER_CALLBACK_FUNCTION_SOFT),
    DECL(AL_BUFFER_CALLBACK_USER_PARAM_SOFT),

    DECL(AL_UNPACK_AMBISONIC_ORDER_SOFT),

    DECL(AL_EFFECT_CONVOLUTION_REVERB_SOFT),
    DECL(AL_EFFECTSLOT_STATE_SOFT),
};
#undef DECL

constexpr ALCchar alcNoError[] = "No Error";
constexpr ALCchar alcErrInvalidDevice[] = "Invalid Device";
constexpr ALCchar alcErrInvalidContext[] = "Invalid Context";
constexpr ALCchar alcErrInvalidEnum[] = "Invalid Enum";
constexpr ALCchar alcErrInvalidValue[] = "Invalid Value";
constexpr ALCchar alcErrOutOfMemory[] = "Out of Memory";


/************************************************
 * Global variables
 ************************************************/

/* Enumerated device names */
constexpr ALCchar alcDefaultName[] = "OpenAL Soft\0";

std::string alcAllDevicesList;
std::string alcCaptureDeviceList;

/* Default is always the first in the list */
al::string alcDefaultAllDevicesSpecifier;
al::string alcCaptureDefaultDeviceSpecifier;

/* Default context extensions */
constexpr ALchar alExtList[] =
    "AL_EXT_ALAW "
    "AL_EXT_BFORMAT "
    "AL_EXT_DOUBLE "
    "AL_EXT_EXPONENT_DISTANCE "
    "AL_EXT_FLOAT32 "
    "AL_EXT_IMA4 "
    "AL_EXT_LINEAR_DISTANCE "
    "AL_EXT_MCFORMATS "
    "AL_EXT_MULAW "
    "AL_EXT_MULAW_BFORMAT "
    "AL_EXT_MULAW_MCFORMATS "
    "AL_EXT_OFFSET "
    "AL_EXT_source_distance_model "
    "AL_EXT_SOURCE_RADIUS "
    "AL_EXT_STEREO_ANGLES "
    "AL_LOKI_quadriphonic "
    "AL_SOFT_bformat_ex "
    "AL_SOFTX_bformat_hoa "
    "AL_SOFT_block_alignment "
    "AL_SOFTX_callback_buffer "
    "AL_SOFTX_convolution_reverb "
    "AL_SOFT_deferred_updates "
    "AL_SOFT_direct_channels "
    "AL_SOFT_direct_channels_remix "
    "AL_SOFT_effect_target "
    "AL_SOFT_events "
    "AL_SOFTX_filter_gain_ex "
    "AL_SOFT_gain_clamp_ex "
    "AL_SOFT_loop_points "
    "AL_SOFTX_map_buffer "
    "AL_SOFT_MSADPCM "
    "AL_SOFT_source_latency "
    "AL_SOFT_source_length "
    "AL_SOFT_source_resampler "
    "AL_SOFT_source_spatialize";

std::atomic<ALCenum> LastNullDeviceError{ALC_NO_ERROR};

/* Thread-local current context. The handling may look a little obtuse, but
 * it's designed this way to avoid a bug with 32-bit GCC/MinGW, which causes
 * thread-local object destructors to get a junk 'this' pointer. This method
 * has the benefit of making LocalContext access more efficient since it's a
 * a plain pointer, with the ThreadContext object used to check it at thread
 * exit (and given no data fields, 'this' being junk is inconsequential since
 * it's never accessed).
 */
thread_local ALCcontext *LocalContext{nullptr};
class ThreadCtx {
public:
    ~ThreadCtx()
    {
        if(ALCcontext *ctx{LocalContext})
        {
            const bool result{ctx->releaseIfNoDelete()};
            ERR("Context %p current for thread being destroyed%s!\n",
                decltype(std::declval<void*>()){ctx}, result ? "" : ", leak detected");
        }
    }

    void set(ALCcontext *ctx) const noexcept { LocalContext = ctx; }
};
thread_local ThreadCtx ThreadContext;

/* Process-wide current context */
std::atomic<ALCcontext*> GlobalContext{nullptr};

/* Flag to trap ALC device errors */
bool TrapALCError{false};

/* One-time configuration init control */
std::once_flag alc_config_once{};

/* Default effect that applies to sources that don't have an effect on send 0 */
ALeffect DefaultEffect;

/* Flag to specify if alcSuspendContext/alcProcessContext should defer/process
 * updates.
 */
bool SuspendDefers{true};

/* Initial seed for dithering. */
constexpr ALuint DitherRNGSeed{22222u};


/************************************************
 * ALC information
 ************************************************/
constexpr ALCchar alcNoDeviceExtList[] =
    "ALC_ENUMERATE_ALL_EXT "
    "ALC_ENUMERATION_EXT "
    "ALC_EXT_CAPTURE "
    "ALC_EXT_thread_local_context "
    "ALC_SOFT_loopback "
    "ALC_SOFT_loopback_bformat";
constexpr ALCchar alcExtensionList[] =
    "ALC_ENUMERATE_ALL_EXT "
    "ALC_ENUMERATION_EXT "
    "ALC_EXT_CAPTURE "
    "ALC_EXT_DEDICATED "
    "ALC_EXT_disconnect "
    "ALC_EXT_EFX "
    "ALC_EXT_thread_local_context "
    "ALC_SOFT_device_clock "
    "ALC_SOFT_HRTF "
    "ALC_SOFT_loopback "
    "ALC_SOFT_loopback_bformat "
    "ALC_SOFT_output_limiter "
    "ALC_SOFT_pause_device";
constexpr int alcMajorVersion{1};
constexpr int alcMinorVersion{1};

constexpr int alcEFXMajorVersion{1};
constexpr int alcEFXMinorVersion{0};


/* To avoid extraneous allocations, a 0-sized FlexArray<ALCcontext*> is defined
 * globally as a sharable object.
 */
al::FlexArray<ALCcontext*> EmptyContextArray{0u};


using DeviceRef = al::intrusive_ptr<ALCdevice>;


/************************************************
 * Device lists
 ************************************************/
al::vector<ALCdevice*> DeviceList;
al::vector<ALCcontext*> ContextList;

std::recursive_mutex ListLock;


void alc_initconfig(void)
{
    if(auto loglevel = al::getenv("ALSOFT_LOGLEVEL"))
    {
        long lvl = strtol(loglevel->c_str(), nullptr, 0);
        if(lvl >= static_cast<long>(LogLevel::Trace))
            gLogLevel = LogLevel::Trace;
        else if(lvl <= static_cast<long>(LogLevel::Disable))
            gLogLevel = LogLevel::Disable;
        else
            gLogLevel = static_cast<LogLevel>(lvl);
    }

#ifdef _WIN32
    if(const auto logfile = al::getenv(L"ALSOFT_LOGFILE"))
    {
        FILE *logf{_wfopen(logfile->c_str(), L"wt")};
        if(logf) gLogFile = logf;
        else
        {
            auto u8name = wstr_to_utf8(logfile->c_str());
            ERR("Failed to open log file '%s'\n", u8name.c_str());
        }
    }
#else
    if(const auto logfile = al::getenv("ALSOFT_LOGFILE"))
    {
        FILE *logf{fopen(logfile->c_str(), "wt")};
        if(logf) gLogFile = logf;
        else ERR("Failed to open log file '%s'\n", logfile->c_str());
    }
#endif

    TRACE("Initializing library v%s-%s %s\n", ALSOFT_VERSION, ALSOFT_GIT_COMMIT_HASH,
        ALSOFT_GIT_BRANCH);
    {
        al::string names;
        if(al::size(BackendList) < 1)
            names = "(none)";
        else
        {
            const al::span<const BackendInfo> infos{BackendList};
            names = infos[0].name;
            for(const auto &backend : infos.subspan<1>())
            {
                names += ", ";
                names += backend.name;
            }
        }
        TRACE("Supported backends: %s\n", names.c_str());
    }
    ReadALConfig();

    if(auto suspendmode = al::getenv("__ALSOFT_SUSPEND_CONTEXT"))
    {
        if(al::strcasecmp(suspendmode->c_str(), "ignore") == 0)
        {
            SuspendDefers = false;
            TRACE("Selected context suspend behavior, \"ignore\"\n");
        }
        else
            ERR("Unhandled context suspend behavior setting: \"%s\"\n", suspendmode->c_str());
    }

    int capfilter{0};
#if defined(HAVE_SSE4_1)
    capfilter |= CPU_CAP_SSE | CPU_CAP_SSE2 | CPU_CAP_SSE3 | CPU_CAP_SSE4_1;
#elif defined(HAVE_SSE3)
    capfilter |= CPU_CAP_SSE | CPU_CAP_SSE2 | CPU_CAP_SSE3;
#elif defined(HAVE_SSE2)
    capfilter |= CPU_CAP_SSE | CPU_CAP_SSE2;
#elif defined(HAVE_SSE)
    capfilter |= CPU_CAP_SSE;
#endif
#ifdef HAVE_NEON
    capfilter |= CPU_CAP_NEON;
#endif
    if(auto cpuopt = ConfigValueStr(nullptr, nullptr, "disable-cpu-exts"))
    {
        const char *str{cpuopt->c_str()};
        if(al::strcasecmp(str, "all") == 0)
            capfilter = 0;
        else
        {
            const char *next = str;
            do {
                str = next;
                while(isspace(str[0]))
                    str++;
                next = strchr(str, ',');

                if(!str[0] || str[0] == ',')
                    continue;

                size_t len{next ? static_cast<size_t>(next-str) : strlen(str)};
                while(len > 0 && isspace(str[len-1]))
                    len--;
                if(len == 3 && al::strncasecmp(str, "sse", len) == 0)
                    capfilter &= ~CPU_CAP_SSE;
                else if(len == 4 && al::strncasecmp(str, "sse2", len) == 0)
                    capfilter &= ~CPU_CAP_SSE2;
                else if(len == 4 && al::strncasecmp(str, "sse3", len) == 0)
                    capfilter &= ~CPU_CAP_SSE3;
                else if(len == 6 && al::strncasecmp(str, "sse4.1", len) == 0)
                    capfilter &= ~CPU_CAP_SSE4_1;
                else if(len == 4 && al::strncasecmp(str, "neon", len) == 0)
                    capfilter &= ~CPU_CAP_NEON;
                else
                    WARN("Invalid CPU extension \"%s\"\n", str);
            } while(next++);
        }
    }
    FillCPUCaps(capfilter);

    if(auto priopt = ConfigValueInt(nullptr, nullptr, "rt-prio"))
        RTPrioLevel = *priopt;

    aluInit();
    aluInitMixer();

    auto traperr = al::getenv("ALSOFT_TRAP_ERROR");
    if(traperr && (al::strcasecmp(traperr->c_str(), "true") == 0
            || std::strtol(traperr->c_str(), nullptr, 0) == 1))
    {
        TrapALError  = true;
        TrapALCError = true;
    }
    else
    {
        traperr = al::getenv("ALSOFT_TRAP_AL_ERROR");
        if(traperr)
            TrapALError = al::strcasecmp(traperr->c_str(), "true") == 0
                || strtol(traperr->c_str(), nullptr, 0) == 1;
        else
            TrapALError = !!GetConfigValueBool(nullptr, nullptr, "trap-al-error", false);

        traperr = al::getenv("ALSOFT_TRAP_ALC_ERROR");
        if(traperr)
            TrapALCError = al::strcasecmp(traperr->c_str(), "true") == 0
                || strtol(traperr->c_str(), nullptr, 0) == 1;
        else
            TrapALCError = !!GetConfigValueBool(nullptr, nullptr, "trap-alc-error", false);
    }

    if(auto boostopt = ConfigValueFloat(nullptr, "reverb", "boost"))
    {
        const float valf{std::isfinite(*boostopt) ? clampf(*boostopt, -24.0f, 24.0f) : 0.0f};
        ReverbBoost *= std::pow(10.0f, valf / 20.0f);
    }

    auto BackendListEnd = std::end(BackendList);
    auto devopt = al::getenv("ALSOFT_DRIVERS");
    if(devopt || (devopt=ConfigValueStr(nullptr, nullptr, "drivers")))
    {
        auto backendlist_cur = std::begin(BackendList);

        bool endlist{true};
        const char *next{devopt->c_str()};
        do {
            const char *devs{next};
            while(isspace(devs[0]))
                devs++;
            next = strchr(devs, ',');

            const bool delitem{devs[0] == '-'};
            if(devs[0] == '-') devs++;

            if(!devs[0] || devs[0] == ',')
            {
                endlist = false;
                continue;
            }
            endlist = true;

            size_t len{next ? (static_cast<size_t>(next-devs)) : strlen(devs)};
            while(len > 0 && isspace(devs[len-1])) --len;
#ifdef HAVE_WASAPI
            /* HACK: For backwards compatibility, convert backend references of
             * mmdevapi to wasapi. This should eventually be removed.
             */
            if(len == 8 && strncmp(devs, "mmdevapi", len) == 0)
            {
                devs = "wasapi";
                len = 6;
            }
#endif

            auto find_backend = [devs,len](const BackendInfo &backend) -> bool
            { return len == strlen(backend.name) && strncmp(backend.name, devs, len) == 0; };
            auto this_backend = std::find_if(std::begin(BackendList), BackendListEnd,
                find_backend);

            if(this_backend == BackendListEnd)
                continue;

            if(delitem)
                BackendListEnd = std::move(this_backend+1, BackendListEnd, this_backend);
            else
                backendlist_cur = std::rotate(backendlist_cur, this_backend, this_backend+1);
        } while(next++);

        if(endlist)
            BackendListEnd = backendlist_cur;
    }

    auto init_backend = [](BackendInfo &backend) -> void
    {
        if(PlaybackFactory && CaptureFactory)
            return;

        BackendFactory &factory = backend.getFactory();
        if(!factory.init())
        {
            WARN("Failed to initialize backend \"%s\"\n", backend.name);
            return;
        }

        TRACE("Initialized backend \"%s\"\n", backend.name);
        if(!PlaybackFactory && factory.querySupport(BackendType::Playback))
        {
            PlaybackFactory = &factory;
            TRACE("Added \"%s\" for playback\n", backend.name);
        }
        if(!CaptureFactory && factory.querySupport(BackendType::Capture))
        {
            CaptureFactory = &factory;
            TRACE("Added \"%s\" for capture\n", backend.name);
        }
    };
    std::for_each(std::begin(BackendList), BackendListEnd, init_backend);

    LoopbackBackendFactory::getFactory().init();

    if(!PlaybackFactory)
        WARN("No playback backend available!\n");
    if(!CaptureFactory)
        WARN("No capture backend available!\n");

    if(auto exclopt = ConfigValueStr(nullptr, nullptr, "excludefx"))
    {
        const char *next{exclopt->c_str()};
        do {
            const char *str{next};
            next = strchr(str, ',');

            if(!str[0] || next == str)
                continue;

            size_t len{next ? static_cast<size_t>(next-str) : strlen(str)};
            for(const EffectList &effectitem : gEffectList)
            {
                if(len == strlen(effectitem.name) &&
                   strncmp(effectitem.name, str, len) == 0)
                    DisabledEffects[effectitem.type] = true;
            }
        } while(next++);
    }

    InitEffect(&DefaultEffect);
    auto defrevopt = al::getenv("ALSOFT_DEFAULT_REVERB");
    if(defrevopt || (defrevopt=ConfigValueStr(nullptr, nullptr, "default-reverb")))
        LoadReverbPreset(defrevopt->c_str(), &DefaultEffect);
}
#define DO_INITCONFIG() std::call_once(alc_config_once, [](){alc_initconfig();})


/************************************************
 * Device enumeration
 ************************************************/
void ProbeAllDevicesList()
{
    DO_INITCONFIG();

    std::lock_guard<std::recursive_mutex> _{ListLock};
    if(!PlaybackFactory)
        decltype(alcAllDevicesList){}.swap(alcAllDevicesList);
    else
    {
        std::string names{PlaybackFactory->probe(BackendType::Playback)};
        if(names.empty()) names += '\0';
        names.swap(alcAllDevicesList);
    }
}
void ProbeCaptureDeviceList()
{
    DO_INITCONFIG();

    std::lock_guard<std::recursive_mutex> _{ListLock};
    if(!CaptureFactory)
        decltype(alcCaptureDeviceList){}.swap(alcCaptureDeviceList);
    else
    {
        std::string names{CaptureFactory->probe(BackendType::Capture)};
        if(names.empty()) names += '\0';
        names.swap(alcCaptureDeviceList);
    }
}

} // namespace

/* Mixing thread piority level */
int RTPrioLevel{1};

FILE *gLogFile{stderr};
#ifdef _DEBUG
LogLevel gLogLevel{LogLevel::Warning};
#else
LogLevel gLogLevel{LogLevel::Error};
#endif

/************************************************
 * Library initialization
 ************************************************/
#if defined(_WIN32) && !defined(AL_LIBTYPE_STATIC)
BOOL APIENTRY DllMain(HINSTANCE module, DWORD reason, LPVOID /*reserved*/)
{
    switch(reason)
    {
    case DLL_PROCESS_ATTACH:
        /* Pin the DLL so we won't get unloaded until the process terminates */
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            reinterpret_cast<WCHAR*>(module), &module);
        break;
    }
    return TRUE;
}
#endif

/************************************************
 * Device format information
 ************************************************/
const ALCchar *DevFmtTypeString(DevFmtType type) noexcept
{
    switch(type)
    {
    case DevFmtByte: return "Int8";
    case DevFmtUByte: return "UInt8";
    case DevFmtShort: return "Int16";
    case DevFmtUShort: return "UInt16";
    case DevFmtInt: return "Int32";
    case DevFmtUInt: return "UInt32";
    case DevFmtFloat: return "Float32";
    }
    return "(unknown type)";
}
const ALCchar *DevFmtChannelsString(DevFmtChannels chans) noexcept
{
    switch(chans)
    {
    case DevFmtMono: return "Mono";
    case DevFmtStereo: return "Stereo";
    case DevFmtQuad: return "Quadraphonic";
    case DevFmtX51: return "5.1 Surround";
    case DevFmtX51Rear: return "5.1 Surround (Rear)";
    case DevFmtX61: return "6.1 Surround";
    case DevFmtX71: return "7.1 Surround";
    case DevFmtAmbi3D: return "Ambisonic 3D";
    }
    return "(unknown channels)";
}

ALuint BytesFromDevFmt(DevFmtType type) noexcept
{
    switch(type)
    {
    case DevFmtByte: return sizeof(int8_t);
    case DevFmtUByte: return sizeof(uint8_t);
    case DevFmtShort: return sizeof(int16_t);
    case DevFmtUShort: return sizeof(uint16_t);
    case DevFmtInt: return sizeof(int32_t);
    case DevFmtUInt: return sizeof(uint32_t);
    case DevFmtFloat: return sizeof(float);
    }
    return 0;
}
ALuint ChannelsFromDevFmt(DevFmtChannels chans, ALuint ambiorder) noexcept
{
    switch(chans)
    {
    case DevFmtMono: return 1;
    case DevFmtStereo: return 2;
    case DevFmtQuad: return 4;
    case DevFmtX51: return 6;
    case DevFmtX51Rear: return 6;
    case DevFmtX61: return 7;
    case DevFmtX71: return 8;
    case DevFmtAmbi3D: return (ambiorder+1) * (ambiorder+1);
    }
    return 0;
}

namespace {

struct DevFmtPair { DevFmtChannels chans; DevFmtType type; };
al::optional<DevFmtPair> DecomposeDevFormat(ALenum format)
{
    static const struct {
        ALenum format;
        DevFmtChannels channels;
        DevFmtType type;
    } list[] = {
        { AL_FORMAT_MONO8,        DevFmtMono, DevFmtUByte },
        { AL_FORMAT_MONO16,       DevFmtMono, DevFmtShort },
        { AL_FORMAT_MONO_FLOAT32, DevFmtMono, DevFmtFloat },

        { AL_FORMAT_STEREO8,        DevFmtStereo, DevFmtUByte },
        { AL_FORMAT_STEREO16,       DevFmtStereo, DevFmtShort },
        { AL_FORMAT_STEREO_FLOAT32, DevFmtStereo, DevFmtFloat },

        { AL_FORMAT_QUAD8,  DevFmtQuad, DevFmtUByte },
        { AL_FORMAT_QUAD16, DevFmtQuad, DevFmtShort },
        { AL_FORMAT_QUAD32, DevFmtQuad, DevFmtFloat },

        { AL_FORMAT_51CHN8,  DevFmtX51, DevFmtUByte },
        { AL_FORMAT_51CHN16, DevFmtX51, DevFmtShort },
        { AL_FORMAT_51CHN32, DevFmtX51, DevFmtFloat },

        { AL_FORMAT_61CHN8,  DevFmtX61, DevFmtUByte },
        { AL_FORMAT_61CHN16, DevFmtX61, DevFmtShort },
        { AL_FORMAT_61CHN32, DevFmtX61, DevFmtFloat },

        { AL_FORMAT_71CHN8,  DevFmtX71, DevFmtUByte },
        { AL_FORMAT_71CHN16, DevFmtX71, DevFmtShort },
        { AL_FORMAT_71CHN32, DevFmtX71, DevFmtFloat },
    };

    for(const auto &item : list)
    {
        if(item.format == format)
            return al::make_optional(DevFmtPair{item.channels, item.type});
    }

    return al::nullopt;
}

bool IsValidALCType(ALCenum type)
{
    switch(type)
    {
    case ALC_BYTE_SOFT:
    case ALC_UNSIGNED_BYTE_SOFT:
    case ALC_SHORT_SOFT:
    case ALC_UNSIGNED_SHORT_SOFT:
    case ALC_INT_SOFT:
    case ALC_UNSIGNED_INT_SOFT:
    case ALC_FLOAT_SOFT:
        return true;
    }
    return false;
}

bool IsValidALCChannels(ALCenum channels)
{
    switch(channels)
    {
    case ALC_MONO_SOFT:
    case ALC_STEREO_SOFT:
    case ALC_QUAD_SOFT:
    case ALC_5POINT1_SOFT:
    case ALC_6POINT1_SOFT:
    case ALC_7POINT1_SOFT:
    case ALC_BFORMAT3D_SOFT:
        return true;
    }
    return false;
}

bool IsValidAmbiLayout(ALCenum layout)
{
    switch(layout)
    {
    case ALC_ACN_SOFT:
    case ALC_FUMA_SOFT:
        return true;
    }
    return false;
}

bool IsValidAmbiScaling(ALCenum scaling)
{
    switch(scaling)
    {
    case ALC_N3D_SOFT:
    case ALC_SN3D_SOFT:
    case ALC_FUMA_SOFT:
        return true;
    }
    return false;
}


/* Downmixing channel arrays, to map the given format's missing channels to
 * existing ones. Based on Wine's DSound downmix values, which are based on
 * PulseAudio's.
 */
const std::array<InputRemixMap,7> MonoDownmix{{
    { FrontLeft,   {{{FrontCenter, 0.5f},      {LFE, 0.0f}}} },
    { FrontRight,  {{{FrontCenter, 0.5f},      {LFE, 0.0f}}} },
    { SideLeft,    {{{FrontCenter, 0.5f/9.0f}, {LFE, 0.0f}}} },
    { SideRight,   {{{FrontCenter, 0.5f/9.0f}, {LFE, 0.0f}}} },
    { BackLeft,    {{{FrontCenter, 0.5f/9.0f}, {LFE, 0.0f}}} },
    { BackRight,   {{{FrontCenter, 0.5f/9.0f}, {LFE, 0.0f}}} },
    { BackCenter,  {{{FrontCenter, 1.0f/9.0f}, {LFE, 0.0f}}} },
}};
const std::array<InputRemixMap,6> StereoDownmix{{
    { FrontCenter, {{{FrontLeft, 0.5f},      {FrontRight, 0.5f}}} },
    { SideLeft,    {{{FrontLeft, 1.0f/9.0f}, {FrontRight, 0.0f}}} },
    { SideRight,   {{{FrontLeft, 0.0f},      {FrontRight, 1.0f/9.0f}}} },
    { BackLeft,    {{{FrontLeft, 1.0f/9.0f}, {FrontRight, 0.0f}}} },
    { BackRight,   {{{FrontLeft, 0.0f},      {FrontRight, 1.0f/9.0f}}} },
    { BackCenter,  {{{FrontLeft, 0.5f/9.0f}, {FrontRight, 0.5f/9.0f}}} },
}};
const std::array<InputRemixMap,4> QuadDownmix{{
    { FrontCenter, {{{FrontLeft,  0.5f}, {FrontRight, 0.5f}}} },
    { SideLeft,    {{{FrontLeft,  0.5f}, {BackLeft,   0.5f}}} },
    { SideRight,   {{{FrontRight, 0.5f}, {BackRight,  0.5f}}} },
    { BackCenter,  {{{BackLeft,   0.5f}, {BackRight,  0.5f}}} },
}};
const std::array<InputRemixMap,3> X51Downmix{{
    { BackLeft,   {{{SideLeft, 1.0f}, {SideRight, 0.0f}}} },
    { BackRight,  {{{SideLeft, 0.0f}, {SideRight, 1.0f}}} },
    { BackCenter, {{{SideLeft, 0.5f}, {SideRight, 0.5f}}} },
}};
const std::array<InputRemixMap,3> X51RearDownmix{{
    { SideLeft,   {{{BackLeft, 1.0f}, {BackRight, 0.0f}}} },
    { SideRight,  {{{BackLeft, 0.0f}, {BackRight, 1.0f}}} },
    { BackCenter, {{{BackLeft, 0.5f}, {BackRight, 0.5f}}} },
}};
const std::array<InputRemixMap,2> X61Downmix{{
    { BackLeft,  {{{BackCenter, 0.5f}, {SideLeft,  0.5f}}} },
    { BackRight, {{{BackCenter, 0.5f}, {SideRight, 0.5f}}} },
}};
const std::array<InputRemixMap,1> X71Downmix{{
    { BackCenter, {{{BackLeft, 0.5f}, {BackRight, 0.5f}}} },
}};

} // namespace

/************************************************
 * Miscellaneous ALC helpers
 ************************************************/

void ALCcontext::processUpdates()
{
    std::lock_guard<std::mutex> _{mPropLock};
    if(mDeferUpdates.exchange(false, std::memory_order_acq_rel))
    {
        /* Tell the mixer to stop applying updates, then wait for any active
         * updating to finish, before providing updates.
         */
        mHoldUpdates.store(true, std::memory_order_release);
        while((mUpdateCount.load(std::memory_order_acquire)&1) != 0) {
            /* busy-wait */
        }

        if(!mPropsClean.test_and_set(std::memory_order_acq_rel))
            UpdateContextProps(this);
        if(!mListener.PropsClean.test_and_set(std::memory_order_acq_rel))
            UpdateListenerProps(this);
        UpdateAllEffectSlotProps(this);
        UpdateAllSourceProps(this);

        /* Now with all updates declared, let the mixer continue applying them
         * so they all happen at once.
         */
        mHoldUpdates.store(false, std::memory_order_release);
    }
}


void ALCcontext::allocVoiceChanges(size_t addcount)
{
    constexpr size_t clustersize{128};
    /* Convert element count to cluster count. */
    addcount = (addcount+(clustersize-1)) / clustersize;
    while(addcount)
    {
        VoiceChangeCluster cluster{std::make_unique<VoiceChange[]>(clustersize)};
        for(size_t i{1};i < clustersize;++i)
            cluster[i-1].mNext.store(std::addressof(cluster[i]), std::memory_order_relaxed);
        cluster[clustersize-1].mNext.store(mVoiceChangeTail, std::memory_order_relaxed);
        mVoiceChangeClusters.emplace_back(std::move(cluster));
        mVoiceChangeTail = mVoiceChangeClusters.back().get();
        --addcount;
    }
}

void ALCcontext::allocVoices(size_t addcount)
{
    constexpr size_t clustersize{32};
    /* Convert element count to cluster count. */
    addcount = (addcount+(clustersize-1)) / clustersize;

    if(addcount >= std::numeric_limits<int>::max()/clustersize - mVoiceClusters.size())
        throw std::runtime_error{"Allocating too many voices"};
    const size_t totalcount{(mVoiceClusters.size()+addcount) * clustersize};
    TRACE("Increasing allocated voices to %zu\n", totalcount);

    auto newarray = VoiceArray::Create(totalcount);
    while(addcount)
    {
        mVoiceClusters.emplace_back(std::make_unique<Voice[]>(clustersize));
        --addcount;
    }

    auto voice_iter = newarray->begin();
    for(VoiceCluster &cluster : mVoiceClusters)
    {
        for(size_t i{0};i < clustersize;++i)
            *(voice_iter++) = &cluster[i];
    }

    if(auto *oldvoices = mVoices.exchange(newarray.release(), std::memory_order_acq_rel))
    {
        mDevice->waitForMix();
        delete oldvoices;
    }
}


/** Stores the latest ALC device error. */
static void alcSetError(ALCdevice *device, ALCenum errorCode)
{
    WARN("Error generated on device %p, code 0x%04x\n", decltype(std::declval<void*>()){device},
        errorCode);
    if(TrapALCError)
    {
#ifdef _WIN32
        /* DebugBreak() will cause an exception if there is no debugger */
        if(IsDebuggerPresent())
            DebugBreak();
#elif defined(SIGTRAP)
        raise(SIGTRAP);
#endif
    }

    if(device)
        device->LastError.store(errorCode);
    else
        LastNullDeviceError.store(errorCode);
}


static std::unique_ptr<Compressor> CreateDeviceLimiter(const ALCdevice *device, const float threshold)
{
    constexpr bool AutoKnee{true};
    constexpr bool AutoAttack{true};
    constexpr bool AutoRelease{true};
    constexpr bool AutoPostGain{true};
    constexpr bool AutoDeclip{true};
    constexpr float LookAheadTime{0.001f};
    constexpr float HoldTime{0.002f};
    constexpr float PreGainDb{0.0f};
    constexpr float PostGainDb{0.0f};
    constexpr float Ratio{std::numeric_limits<float>::infinity()};
    constexpr float KneeDb{0.0f};
    constexpr float AttackTime{0.02f};
    constexpr float ReleaseTime{0.2f};

    return Compressor::Create(device->RealOut.Buffer.size(), static_cast<float>(device->Frequency),
        AutoKnee, AutoAttack, AutoRelease, AutoPostGain, AutoDeclip, LookAheadTime, HoldTime,
        PreGainDb, PostGainDb, threshold, Ratio, KneeDb, AttackTime, ReleaseTime);
}

/**
 * Updates the device's base clock time with however many samples have been
 * done. This is used so frequency changes on the device don't cause the time
 * to jump forward or back. Must not be called while the device is running/
 * mixing.
 */
static inline void UpdateClockBase(ALCdevice *device)
{
    IncrementRef(device->MixCount);
    device->ClockBase += nanoseconds{seconds{device->SamplesDone}} / device->Frequency;
    device->SamplesDone = 0;
    IncrementRef(device->MixCount);
}

/**
 * Updates device parameters according to the attribute list (caller is
 * responsible for holding the list lock).
 */
static ALCenum UpdateDeviceParams(ALCdevice *device, const int *attrList)
{
    HrtfRequestMode hrtf_userreq{Hrtf_Default};
    HrtfRequestMode hrtf_appreq{Hrtf_Default};
    ALCenum gainLimiter{device->LimiterState};
    ALCuint new_sends{device->NumAuxSends};
    DevFmtChannels oldChans;
    DevFmtType oldType;
    ALCsizei hrtf_id{-1};
    ALCuint oldFreq;

    if((!attrList || !attrList[0]) && device->Type == DeviceType::Loopback)
    {
        WARN("Missing attributes for loopback device\n");
        return ALC_INVALID_VALUE;
    }

    // Check for attributes
    if(attrList && attrList[0])
    {
        ALCenum alayout{AL_NONE};
        ALCenum ascale{AL_NONE};
        ALCenum schans{AL_NONE};
        ALCenum stype{AL_NONE};
        ALCsizei attrIdx{0};
        ALCuint aorder{0};
        ALCuint freq{0u};

        ALuint numMono{device->NumMonoSources};
        ALuint numStereo{device->NumStereoSources};
        ALuint numSends{device->NumAuxSends};

#define TRACE_ATTR(a, v) TRACE("%s = %d\n", #a, v)
        while(attrList[attrIdx])
        {
            switch(attrList[attrIdx])
            {
            case ALC_FORMAT_CHANNELS_SOFT:
                schans = attrList[attrIdx + 1];
                TRACE_ATTR(ALC_FORMAT_CHANNELS_SOFT, schans);
                break;

            case ALC_FORMAT_TYPE_SOFT:
                stype = attrList[attrIdx + 1];
                TRACE_ATTR(ALC_FORMAT_TYPE_SOFT, stype);
                break;

            case ALC_FREQUENCY:
                freq = static_cast<ALuint>(attrList[attrIdx + 1]);
                TRACE_ATTR(ALC_FREQUENCY, freq);
                break;

            case ALC_AMBISONIC_LAYOUT_SOFT:
                alayout = attrList[attrIdx + 1];
                TRACE_ATTR(ALC_AMBISONIC_LAYOUT_SOFT, alayout);
                break;

            case ALC_AMBISONIC_SCALING_SOFT:
                ascale = attrList[attrIdx + 1];
                TRACE_ATTR(ALC_AMBISONIC_SCALING_SOFT, ascale);
                break;

            case ALC_AMBISONIC_ORDER_SOFT:
                aorder = static_cast<ALuint>(attrList[attrIdx + 1]);
                TRACE_ATTR(ALC_AMBISONIC_ORDER_SOFT, aorder);
                break;

            case ALC_MONO_SOURCES:
                numMono = static_cast<ALuint>(attrList[attrIdx + 1]);
                TRACE_ATTR(ALC_MONO_SOURCES, numMono);
                if(numMono > INT_MAX) numMono = 0;
                break;

            case ALC_STEREO_SOURCES:
                numStereo = static_cast<ALuint>(attrList[attrIdx + 1]);
                TRACE_ATTR(ALC_STEREO_SOURCES, numStereo);
                if(numStereo > INT_MAX) numStereo = 0;
                break;

            case ALC_MAX_AUXILIARY_SENDS:
                numSends = static_cast<ALuint>(attrList[attrIdx + 1]);
                TRACE_ATTR(ALC_MAX_AUXILIARY_SENDS, numSends);
                if(numSends > INT_MAX) numSends = 0;
                else numSends = minu(numSends, MAX_SENDS);
                break;

            case ALC_HRTF_SOFT:
                TRACE_ATTR(ALC_HRTF_SOFT, attrList[attrIdx + 1]);
                if(attrList[attrIdx + 1] == ALC_FALSE)
                    hrtf_appreq = Hrtf_Disable;
                else if(attrList[attrIdx + 1] == ALC_TRUE)
                    hrtf_appreq = Hrtf_Enable;
                else
                    hrtf_appreq = Hrtf_Default;
                break;

            case ALC_HRTF_ID_SOFT:
                hrtf_id = attrList[attrIdx + 1];
                TRACE_ATTR(ALC_HRTF_ID_SOFT, hrtf_id);
                break;

            case ALC_OUTPUT_LIMITER_SOFT:
                gainLimiter = attrList[attrIdx + 1];
                TRACE_ATTR(ALC_OUTPUT_LIMITER_SOFT, gainLimiter);
                break;

            default:
                TRACE("0x%04X = %d (0x%x)\n", attrList[attrIdx],
                    attrList[attrIdx + 1], attrList[attrIdx + 1]);
                break;
            }

            attrIdx += 2;
        }
#undef TRACE_ATTR

        const bool loopback{device->Type == DeviceType::Loopback};
        if(loopback)
        {
            if(!schans || !stype || !freq)
            {
                WARN("Missing format for loopback device\n");
                return ALC_INVALID_VALUE;
            }
            if(!IsValidALCChannels(schans) || !IsValidALCType(stype) || freq < MIN_OUTPUT_RATE
                || freq > MAX_OUTPUT_RATE)
                return ALC_INVALID_VALUE;
            if(schans == ALC_BFORMAT3D_SOFT)
            {
                if(!alayout || !ascale || !aorder)
                {
                    WARN("Missing ambisonic info for loopback device\n");
                    return ALC_INVALID_VALUE;
                }
                if(!IsValidAmbiLayout(alayout) || !IsValidAmbiScaling(ascale))
                    return ALC_INVALID_VALUE;
                if(aorder < 1 || aorder > MAX_AMBI_ORDER)
                    return ALC_INVALID_VALUE;
                if((alayout == ALC_FUMA_SOFT || ascale == ALC_FUMA_SOFT) && aorder > 3)
                    return ALC_INVALID_VALUE;
            }
        }

        /* If a context is already running on the device, stop playback so the
         * device attributes can be updated.
         */
        if(device->Flags.get<DeviceRunning>())
            device->Backend->stop();
        device->Flags.unset<DeviceRunning>();

        UpdateClockBase(device);

        const char *devname{nullptr};
        if(!loopback)
        {
            devname = device->DeviceName.c_str();

            device->BufferSize = DEFAULT_UPDATE_SIZE * DEFAULT_NUM_UPDATES;
            device->UpdateSize = DEFAULT_UPDATE_SIZE;
            device->Frequency = DEFAULT_OUTPUT_RATE;

            freq = ConfigValueUInt(devname, nullptr, "frequency").value_or(freq);
            if(freq < 1)
                device->Flags.unset<FrequencyRequest>();
            else
            {
                freq = clampu(freq, MIN_OUTPUT_RATE, MAX_OUTPUT_RATE);

                const double scale{static_cast<double>(freq) / device->Frequency};
                device->UpdateSize = static_cast<ALuint>(device->UpdateSize*scale + 0.5);
                device->BufferSize = static_cast<ALuint>(device->BufferSize*scale + 0.5);

                device->Frequency = freq;
                device->Flags.set<FrequencyRequest>();
            }

            if(auto persizeopt = ConfigValueUInt(devname, nullptr, "period_size"))
                device->UpdateSize = clampu(*persizeopt, 64, 8192);

            if(auto peropt = ConfigValueUInt(devname, nullptr, "periods"))
                device->BufferSize = device->UpdateSize * clampu(*peropt, 2, 16);
            else
                device->BufferSize = maxu(device->BufferSize, device->UpdateSize*2);
        }
        else
        {
            device->Frequency = freq;
            device->FmtChans = static_cast<DevFmtChannels>(schans);
            device->FmtType = static_cast<DevFmtType>(stype);
            if(schans == ALC_BFORMAT3D_SOFT)
            {
                device->mAmbiOrder = aorder;
                device->mAmbiLayout = static_cast<DevAmbiLayout>(alayout);
                device->mAmbiScale = static_cast<DevAmbiScaling>(ascale);
            }
        }

        if(numMono > INT_MAX-numStereo)
            numMono = INT_MAX-numStereo;
        numMono += numStereo;
        if(auto srcsopt = ConfigValueUInt(devname, nullptr, "sources"))
        {
            if(*srcsopt <= 0) numMono = 256;
            else numMono = *srcsopt;
        }
        else
            numMono = maxu(numMono, 256);
        numStereo = minu(numStereo, numMono);
        numMono -= numStereo;
        device->SourcesMax = numMono + numStereo;

        device->NumMonoSources = numMono;
        device->NumStereoSources = numStereo;

        if(auto sendsopt = ConfigValueInt(devname, nullptr, "sends"))
            new_sends = minu(numSends, static_cast<ALuint>(clampi(*sendsopt, 0, MAX_SENDS)));
        else
            new_sends = numSends;
    }

    if(device->Flags.get<DeviceRunning>())
        return ALC_NO_ERROR;

    device->AvgSpeakerDist = 0.0f;
    device->Uhj_Encoder = nullptr;
    device->AmbiDecoder = nullptr;
    device->Bs2b = nullptr;
    device->PostProcess = nullptr;

    device->Limiter = nullptr;
    device->ChannelDelay.clear();

    std::fill(std::begin(device->HrtfAccumData), std::end(device->HrtfAccumData), float2{});

    device->Dry.AmbiMap.fill(BFChannelConfig{});
    device->Dry.Buffer = {};
    std::fill(std::begin(device->NumChannelsPerOrder), std::end(device->NumChannelsPerOrder), 0u);
    device->RealOut.RemixMap = {};
    device->RealOut.ChannelIndex.fill(INVALID_CHANNEL_INDEX);
    device->RealOut.Buffer = {};
    device->MixBuffer.clear();
    device->MixBuffer.shrink_to_fit();

    UpdateClockBase(device);
    device->FixedLatency = nanoseconds::zero();

    device->DitherDepth = 0.0f;
    device->DitherSeed = DitherRNGSeed;

    /*************************************************************************
     * Update device format request if HRTF is requested
     */
    device->HrtfStatus = ALC_HRTF_DISABLED_SOFT;
    if(device->Type != DeviceType::Loopback)
    {
        if(auto hrtfopt = ConfigValueStr(device->DeviceName.c_str(), nullptr, "hrtf"))
        {
            const char *hrtf{hrtfopt->c_str()};
            if(al::strcasecmp(hrtf, "true") == 0)
                hrtf_userreq = Hrtf_Enable;
            else if(al::strcasecmp(hrtf, "false") == 0)
                hrtf_userreq = Hrtf_Disable;
            else if(al::strcasecmp(hrtf, "auto") != 0)
                ERR("Unexpected hrtf value: %s\n", hrtf);
        }

        if(hrtf_userreq == Hrtf_Enable || (hrtf_userreq != Hrtf_Disable && hrtf_appreq == Hrtf_Enable))
        {
            device->FmtChans = DevFmtStereo;
            device->Flags.set<ChannelsRequest>();
        }
    }

    oldFreq  = device->Frequency;
    oldChans = device->FmtChans;
    oldType  = device->FmtType;

    TRACE("Pre-reset: %s%s, %s%s, %s%uhz, %u / %u buffer\n",
        device->Flags.get<ChannelsRequest>()?"*":"", DevFmtChannelsString(device->FmtChans),
        device->Flags.get<SampleTypeRequest>()?"*":"", DevFmtTypeString(device->FmtType),
        device->Flags.get<FrequencyRequest>()?"*":"", device->Frequency,
        device->UpdateSize, device->BufferSize);

    try {
        auto backend = device->Backend.get();
        if(!backend->reset())
            throw al::backend_exception{ALC_INVALID_DEVICE, "Device reset failure"};
    }
    catch(std::exception &e) {
        device->handleDisconnect("%s", e.what());
        return ALC_INVALID_DEVICE;
    }

    if(device->FmtChans != oldChans && device->Flags.get<ChannelsRequest>())
    {
        ERR("Failed to set %s, got %s instead\n", DevFmtChannelsString(oldChans),
            DevFmtChannelsString(device->FmtChans));
        device->Flags.unset<ChannelsRequest>();
    }
    if(device->FmtType != oldType && device->Flags.get<SampleTypeRequest>())
    {
        ERR("Failed to set %s, got %s instead\n", DevFmtTypeString(oldType),
            DevFmtTypeString(device->FmtType));
        device->Flags.unset<SampleTypeRequest>();
    }
    if(device->Frequency != oldFreq && device->Flags.get<FrequencyRequest>())
    {
        WARN("Failed to set %uhz, got %uhz instead\n", oldFreq, device->Frequency);
        device->Flags.unset<FrequencyRequest>();
    }

    TRACE("Post-reset: %s, %s, %uhz, %u / %u buffer\n",
        DevFmtChannelsString(device->FmtChans), DevFmtTypeString(device->FmtType),
        device->Frequency, device->UpdateSize, device->BufferSize);

    switch(device->FmtChans)
    {
    case DevFmtMono: device->RealOut.RemixMap = MonoDownmix; break;
    case DevFmtStereo: device->RealOut.RemixMap = StereoDownmix; break;
    case DevFmtQuad: device->RealOut.RemixMap = QuadDownmix; break;
    case DevFmtX51: device->RealOut.RemixMap = X51Downmix; break;
    case DevFmtX51Rear: device->RealOut.RemixMap = X51RearDownmix; break;
    case DevFmtX61: device->RealOut.RemixMap = X61Downmix; break;
    case DevFmtX71: device->RealOut.RemixMap = X71Downmix; break;
    case DevFmtAmbi3D: break;
    }

    aluInitRenderer(device, hrtf_id, hrtf_appreq, hrtf_userreq);

    device->NumAuxSends = new_sends;
    TRACE("Max sources: %d (%d + %d), effect slots: %d, sends: %d\n",
        device->SourcesMax, device->NumMonoSources, device->NumStereoSources,
        device->AuxiliaryEffectSlotMax, device->NumAuxSends);

    nanoseconds::rep sample_delay{0};
    if(device->Uhj_Encoder)
        sample_delay += Uhj2Encoder::sFilterSize;
    if(device->mHrtfState)
        sample_delay += HRTF_DIRECT_DELAY;
    if(auto *ambidec = device->AmbiDecoder.get())
    {
        if(ambidec->hasStablizer())
            sample_delay += FrontStablizer::DelayLength;
    }

    if(GetConfigValueBool(device->DeviceName.c_str(), nullptr, "dither", 1))
    {
        int depth{ConfigValueInt(device->DeviceName.c_str(), nullptr, "dither-depth").value_or(0)};
        if(depth <= 0)
        {
            switch(device->FmtType)
            {
            case DevFmtByte:
            case DevFmtUByte:
                depth = 8;
                break;
            case DevFmtShort:
            case DevFmtUShort:
                depth = 16;
                break;
            case DevFmtInt:
            case DevFmtUInt:
            case DevFmtFloat:
                break;
            }
        }

        if(depth > 0)
        {
            depth = clampi(depth, 2, 24);
            device->DitherDepth = std::pow(2.0f, static_cast<float>(depth-1));
        }
    }
    if(!(device->DitherDepth > 0.0f))
        TRACE("Dithering disabled\n");
    else
        TRACE("Dithering enabled (%d-bit, %g)\n", float2int(std::log2(device->DitherDepth)+0.5f)+1,
              device->DitherDepth);

    device->LimiterState = gainLimiter;
    if(auto limopt = ConfigValueBool(device->DeviceName.c_str(), nullptr, "output-limiter"))
        gainLimiter = *limopt ? ALC_TRUE : ALC_FALSE;

    /* Valid values for gainLimiter are ALC_DONT_CARE_SOFT, ALC_TRUE, and
     * ALC_FALSE. For ALC_DONT_CARE_SOFT, use the limiter for integer-based
     * output (where samples must be clamped), and don't for floating-point
     * (which can take unclamped samples).
     */
    if(gainLimiter == ALC_DONT_CARE_SOFT)
    {
        switch(device->FmtType)
        {
            case DevFmtByte:
            case DevFmtUByte:
            case DevFmtShort:
            case DevFmtUShort:
            case DevFmtInt:
            case DevFmtUInt:
                gainLimiter = ALC_TRUE;
                break;
            case DevFmtFloat:
                gainLimiter = ALC_FALSE;
                break;
        }
    }
    if(gainLimiter == ALC_FALSE)
        TRACE("Output limiter disabled\n");
    else
    {
        float thrshld{1.0f};
        switch(device->FmtType)
        {
            case DevFmtByte:
            case DevFmtUByte:
                thrshld = 127.0f / 128.0f;
                break;
            case DevFmtShort:
            case DevFmtUShort:
                thrshld = 32767.0f / 32768.0f;
                break;
            case DevFmtInt:
            case DevFmtUInt:
            case DevFmtFloat:
                break;
        }
        if(device->DitherDepth > 0.0f)
            thrshld -= 1.0f / device->DitherDepth;

        const float thrshld_dB{std::log10(thrshld) * 20.0f};
        auto limiter = CreateDeviceLimiter(device, thrshld_dB);

        sample_delay += limiter->getLookAhead();
        device->Limiter = std::move(limiter);
        TRACE("Output limiter enabled, %.4fdB limit\n", thrshld_dB);
    }

    /* Convert the sample delay from samples to nanosamples to nanoseconds. */
    device->FixedLatency += nanoseconds{seconds{sample_delay}} / device->Frequency;
    TRACE("Fixed device latency: %" PRId64 "ns\n", int64_t{device->FixedLatency.count()});

    FPUCtl mixer_mode{};
    for(ALCcontext *context : *device->mContexts.load())
    {
        std::unique_lock<std::mutex> proplock{context->mPropLock};
        std::unique_lock<std::mutex> slotlock{context->mEffectSlotLock};

        /* Clear out unused wet buffers. */
        auto buffer_not_in_use = [](WetBufferPtr &wetbuffer) noexcept -> bool
        { return !wetbuffer->mInUse; };
        auto wetbuffer_iter = std::remove_if(context->mWetBuffers.begin(),
            context->mWetBuffers.end(), buffer_not_in_use);
        context->mWetBuffers.erase(wetbuffer_iter, context->mWetBuffers.end());

        if(ALeffectslot *slot{context->mDefaultSlot.get()})
        {
            aluInitEffectPanning(slot, context);

            EffectState *state{slot->Effect.State.get()};
            state->mOutTarget = device->Dry.Buffer;
            state->deviceUpdate(device);
            if(ALbuffer *buffer{slot->Buffer})
                state->setBuffer(device, &buffer->mBuffer);
            slot->updateProps(context);
        }

        if(ALeffectslotArray *curarray{context->mActiveAuxSlots.load(std::memory_order_relaxed)})
            std::fill_n(curarray->end(), curarray->size(), nullptr);
        for(auto &sublist : context->mEffectSlotList)
        {
            uint64_t usemask{~sublist.FreeMask};
            while(usemask)
            {
                const ALsizei idx{CountTrailingZeros(usemask)};
                ALeffectslot *slot{sublist.EffectSlots + idx};
                usemask &= ~(1_u64 << idx);

                aluInitEffectPanning(slot, context);

                EffectState *state{slot->Effect.State.get()};
                state->mOutTarget = device->Dry.Buffer;
                state->deviceUpdate(device);
                if(ALbuffer *buffer{slot->Buffer})
                    state->setBuffer(device, &buffer->mBuffer);
                slot->updateProps(context);
            }
        }
        slotlock.unlock();

        const ALuint num_sends{device->NumAuxSends};
        std::unique_lock<std::mutex> srclock{context->mSourceLock};
        for(auto &sublist : context->mSourceList)
        {
            uint64_t usemask{~sublist.FreeMask};
            while(usemask)
            {
                const ALsizei idx{CountTrailingZeros(usemask)};
                ALsource *source{sublist.Sources + idx};
                usemask &= ~(1_u64 << idx);

                auto clear_send = [](ALsource::SendData &send) -> void
                {
                    if(send.Slot)
                        DecrementRef(send.Slot->ref);
                    send.Slot = nullptr;
                    send.Gain = 1.0f;
                    send.GainHF = 1.0f;
                    send.HFReference = LOWPASSFREQREF;
                    send.GainLF = 1.0f;
                    send.LFReference = HIGHPASSFREQREF;
                };
                auto send_begin = source->Send.begin() + static_cast<ptrdiff_t>(num_sends);
                std::for_each(send_begin, source->Send.end(), clear_send);

                source->PropsClean.clear(std::memory_order_release);
            }
        }

        /* Clear any pre-existing voice property structs, in case the number of
         * auxiliary sends is changing. Active sources will have updates
         * respecified in UpdateAllSourceProps.
         */
        VoicePropsItem *vprops{context->mFreeVoiceProps.exchange(nullptr, std::memory_order_acq_rel)};
        while(vprops)
        {
            VoicePropsItem *next = vprops->next.load(std::memory_order_relaxed);
            delete vprops;
            vprops = next;
        }

        auto voicelist = context->getVoicesSpan();
        for(Voice *voice : voicelist)
        {
            /* Clear extraneous property set sends. */
            std::fill(std::begin(voice->mProps.Send)+num_sends, std::end(voice->mProps.Send),
                VoiceProps::SendData{});

            std::fill(voice->mSend.begin()+num_sends, voice->mSend.end(), Voice::TargetData{});
            for(auto &chandata : voice->mChans)
            {
                std::fill(chandata.mWetParams.begin()+num_sends, chandata.mWetParams.end(),
                    SendParams{});
            }

            delete voice->mUpdate.exchange(nullptr, std::memory_order_acq_rel);

            /* Force the voice to stopped if it was stopping. */
            Voice::State vstate{Voice::Stopping};
            voice->mPlayState.compare_exchange_strong(vstate, Voice::Stopped,
                std::memory_order_acquire, std::memory_order_acquire);
            if(voice->mSourceID.load(std::memory_order_relaxed) == 0u)
                continue;

            voice->mStep = 0;
            voice->mFlags |= VoiceIsFading;

            if(voice->mAmbiOrder && device->mAmbiOrder > voice->mAmbiOrder)
            {
                const uint8_t *OrderFromChan{(voice->mFmtChannels == FmtBFormat2D) ?
                    AmbiIndex::OrderFrom2DChannel.data() :
                    AmbiIndex::OrderFromChannel.data()};

                const BandSplitter splitter{400.0f / static_cast<float>(device->Frequency)};

                const auto scales = BFormatDec::GetHFOrderScales(voice->mAmbiOrder,
                    device->mAmbiOrder);
                for(auto &chandata : voice->mChans)
                {
                    chandata.mPrevSamples.fill(0.0f);
                    chandata.mAmbiScale = scales[*(OrderFromChan++)];
                    chandata.mAmbiSplitter = splitter;
                    chandata.mDryParams = DirectParams{};
                    std::fill_n(chandata.mWetParams.begin(), num_sends, SendParams{});
                }

                voice->mFlags |= VoiceIsAmbisonic;
            }
            else
            {
                /* Clear previous samples. */
                for(auto &chandata : voice->mChans)
                {
                    chandata.mPrevSamples.fill(0.0f);
                    chandata.mDryParams = DirectParams{};
                    std::fill_n(chandata.mWetParams.begin(), num_sends, SendParams{});
                }

                voice->mFlags &= ~VoiceIsAmbisonic;
            }

            if(device->AvgSpeakerDist > 0.0f)
            {
                /* Reinitialize the NFC filters for new parameters. */
                const float w1{SpeedOfSoundMetersPerSec /
                    (device->AvgSpeakerDist * static_cast<float>(device->Frequency))};
                for(auto &chandata : voice->mChans)
                    chandata.mDryParams.NFCtrlFilter.init(w1);
            }
        }
        srclock.unlock();

        context->mPropsClean.test_and_set(std::memory_order_release);
        UpdateContextProps(context);
        context->mListener.PropsClean.test_and_set(std::memory_order_release);
        UpdateListenerProps(context);
        UpdateAllSourceProps(context);
    }
    mixer_mode.leave();

    if(!device->Flags.get<DevicePaused>())
    {
        try {
            auto backend = device->Backend.get();
            backend->start();
            device->Flags.set<DeviceRunning>();
        }
        catch(al::backend_exception& e) {
            device->handleDisconnect("%s", e.what());
            return ALC_INVALID_DEVICE;
        }
    }

    return ALC_NO_ERROR;
}


ALCdevice::ALCdevice(DeviceType type) : Type{type}, mContexts{&EmptyContextArray}
{
}

ALCdevice::~ALCdevice()
{
    TRACE("Freeing device %p\n", decltype(std::declval<void*>()){this});

    Backend = nullptr;

    size_t count{std::accumulate(BufferList.cbegin(), BufferList.cend(), size_t{0u},
        [](size_t cur, const BufferSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(~sublist.FreeMask)); })};
    if(count > 0)
        WARN("%zu Buffer%s not deleted\n", count, (count==1)?"":"s");

    count = std::accumulate(EffectList.cbegin(), EffectList.cend(), size_t{0u},
        [](size_t cur, const EffectSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(~sublist.FreeMask)); });
    if(count > 0)
        WARN("%zu Effect%s not deleted\n", count, (count==1)?"":"s");

    count = std::accumulate(FilterList.cbegin(), FilterList.cend(), size_t{0u},
        [](size_t cur, const FilterSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(~sublist.FreeMask)); });
    if(count > 0)
        WARN("%zu Filter%s not deleted\n", count, (count==1)?"":"s");

    mHrtf = nullptr;

    auto *oldarray = mContexts.exchange(nullptr, std::memory_order_relaxed);
    if(oldarray != &EmptyContextArray) delete oldarray;
}


/** Checks if the device handle is valid, and returns a new reference if so. */
static DeviceRef VerifyDevice(ALCdevice *device)
{
    std::lock_guard<std::recursive_mutex> _{ListLock};
    auto iter = std::lower_bound(DeviceList.begin(), DeviceList.end(), device);
    if(iter != DeviceList.end() && *iter == device)
    {
        (*iter)->add_ref();
        return DeviceRef{*iter};
    }
    return nullptr;
}


ALCcontext::ALCcontext(al::intrusive_ptr<ALCdevice> device) : mDevice{std::move(device)}
{
    mPropsClean.test_and_set(std::memory_order_relaxed);
}

ALCcontext::~ALCcontext()
{
    TRACE("Freeing context %p\n", decltype(std::declval<void*>()){this});

    size_t count{0};
    ALcontextProps *cprops{mUpdate.exchange(nullptr, std::memory_order_relaxed)};
    if(cprops)
    {
        ++count;
        delete cprops;
    }
    cprops = mFreeContextProps.exchange(nullptr, std::memory_order_acquire);
    while(cprops)
    {
        ALcontextProps *next{cprops->next.load(std::memory_order_relaxed)};
        delete cprops;
        cprops = next;
        ++count;
    }
    TRACE("Freed %zu context property object%s\n", count, (count==1)?"":"s");

    count = std::accumulate(mSourceList.cbegin(), mSourceList.cend(), size_t{0u},
        [](size_t cur, const SourceSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(~sublist.FreeMask)); });
    if(count > 0)
        WARN("%zu Source%s not deleted\n", count, (count==1)?"":"s");
    mSourceList.clear();
    mNumSources = 0;

    count = 0;
    ALeffectslotProps *eprops{mFreeEffectslotProps.exchange(nullptr, std::memory_order_acquire)};
    while(eprops)
    {
        ALeffectslotProps *next{eprops->next.load(std::memory_order_relaxed)};
        delete eprops;
        eprops = next;
        ++count;
    }
    TRACE("Freed %zu AuxiliaryEffectSlot property object%s\n", count, (count==1)?"":"s");

    if(ALeffectslotArray *curarray{mActiveAuxSlots.exchange(nullptr, std::memory_order_relaxed)})
    {
        al::destroy_n(curarray->end(), curarray->size());
        delete curarray;
    }
    mDefaultSlot = nullptr;

    count = std::accumulate(mEffectSlotList.cbegin(), mEffectSlotList.cend(), size_t{0u},
        [](size_t cur, const EffectSlotSubList &sublist) noexcept -> size_t
        { return cur + static_cast<ALuint>(PopCount(~sublist.FreeMask)); });
    if(count > 0)
        WARN("%zu AuxiliaryEffectSlot%s not deleted\n", count, (count==1)?"":"s");
    mEffectSlotList.clear();
    mNumEffectSlots = 0;

    count = 0;
    VoicePropsItem *vprops{mFreeVoiceProps.exchange(nullptr, std::memory_order_acquire)};
    while(vprops)
    {
        VoicePropsItem *next{vprops->next.load(std::memory_order_relaxed)};
        delete vprops;
        vprops = next;
        ++count;
    }
    TRACE("Freed %zu voice property object%s\n", count, (count==1)?"":"s");

    delete mVoices.exchange(nullptr, std::memory_order_relaxed);

    count = 0;
    ALlistenerProps *lprops{mListener.Params.Update.exchange(nullptr, std::memory_order_relaxed)};
    if(lprops)
    {
        ++count;
        delete lprops;
    }
    lprops = mFreeListenerProps.exchange(nullptr, std::memory_order_acquire);
    while(lprops)
    {
        ALlistenerProps *next{lprops->next.load(std::memory_order_relaxed)};
        delete lprops;
        lprops = next;
        ++count;
    }
    TRACE("Freed %zu listener property object%s\n", count, (count==1)?"":"s");

    if(mAsyncEvents)
    {
        count = 0;
        auto evt_vec = mAsyncEvents->getReadVector();
        if(evt_vec.first.len > 0)
        {
            al::destroy_n(reinterpret_cast<AsyncEvent*>(evt_vec.first.buf), evt_vec.first.len);
            count += evt_vec.first.len;
        }
        if(evt_vec.second.len > 0)
        {
            al::destroy_n(reinterpret_cast<AsyncEvent*>(evt_vec.second.buf), evt_vec.second.len);
            count += evt_vec.second.len;
        }
        if(count > 0)
            TRACE("Destructed %zu orphaned event%s\n", count, (count==1)?"":"s");
        mAsyncEvents->readAdvance(count);
    }
}

void ALCcontext::init()
{
    if(DefaultEffect.type != AL_EFFECT_NULL && mDevice->Type == DeviceType::Playback)
    {
        mDefaultSlot = std::unique_ptr<ALeffectslot>{new ALeffectslot{}};
        if(mDefaultSlot->init() == AL_NO_ERROR)
            aluInitEffectPanning(mDefaultSlot.get(), this);
        else
        {
            mDefaultSlot = nullptr;
            ERR("Failed to initialize the default effect slot\n");
        }
    }

    ALeffectslotArray *auxslots;
    if(!mDefaultSlot)
        auxslots = ALeffectslot::CreatePtrArray(0);
    else
    {
        auxslots = ALeffectslot::CreatePtrArray(1);
        (*auxslots)[0] = mDefaultSlot.get();
        mDefaultSlot->mState = SlotState::Playing;
    }
    mActiveAuxSlots.store(auxslots, std::memory_order_relaxed);

    allocVoiceChanges(1);
    {
        VoiceChange *cur{mVoiceChangeTail};
        while(VoiceChange *next{cur->mNext.load(std::memory_order_relaxed)})
            cur = next;
        mCurrentVoiceChange.store(cur, std::memory_order_relaxed);
    }

    mExtensionList = alExtList;


    mListener.Params.Matrix = alu::Matrix::Identity();
    mListener.Params.Velocity = alu::Vector{};
    mListener.Params.Gain = mListener.Gain;
    mListener.Params.MetersPerUnit = mListener.mMetersPerUnit;
    mListener.Params.DopplerFactor = mDopplerFactor;
    mListener.Params.SpeedOfSound = mSpeedOfSound * mDopplerVelocity;
    mListener.Params.SourceDistanceModel = mSourceDistanceModel;
    mListener.Params.mDistanceModel = mDistanceModel;


    mAsyncEvents = RingBuffer::Create(511, sizeof(AsyncEvent), false);
    StartEventThrd(this);


    allocVoices(256);
    mActiveVoiceCount.store(64, std::memory_order_relaxed);
}

bool ALCcontext::deinit()
{
    if(LocalContext == this)
    {
        WARN("%p released while current on thread\n", decltype(std::declval<void*>()){this});
        ThreadContext.set(nullptr);
        release();
    }

    ALCcontext *origctx{this};
    if(GlobalContext.compare_exchange_strong(origctx, nullptr))
        release();

    bool ret{};
    /* First make sure this context exists in the device's list. */
    auto *oldarray = mDevice->mContexts.load(std::memory_order_acquire);
    if(auto toremove = static_cast<size_t>(std::count(oldarray->begin(), oldarray->end(), this)))
    {
        using ContextArray = al::FlexArray<ALCcontext*>;
        auto alloc_ctx_array = [](const size_t count) -> ContextArray*
        {
            if(count == 0) return &EmptyContextArray;
            return ContextArray::Create(count).release();
        };
        auto *newarray = alloc_ctx_array(oldarray->size() - toremove);

        /* Copy the current/old context handles to the new array, excluding the
         * given context.
         */
        std::copy_if(oldarray->begin(), oldarray->end(), newarray->begin(),
            std::bind(std::not_equal_to<ALCcontext*>{}, _1, this));

        /* Store the new context array in the device. Wait for any current mix
         * to finish before deleting the old array.
         */
        mDevice->mContexts.store(newarray);
        if(oldarray != &EmptyContextArray)
        {
            mDevice->waitForMix();
            delete oldarray;
        }

        ret = !newarray->empty();
    }
    else
        ret = !oldarray->empty();

    StopEventThrd(this);

    return ret;
}


/**
 * Checks if the given context is valid, returning a new reference to it if so.
 */
static ContextRef VerifyContext(ALCcontext *context)
{
    std::lock_guard<std::recursive_mutex> _{ListLock};
    auto iter = std::lower_bound(ContextList.begin(), ContextList.end(), context);
    if(iter != ContextList.end() && *iter == context)
    {
        (*iter)->add_ref();
        return ContextRef{*iter};
    }
    return nullptr;
}

/** Returns a new reference to the currently active context for this thread. */
ContextRef GetContextRef(void)
{
    ALCcontext *context{LocalContext};
    if(context)
        context->add_ref();
    else
    {
        std::lock_guard<std::recursive_mutex> _{ListLock};
        context = GlobalContext.load(std::memory_order_acquire);
        if(context) context->add_ref();
    }
    return ContextRef{context};
}


/************************************************
 * Standard ALC functions
 ************************************************/

ALC_API ALCenum ALC_APIENTRY alcGetError(ALCdevice *device)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(dev) return dev->LastError.exchange(ALC_NO_ERROR);
    return LastNullDeviceError.exchange(ALC_NO_ERROR);
}
END_API_FUNC


ALC_API void ALC_APIENTRY alcSuspendContext(ALCcontext *context)
START_API_FUNC
{
    if(!SuspendDefers)
        return;

    ContextRef ctx{VerifyContext(context)};
    if(!ctx)
        alcSetError(nullptr, ALC_INVALID_CONTEXT);
    else
        ctx->deferUpdates();
}
END_API_FUNC

ALC_API void ALC_APIENTRY alcProcessContext(ALCcontext *context)
START_API_FUNC
{
    if(!SuspendDefers)
        return;

    ContextRef ctx{VerifyContext(context)};
    if(!ctx)
        alcSetError(nullptr, ALC_INVALID_CONTEXT);
    else
        ctx->processUpdates();
}
END_API_FUNC


ALC_API const ALCchar* ALC_APIENTRY alcGetString(ALCdevice *Device, ALCenum param)
START_API_FUNC
{
    const ALCchar *value{nullptr};

    switch(param)
    {
    case ALC_NO_ERROR:
        value = alcNoError;
        break;

    case ALC_INVALID_ENUM:
        value = alcErrInvalidEnum;
        break;

    case ALC_INVALID_VALUE:
        value = alcErrInvalidValue;
        break;

    case ALC_INVALID_DEVICE:
        value = alcErrInvalidDevice;
        break;

    case ALC_INVALID_CONTEXT:
        value = alcErrInvalidContext;
        break;

    case ALC_OUT_OF_MEMORY:
        value = alcErrOutOfMemory;
        break;

    case ALC_DEVICE_SPECIFIER:
        value = alcDefaultName;
        break;

    case ALC_ALL_DEVICES_SPECIFIER:
        if(DeviceRef dev{VerifyDevice(Device)})
            value = dev->DeviceName.c_str();
        else
        {
            ProbeAllDevicesList();
            value = alcAllDevicesList.c_str();
        }
        break;

    case ALC_CAPTURE_DEVICE_SPECIFIER:
        if(DeviceRef dev{VerifyDevice(Device)})
            value = dev->DeviceName.c_str();
        else
        {
            ProbeCaptureDeviceList();
            value = alcCaptureDeviceList.c_str();
        }
        break;

    /* Default devices are always first in the list */
    case ALC_DEFAULT_DEVICE_SPECIFIER:
        value = alcDefaultName;
        break;

    case ALC_DEFAULT_ALL_DEVICES_SPECIFIER:
        if(alcAllDevicesList.empty())
            ProbeAllDevicesList();

        /* Copy first entry as default. */
        alcDefaultAllDevicesSpecifier = alcAllDevicesList.c_str();
        value = alcDefaultAllDevicesSpecifier.c_str();
        break;

    case ALC_CAPTURE_DEFAULT_DEVICE_SPECIFIER:
        if(alcCaptureDeviceList.empty())
            ProbeCaptureDeviceList();

        /* Copy first entry as default. */
        alcCaptureDefaultDeviceSpecifier = alcCaptureDeviceList.c_str();
        value = alcCaptureDefaultDeviceSpecifier.c_str();
        break;

    case ALC_EXTENSIONS:
        if(VerifyDevice(Device))
            value = alcExtensionList;
        else
            value = alcNoDeviceExtList;
        break;

    case ALC_HRTF_SPECIFIER_SOFT:
        if(DeviceRef dev{VerifyDevice(Device)})
        {
            std::lock_guard<std::mutex> _{dev->StateLock};
            value = (dev->mHrtf ? dev->HrtfName.c_str() : "");
        }
        else
            alcSetError(nullptr, ALC_INVALID_DEVICE);
        break;

    default:
        alcSetError(VerifyDevice(Device).get(), ALC_INVALID_ENUM);
        break;
    }

    return value;
}
END_API_FUNC


static inline ALCsizei NumAttrsForDevice(ALCdevice *device)
{
    if(device->Type == DeviceType::Capture) return 9;
    if(device->Type != DeviceType::Loopback) return 29;
    if(device->FmtChans == DevFmtAmbi3D)
        return 35;
    return 29;
}

static size_t GetIntegerv(ALCdevice *device, ALCenum param, const al::span<int> values)
{
    size_t i;

    if(values.empty())
    {
        alcSetError(device, ALC_INVALID_VALUE);
        return 0;
    }

    if(!device)
    {
        switch(param)
        {
        case ALC_MAJOR_VERSION:
            values[0] = alcMajorVersion;
            return 1;
        case ALC_MINOR_VERSION:
            values[0] = alcMinorVersion;
            return 1;

        case ALC_ATTRIBUTES_SIZE:
        case ALC_ALL_ATTRIBUTES:
        case ALC_FREQUENCY:
        case ALC_REFRESH:
        case ALC_SYNC:
        case ALC_MONO_SOURCES:
        case ALC_STEREO_SOURCES:
        case ALC_CAPTURE_SAMPLES:
        case ALC_FORMAT_CHANNELS_SOFT:
        case ALC_FORMAT_TYPE_SOFT:
        case ALC_AMBISONIC_LAYOUT_SOFT:
        case ALC_AMBISONIC_SCALING_SOFT:
        case ALC_AMBISONIC_ORDER_SOFT:
        case ALC_MAX_AMBISONIC_ORDER_SOFT:
            alcSetError(nullptr, ALC_INVALID_DEVICE);
            return 0;

        default:
            alcSetError(nullptr, ALC_INVALID_ENUM);
        }
        return 0;
    }

    if(device->Type == DeviceType::Capture)
    {
        switch(param)
        {
        case ALC_ATTRIBUTES_SIZE:
            values[0] = NumAttrsForDevice(device);
            return 1;

        case ALC_ALL_ATTRIBUTES:
            i = 0;
            if(values.size() < static_cast<size_t>(NumAttrsForDevice(device)))
                alcSetError(device, ALC_INVALID_VALUE);
            else
            {
                std::lock_guard<std::mutex> _{device->StateLock};
                values[i++] = ALC_MAJOR_VERSION;
                values[i++] = alcMajorVersion;
                values[i++] = ALC_MINOR_VERSION;
                values[i++] = alcMinorVersion;
                values[i++] = ALC_CAPTURE_SAMPLES;
                values[i++] = static_cast<int>(device->Backend->availableSamples());
                values[i++] = ALC_CONNECTED;
                values[i++] = device->Connected.load(std::memory_order_relaxed);
                values[i++] = 0;
            }
            return i;

        case ALC_MAJOR_VERSION:
            values[0] = alcMajorVersion;
            return 1;
        case ALC_MINOR_VERSION:
            values[0] = alcMinorVersion;
            return 1;

        case ALC_CAPTURE_SAMPLES:
            {
                std::lock_guard<std::mutex> _{device->StateLock};
                values[0] = static_cast<int>(device->Backend->availableSamples());
            }
            return 1;

        case ALC_CONNECTED:
            {
                std::lock_guard<std::mutex> _{device->StateLock};
                values[0] = device->Connected.load(std::memory_order_acquire);
            }
            return 1;

        default:
            alcSetError(device, ALC_INVALID_ENUM);
        }
        return 0;
    }

    /* render device */
    switch(param)
    {
    case ALC_ATTRIBUTES_SIZE:
        values[0] = NumAttrsForDevice(device);
        return 1;

    case ALC_ALL_ATTRIBUTES:
        i = 0;
        if(values.size() < static_cast<size_t>(NumAttrsForDevice(device)))
            alcSetError(device, ALC_INVALID_VALUE);
        else
        {
            std::lock_guard<std::mutex> _{device->StateLock};
            values[i++] = ALC_MAJOR_VERSION;
            values[i++] = alcMajorVersion;
            values[i++] = ALC_MINOR_VERSION;
            values[i++] = alcMinorVersion;
            values[i++] = ALC_EFX_MAJOR_VERSION;
            values[i++] = alcEFXMajorVersion;
            values[i++] = ALC_EFX_MINOR_VERSION;
            values[i++] = alcEFXMinorVersion;

            values[i++] = ALC_FREQUENCY;
            values[i++] = static_cast<int>(device->Frequency);
            if(device->Type != DeviceType::Loopback)
            {
                values[i++] = ALC_REFRESH;
                values[i++] = static_cast<int>(device->Frequency / device->UpdateSize);

                values[i++] = ALC_SYNC;
                values[i++] = ALC_FALSE;
            }
            else
            {
                if(device->FmtChans == DevFmtAmbi3D)
                {
                    values[i++] = ALC_AMBISONIC_LAYOUT_SOFT;
                    values[i++] = static_cast<int>(device->mAmbiLayout);

                    values[i++] = ALC_AMBISONIC_SCALING_SOFT;
                    values[i++] = static_cast<int>(device->mAmbiScale);

                    values[i++] = ALC_AMBISONIC_ORDER_SOFT;
                    values[i++] = static_cast<int>(device->mAmbiOrder);
                }

                values[i++] = ALC_FORMAT_CHANNELS_SOFT;
                values[i++] = device->FmtChans;

                values[i++] = ALC_FORMAT_TYPE_SOFT;
                values[i++] = device->FmtType;
            }

            values[i++] = ALC_MONO_SOURCES;
            values[i++] = static_cast<int>(device->NumMonoSources);

            values[i++] = ALC_STEREO_SOURCES;
            values[i++] = static_cast<int>(device->NumStereoSources);

            values[i++] = ALC_MAX_AUXILIARY_SENDS;
            values[i++] = static_cast<int>(device->NumAuxSends);

            values[i++] = ALC_HRTF_SOFT;
            values[i++] = (device->mHrtf ? ALC_TRUE : ALC_FALSE);

            values[i++] = ALC_HRTF_STATUS_SOFT;
            values[i++] = device->HrtfStatus;

            values[i++] = ALC_OUTPUT_LIMITER_SOFT;
            values[i++] = device->Limiter ? ALC_TRUE : ALC_FALSE;

            values[i++] = ALC_MAX_AMBISONIC_ORDER_SOFT;
            values[i++] = MAX_AMBI_ORDER;

            values[i++] = 0;
        }
        return i;

    case ALC_MAJOR_VERSION:
        values[0] = alcMajorVersion;
        return 1;

    case ALC_MINOR_VERSION:
        values[0] = alcMinorVersion;
        return 1;

    case ALC_EFX_MAJOR_VERSION:
        values[0] = alcEFXMajorVersion;
        return 1;

    case ALC_EFX_MINOR_VERSION:
        values[0] = alcEFXMinorVersion;
        return 1;

    case ALC_FREQUENCY:
        values[0] = static_cast<int>(device->Frequency);
        return 1;

    case ALC_REFRESH:
        if(device->Type == DeviceType::Loopback)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        {
            std::lock_guard<std::mutex> _{device->StateLock};
            values[0] = static_cast<int>(device->Frequency / device->UpdateSize);
        }
        return 1;

    case ALC_SYNC:
        if(device->Type == DeviceType::Loopback)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        values[0] = ALC_FALSE;
        return 1;

    case ALC_FORMAT_CHANNELS_SOFT:
        if(device->Type != DeviceType::Loopback)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        values[0] = device->FmtChans;
        return 1;

    case ALC_FORMAT_TYPE_SOFT:
        if(device->Type != DeviceType::Loopback)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        values[0] = device->FmtType;
        return 1;

    case ALC_AMBISONIC_LAYOUT_SOFT:
        if(device->Type != DeviceType::Loopback || device->FmtChans != DevFmtAmbi3D)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        values[0] = static_cast<int>(device->mAmbiLayout);
        return 1;

    case ALC_AMBISONIC_SCALING_SOFT:
        if(device->Type != DeviceType::Loopback || device->FmtChans != DevFmtAmbi3D)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        values[0] = static_cast<int>(device->mAmbiScale);
        return 1;

    case ALC_AMBISONIC_ORDER_SOFT:
        if(device->Type != DeviceType::Loopback || device->FmtChans != DevFmtAmbi3D)
        {
            alcSetError(device, ALC_INVALID_DEVICE);
            return 0;
        }
        values[0] = static_cast<int>(device->mAmbiOrder);
        return 1;

    case ALC_MONO_SOURCES:
        values[0] = static_cast<int>(device->NumMonoSources);
        return 1;

    case ALC_STEREO_SOURCES:
        values[0] = static_cast<int>(device->NumStereoSources);
        return 1;

    case ALC_MAX_AUXILIARY_SENDS:
        values[0] = static_cast<int>(device->NumAuxSends);
        return 1;

    case ALC_CONNECTED:
        {
            std::lock_guard<std::mutex> _{device->StateLock};
            values[0] = device->Connected.load(std::memory_order_acquire);
        }
        return 1;

    case ALC_HRTF_SOFT:
        values[0] = (device->mHrtf ? ALC_TRUE : ALC_FALSE);
        return 1;

    case ALC_HRTF_STATUS_SOFT:
        values[0] = device->HrtfStatus;
        return 1;

    case ALC_NUM_HRTF_SPECIFIERS_SOFT:
        {
            std::lock_guard<std::mutex> _{device->StateLock};
            device->HrtfList = EnumerateHrtf(device->DeviceName.c_str());
            values[0] = static_cast<int>(minz(device->HrtfList.size(),
                std::numeric_limits<int>::max()));
        }
        return 1;

    case ALC_OUTPUT_LIMITER_SOFT:
        values[0] = device->Limiter ? ALC_TRUE : ALC_FALSE;
        return 1;

    case ALC_MAX_AMBISONIC_ORDER_SOFT:
        values[0] = MAX_AMBI_ORDER;
        return 1;

    default:
        alcSetError(device, ALC_INVALID_ENUM);
    }
    return 0;
}

ALC_API void ALC_APIENTRY alcGetIntegerv(ALCdevice *device, ALCenum param, ALCsizei size, ALCint *values)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(size <= 0 || values == nullptr)
        alcSetError(dev.get(), ALC_INVALID_VALUE);
    else
        GetIntegerv(dev.get(), param, {values, static_cast<ALuint>(size)});
}
END_API_FUNC

ALC_API void ALC_APIENTRY alcGetInteger64vSOFT(ALCdevice *device, ALCenum pname, ALCsizei size, ALCint64SOFT *values)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(size <= 0 || values == nullptr)
    {
        alcSetError(dev.get(), ALC_INVALID_VALUE);
        return;
    }
    if(!dev || dev->Type == DeviceType::Capture)
    {
        auto ivals = al::vector<int>(static_cast<ALuint>(size));
        size_t got{GetIntegerv(dev.get(), pname, ivals)};
        std::copy_n(ivals.begin(), got, values);
        return;
    }
    /* render device */
    switch(pname)
    {
    case ALC_ATTRIBUTES_SIZE:
        *values = NumAttrsForDevice(dev.get())+4;
        break;

    case ALC_ALL_ATTRIBUTES:
        if(size < NumAttrsForDevice(dev.get())+4)
            alcSetError(dev.get(), ALC_INVALID_VALUE);
        else
        {
            size_t i{0};
            std::lock_guard<std::mutex> _{dev->StateLock};
            values[i++] = ALC_FREQUENCY;
            values[i++] = dev->Frequency;

            if(dev->Type != DeviceType::Loopback)
            {
                values[i++] = ALC_REFRESH;
                values[i++] = dev->Frequency / dev->UpdateSize;

                values[i++] = ALC_SYNC;
                values[i++] = ALC_FALSE;
            }
            else
            {
                if(dev->FmtChans == DevFmtAmbi3D)
                {
                    values[i++] = ALC_AMBISONIC_LAYOUT_SOFT;
                    values[i++] = static_cast<int64_t>(dev->mAmbiLayout);

                    values[i++] = ALC_AMBISONIC_SCALING_SOFT;
                    values[i++] = static_cast<int64_t>(dev->mAmbiScale);

                    values[i++] = ALC_AMBISONIC_ORDER_SOFT;
                    values[i++] = dev->mAmbiOrder;
                }

                values[i++] = ALC_FORMAT_CHANNELS_SOFT;
                values[i++] = dev->FmtChans;

                values[i++] = ALC_FORMAT_TYPE_SOFT;
                values[i++] = dev->FmtType;
            }

            values[i++] = ALC_MONO_SOURCES;
            values[i++] = dev->NumMonoSources;

            values[i++] = ALC_STEREO_SOURCES;
            values[i++] = dev->NumStereoSources;

            values[i++] = ALC_MAX_AUXILIARY_SENDS;
            values[i++] = dev->NumAuxSends;

            values[i++] = ALC_HRTF_SOFT;
            values[i++] = (dev->mHrtf ? ALC_TRUE : ALC_FALSE);

            values[i++] = ALC_HRTF_STATUS_SOFT;
            values[i++] = dev->HrtfStatus;

            values[i++] = ALC_OUTPUT_LIMITER_SOFT;
            values[i++] = dev->Limiter ? ALC_TRUE : ALC_FALSE;

            ClockLatency clock{GetClockLatency(dev.get())};
            values[i++] = ALC_DEVICE_CLOCK_SOFT;
            values[i++] = clock.ClockTime.count();

            values[i++] = ALC_DEVICE_LATENCY_SOFT;
            values[i++] = clock.Latency.count();

            values[i++] = 0;
        }
        break;

    case ALC_DEVICE_CLOCK_SOFT:
        {
            std::lock_guard<std::mutex> _{dev->StateLock};
            ALuint samplecount, refcount;
            nanoseconds basecount;
            do {
                refcount = dev->waitForMix();
                basecount = dev->ClockBase;
                samplecount = dev->SamplesDone;
            } while(refcount != ReadRef(dev->MixCount));
            basecount += nanoseconds{seconds{samplecount}} / dev->Frequency;
            *values = basecount.count();
        }
        break;

    case ALC_DEVICE_LATENCY_SOFT:
        {
            std::lock_guard<std::mutex> _{dev->StateLock};
            ClockLatency clock{GetClockLatency(dev.get())};
            *values = clock.Latency.count();
        }
        break;

    case ALC_DEVICE_CLOCK_LATENCY_SOFT:
        if(size < 2)
            alcSetError(dev.get(), ALC_INVALID_VALUE);
        else
        {
            std::lock_guard<std::mutex> _{dev->StateLock};
            ClockLatency clock{GetClockLatency(dev.get())};
            values[0] = clock.ClockTime.count();
            values[1] = clock.Latency.count();
        }
        break;

    default:
        auto ivals = al::vector<int>(static_cast<ALuint>(size));
        size_t got{GetIntegerv(dev.get(), pname, ivals)};
        std::copy_n(ivals.begin(), got, values);
        break;
    }
}
END_API_FUNC


ALC_API ALCboolean ALC_APIENTRY alcIsExtensionPresent(ALCdevice *device, const ALCchar *extName)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!extName)
        alcSetError(dev.get(), ALC_INVALID_VALUE);
    else
    {
        size_t len = strlen(extName);
        const char *ptr = (dev ? alcExtensionList : alcNoDeviceExtList);
        while(ptr && *ptr)
        {
            if(al::strncasecmp(ptr, extName, len) == 0 && (ptr[len] == '\0' || isspace(ptr[len])))
                return ALC_TRUE;

            if((ptr=strchr(ptr, ' ')) != nullptr)
            {
                do {
                    ++ptr;
                } while(isspace(*ptr));
            }
        }
    }
    return ALC_FALSE;
}
END_API_FUNC


ALC_API ALCvoid* ALC_APIENTRY alcGetProcAddress(ALCdevice *device, const ALCchar *funcName)
START_API_FUNC
{
    if(!funcName)
    {
        DeviceRef dev{VerifyDevice(device)};
        alcSetError(dev.get(), ALC_INVALID_VALUE);
    }
    else
    {
        for(const auto &func : alcFunctions)
        {
            if(strcmp(func.funcName, funcName) == 0)
                return func.address;
        }
    }
    return nullptr;
}
END_API_FUNC


ALC_API ALCenum ALC_APIENTRY alcGetEnumValue(ALCdevice *device, const ALCchar *enumName)
START_API_FUNC
{
    if(!enumName)
    {
        DeviceRef dev{VerifyDevice(device)};
        alcSetError(dev.get(), ALC_INVALID_VALUE);
    }
    else
    {
        for(const auto &enm : alcEnumerations)
        {
            if(strcmp(enm.enumName, enumName) == 0)
                return enm.value;
        }
    }
    return 0;
}
END_API_FUNC


ALC_API ALCcontext* ALC_APIENTRY alcCreateContext(ALCdevice *device, const ALCint *attrList)
START_API_FUNC
{
    /* Explicitly hold the list lock while taking the StateLock in case the
     * device is asynchronously destroyed, to ensure this new context is
     * properly cleaned up after being made.
     */
    std::unique_lock<std::recursive_mutex> listlock{ListLock};
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type == DeviceType::Capture || !dev->Connected.load(std::memory_order_relaxed))
    {
        listlock.unlock();
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
        return nullptr;
    }
    std::unique_lock<std::mutex> statelock{dev->StateLock};
    listlock.unlock();

    dev->LastError.store(ALC_NO_ERROR);

    ALCenum err{UpdateDeviceParams(dev.get(), attrList)};
    if(err != ALC_NO_ERROR)
    {
        alcSetError(dev.get(), err);
        return nullptr;
    }

    ContextRef context{new ALCcontext{dev}};
    context->init();

    if(auto volopt = ConfigValueFloat(dev->DeviceName.c_str(), nullptr, "volume-adjust"))
    {
        const float valf{*volopt};
        if(!std::isfinite(valf))
            ERR("volume-adjust must be finite: %f\n", valf);
        else
        {
            const float db{clampf(valf, -24.0f, 24.0f)};
            if(db != valf)
                WARN("volume-adjust clamped: %f, range: +/-%f\n", valf, 24.0f);
            context->mGainBoost = std::pow(10.0f, db/20.0f);
            TRACE("volume-adjust gain: %f\n", context->mGainBoost);
        }
    }
    UpdateListenerProps(context.get());

    {
        using ContextArray = al::FlexArray<ALCcontext*>;

        /* Allocate a new context array, which holds 1 more than the current/
         * old array.
         */
        auto *oldarray = device->mContexts.load();
        const size_t newcount{oldarray->size()+1};
        std::unique_ptr<ContextArray> newarray{ContextArray::Create(newcount)};

        /* Copy the current/old context handles to the new array, appending the
         * new context.
         */
        auto iter = std::copy(oldarray->begin(), oldarray->end(), newarray->begin());
        *iter = context.get();

        /* Store the new context array in the device. Wait for any current mix
         * to finish before deleting the old array.
         */
        dev->mContexts.store(newarray.release());
        if(oldarray != &EmptyContextArray)
        {
            dev->waitForMix();
            delete oldarray;
        }
    }
    statelock.unlock();

    {
        std::lock_guard<std::recursive_mutex> _{ListLock};
        auto iter = std::lower_bound(ContextList.cbegin(), ContextList.cend(), context.get());
        ContextList.emplace(iter, context.get());
    }

    if(ALeffectslot *slot{context->mDefaultSlot.get()})
    {
        if(slot->initEffect(&DefaultEffect, context.get()) == AL_NO_ERROR)
            slot->updateProps(context.get());
        else
            ERR("Failed to initialize the default effect\n");
    }

    TRACE("Created context %p\n", decltype(std::declval<void*>()){context.get()});
    return context.release();
}
END_API_FUNC

ALC_API void ALC_APIENTRY alcDestroyContext(ALCcontext *context)
START_API_FUNC
{
    std::unique_lock<std::recursive_mutex> listlock{ListLock};
    auto iter = std::lower_bound(ContextList.begin(), ContextList.end(), context);
    if(iter == ContextList.end() || *iter != context)
    {
        listlock.unlock();
        alcSetError(nullptr, ALC_INVALID_CONTEXT);
        return;
    }
    /* Hold a reference to this context so it remains valid until the ListLock
     * is released.
     */
    ContextRef ctx{*iter};
    ContextList.erase(iter);

    ALCdevice *Device{ctx->mDevice.get()};

    std::lock_guard<std::mutex> _{Device->StateLock};
    if(!ctx->deinit() && Device->Flags.get<DeviceRunning>())
    {
        Device->Backend->stop();
        Device->Flags.unset<DeviceRunning>();
    }
}
END_API_FUNC


ALC_API ALCcontext* ALC_APIENTRY alcGetCurrentContext(void)
START_API_FUNC
{
    ALCcontext *Context{LocalContext};
    if(!Context) Context = GlobalContext.load();
    return Context;
}
END_API_FUNC

/** Returns the currently active thread-local context. */
ALC_API ALCcontext* ALC_APIENTRY alcGetThreadContext(void)
START_API_FUNC
{ return LocalContext; }
END_API_FUNC

ALC_API ALCboolean ALC_APIENTRY alcMakeContextCurrent(ALCcontext *context)
START_API_FUNC
{
    /* context must be valid or nullptr */
    ContextRef ctx;
    if(context)
    {
        ctx = VerifyContext(context);
        if(!ctx)
        {
            alcSetError(nullptr, ALC_INVALID_CONTEXT);
            return ALC_FALSE;
        }
    }
    /* Release this reference (if any) to store it in the GlobalContext
     * pointer. Take ownership of the reference (if any) that was previously
     * stored there.
     */
    ctx = ContextRef{GlobalContext.exchange(ctx.release())};

    /* Reset (decrement) the previous global reference by replacing it with the
     * thread-local context. Take ownership of the thread-local context
     * reference (if any), clearing the storage to null.
     */
    ctx = ContextRef{LocalContext};
    if(ctx) ThreadContext.set(nullptr);
    /* Reset (decrement) the previous thread-local reference. */

    return ALC_TRUE;
}
END_API_FUNC

/** Makes the given context the active context for the current thread. */
ALC_API ALCboolean ALC_APIENTRY alcSetThreadContext(ALCcontext *context)
START_API_FUNC
{
    /* context must be valid or nullptr */
    ContextRef ctx;
    if(context)
    {
        ctx = VerifyContext(context);
        if(!ctx)
        {
            alcSetError(nullptr, ALC_INVALID_CONTEXT);
            return ALC_FALSE;
        }
    }
    /* context's reference count is already incremented */
    ContextRef old{LocalContext};
    ThreadContext.set(ctx.release());

    return ALC_TRUE;
}
END_API_FUNC


ALC_API ALCdevice* ALC_APIENTRY alcGetContextsDevice(ALCcontext *Context)
START_API_FUNC
{
    ContextRef ctx{VerifyContext(Context)};
    if(!ctx)
    {
        alcSetError(nullptr, ALC_INVALID_CONTEXT);
        return nullptr;
    }
    return ctx->mDevice.get();
}
END_API_FUNC


ALC_API ALCdevice* ALC_APIENTRY alcOpenDevice(const ALCchar *deviceName)
START_API_FUNC
{
    DO_INITCONFIG();

    if(!PlaybackFactory)
    {
        alcSetError(nullptr, ALC_INVALID_VALUE);
        return nullptr;
    }

    if(deviceName)
    {
        if(!deviceName[0] || al::strcasecmp(deviceName, alcDefaultName) == 0
#ifdef _WIN32
            /* Some old Windows apps hardcode these expecting OpenAL to use a
             * specific audio API, even when they're not enumerated. Creative's
             * router effectively ignores them too.
             */
            || al::strcasecmp(deviceName, "DirectSound3D") == 0
            || al::strcasecmp(deviceName, "DirectSound") == 0
            || al::strcasecmp(deviceName, "MMSYSTEM") == 0
#endif
            || al::strcasecmp(deviceName, "openal-soft") == 0)
            deviceName = nullptr;
    }

    DeviceRef device{new ALCdevice{DeviceType::Playback}};

    /* Set output format */
    device->FmtChans = DevFmtChannelsDefault;
    device->FmtType = DevFmtTypeDefault;
    device->Frequency = DEFAULT_OUTPUT_RATE;
    device->UpdateSize = DEFAULT_UPDATE_SIZE;
    device->BufferSize = DEFAULT_UPDATE_SIZE * DEFAULT_NUM_UPDATES;

    device->SourcesMax = 256;
    device->AuxiliaryEffectSlotMax = 64;
    device->NumAuxSends = DEFAULT_SENDS;

    try {
        auto backend = PlaybackFactory->createBackend(device.get(), BackendType::Playback);
        std::lock_guard<std::recursive_mutex> _{ListLock};
        backend->open(deviceName);
        device->Backend = std::move(backend);
    }
    catch(al::backend_exception &e) {
        WARN("Failed to open playback device: %s\n", e.what());
        alcSetError(nullptr, e.errorCode());
        return nullptr;
    }

    deviceName = device->DeviceName.c_str();
    if(auto chanopt = ConfigValueStr(deviceName, nullptr, "channels"))
    {
        static const struct ChannelMap {
            const char name[16];
            DevFmtChannels chans;
            ALuint order;
        } chanlist[] = {
            { "mono",       DevFmtMono,   0 },
            { "stereo",     DevFmtStereo, 0 },
            { "quad",       DevFmtQuad,   0 },
            { "surround51", DevFmtX51,    0 },
            { "surround61", DevFmtX61,    0 },
            { "surround71", DevFmtX71,    0 },
            { "surround51rear", DevFmtX51Rear, 0 },
            { "ambi1", DevFmtAmbi3D, 1 },
            { "ambi2", DevFmtAmbi3D, 2 },
            { "ambi3", DevFmtAmbi3D, 3 },
        };

        const ALCchar *fmt{chanopt->c_str()};
        auto iter = std::find_if(std::begin(chanlist), std::end(chanlist),
            [fmt](const ChannelMap &entry) -> bool
            { return al::strcasecmp(entry.name, fmt) == 0; }
        );
        if(iter == std::end(chanlist))
            ERR("Unsupported channels: %s\n", fmt);
        else
        {
            device->FmtChans = iter->chans;
            device->mAmbiOrder = iter->order;
            device->Flags.set<ChannelsRequest>();
        }
    }
    if(auto typeopt = ConfigValueStr(deviceName, nullptr, "sample-type"))
    {
        static const struct TypeMap {
            const char name[16];
            DevFmtType type;
        } typelist[] = {
            { "int8",    DevFmtByte   },
            { "uint8",   DevFmtUByte  },
            { "int16",   DevFmtShort  },
            { "uint16",  DevFmtUShort },
            { "int32",   DevFmtInt    },
            { "uint32",  DevFmtUInt   },
            { "float32", DevFmtFloat  },
        };

        const ALCchar *fmt{typeopt->c_str()};
        auto iter = std::find_if(std::begin(typelist), std::end(typelist),
            [fmt](const TypeMap &entry) -> bool
            { return al::strcasecmp(entry.name, fmt) == 0; }
        );
        if(iter == std::end(typelist))
            ERR("Unsupported sample-type: %s\n", fmt);
        else
        {
            device->FmtType = iter->type;
            device->Flags.set<SampleTypeRequest>();
        }
    }

    if(ALuint freq{ConfigValueUInt(deviceName, nullptr, "frequency").value_or(0)})
    {
        if(freq < MIN_OUTPUT_RATE || freq > MAX_OUTPUT_RATE)
        {
            const ALuint newfreq{clampu(freq, MIN_OUTPUT_RATE, MAX_OUTPUT_RATE)};
            ERR("%uhz request clamped to %uhz\n", freq, newfreq);
            freq = newfreq;
        }
        const double scale{static_cast<double>(freq) / device->Frequency};
        device->UpdateSize = static_cast<ALuint>(device->UpdateSize*scale + 0.5);
        device->BufferSize = static_cast<ALuint>(device->BufferSize*scale + 0.5);
        device->Frequency = freq;
        device->Flags.set<FrequencyRequest>();
    }

    if(auto persizeopt = ConfigValueUInt(deviceName, nullptr, "period_size"))
        device->UpdateSize = clampu(*persizeopt, 64, 8192);

    if(auto peropt = ConfigValueUInt(deviceName, nullptr, "periods"))
        device->BufferSize = device->UpdateSize * clampu(*peropt, 2, 16);
    else
        device->BufferSize = maxu(device->BufferSize, device->UpdateSize*2);

    if(auto srcsmax = ConfigValueUInt(deviceName, nullptr, "sources").value_or(0))
        device->SourcesMax = srcsmax;

    if(auto slotsmax = ConfigValueUInt(deviceName, nullptr, "slots").value_or(0))
        device->AuxiliaryEffectSlotMax = minu(slotsmax, INT_MAX);

    if(auto sendsopt = ConfigValueInt(deviceName, nullptr, "sends"))
        device->NumAuxSends = minu(DEFAULT_SENDS,
            static_cast<ALuint>(clampi(*sendsopt, 0, MAX_SENDS)));

    device->NumStereoSources = 1;
    device->NumMonoSources = device->SourcesMax - device->NumStereoSources;

    if(auto ambiopt = ConfigValueStr(deviceName, nullptr, "ambi-format"))
    {
        const ALCchar *fmt{ambiopt->c_str()};
        if(al::strcasecmp(fmt, "fuma") == 0)
        {
            if(device->mAmbiOrder > 3)
                ERR("FuMa is incompatible with %d%s order ambisonics (up to third-order only)\n",
                    device->mAmbiOrder,
                    (((device->mAmbiOrder%100)/10) == 1) ? "th" :
                    ((device->mAmbiOrder%10) == 1) ? "st" :
                    ((device->mAmbiOrder%10) == 2) ? "nd" :
                    ((device->mAmbiOrder%10) == 3) ? "rd" : "th");
            else
            {
                device->mAmbiLayout = DevAmbiLayout::FuMa;
                device->mAmbiScale = DevAmbiScaling::FuMa;
            }
        }
        else if(al::strcasecmp(fmt, "ambix") == 0 || al::strcasecmp(fmt, "acn+sn3d") == 0)
        {
            device->mAmbiLayout = DevAmbiLayout::ACN;
            device->mAmbiScale = DevAmbiScaling::SN3D;
        }
        else if(al::strcasecmp(fmt, "acn+n3d") == 0)
        {
            device->mAmbiLayout = DevAmbiLayout::ACN;
            device->mAmbiScale = DevAmbiScaling::N3D;
        }
        else
            ERR("Unsupported ambi-format: %s\n", fmt);
    }

    {
        std::lock_guard<std::recursive_mutex> _{ListLock};
        auto iter = std::lower_bound(DeviceList.cbegin(), DeviceList.cend(), device.get());
        DeviceList.emplace(iter, device.get());
    }

    TRACE("Created device %p, \"%s\"\n", decltype(std::declval<void*>()){device.get()},
        device->DeviceName.c_str());
    return device.release();
}
END_API_FUNC

ALC_API ALCboolean ALC_APIENTRY alcCloseDevice(ALCdevice *device)
START_API_FUNC
{
    std::unique_lock<std::recursive_mutex> listlock{ListLock};
    auto iter = std::lower_bound(DeviceList.begin(), DeviceList.end(), device);
    if(iter == DeviceList.end() || *iter != device)
    {
        alcSetError(nullptr, ALC_INVALID_DEVICE);
        return ALC_FALSE;
    }
    if((*iter)->Type == DeviceType::Capture)
    {
        alcSetError(*iter, ALC_INVALID_DEVICE);
        return ALC_FALSE;
    }

    /* Erase the device, and any remaining contexts left on it, from their
     * respective lists.
     */
    DeviceRef dev{*iter};
    DeviceList.erase(iter);

    std::unique_lock<std::mutex> statelock{dev->StateLock};
    al::vector<ContextRef> orphanctxs;
    for(ALCcontext *ctx : *dev->mContexts.load())
    {
        auto ctxiter = std::lower_bound(ContextList.begin(), ContextList.end(), ctx);
        if(ctxiter != ContextList.end() && *ctxiter == ctx)
        {
            orphanctxs.emplace_back(ContextRef{*ctxiter});
            ContextList.erase(ctxiter);
        }
    }
    listlock.unlock();

    for(ContextRef &context : orphanctxs)
    {
        WARN("Releasing orphaned context %p\n", decltype(std::declval<void*>()){context.get()});
        context->deinit();
    }
    orphanctxs.clear();

    if(dev->Flags.get<DeviceRunning>())
        dev->Backend->stop();
    dev->Flags.unset<DeviceRunning>();

    return ALC_TRUE;
}
END_API_FUNC


/************************************************
 * ALC capture functions
 ************************************************/
ALC_API ALCdevice* ALC_APIENTRY alcCaptureOpenDevice(const ALCchar *deviceName, ALCuint frequency, ALCenum format, ALCsizei samples)
START_API_FUNC
{
    DO_INITCONFIG();

    if(!CaptureFactory)
    {
        alcSetError(nullptr, ALC_INVALID_VALUE);
        return nullptr;
    }

    if(samples <= 0)
    {
        alcSetError(nullptr, ALC_INVALID_VALUE);
        return nullptr;
    }

    if(deviceName)
    {
        if(!deviceName[0] || al::strcasecmp(deviceName, alcDefaultName) == 0
            || al::strcasecmp(deviceName, "openal-soft") == 0)
            deviceName = nullptr;
    }

    DeviceRef device{new ALCdevice{DeviceType::Capture}};

    auto decompfmt = DecomposeDevFormat(format);
    if(!decompfmt)
    {
        alcSetError(nullptr, ALC_INVALID_ENUM);
        return nullptr;
    }

    device->Frequency = frequency;
    device->FmtChans = decompfmt->chans;
    device->FmtType = decompfmt->type;
    device->Flags.set<FrequencyRequest, ChannelsRequest, SampleTypeRequest>();

    device->UpdateSize = static_cast<ALuint>(samples);
    device->BufferSize = static_cast<ALuint>(samples);

    try {
        TRACE("Capture format: %s, %s, %uhz, %u / %u buffer\n",
            DevFmtChannelsString(device->FmtChans), DevFmtTypeString(device->FmtType),
            device->Frequency, device->UpdateSize, device->BufferSize);

        auto backend = CaptureFactory->createBackend(device.get(), BackendType::Capture);
        std::lock_guard<std::recursive_mutex> _{ListLock};
        backend->open(deviceName);
        device->Backend = std::move(backend);
    }
    catch(al::backend_exception &e) {
        WARN("Failed to open capture device: %s\n", e.what());
        alcSetError(nullptr, e.errorCode());
        return nullptr;
    }

    {
        std::lock_guard<std::recursive_mutex> _{ListLock};
        auto iter = std::lower_bound(DeviceList.cbegin(), DeviceList.cend(), device.get());
        DeviceList.emplace(iter, device.get());
    }

    TRACE("Created capture device %p, \"%s\"\n", decltype(std::declval<void*>()){device.get()},
        device->DeviceName.c_str());
    return device.release();
}
END_API_FUNC

ALC_API ALCboolean ALC_APIENTRY alcCaptureCloseDevice(ALCdevice *device)
START_API_FUNC
{
    std::unique_lock<std::recursive_mutex> listlock{ListLock};
    auto iter = std::lower_bound(DeviceList.begin(), DeviceList.end(), device);
    if(iter == DeviceList.end() || *iter != device)
    {
        alcSetError(nullptr, ALC_INVALID_DEVICE);
        return ALC_FALSE;
    }
    if((*iter)->Type != DeviceType::Capture)
    {
        alcSetError(*iter, ALC_INVALID_DEVICE);
        return ALC_FALSE;
    }

    DeviceRef dev{*iter};
    DeviceList.erase(iter);
    listlock.unlock();

    std::lock_guard<std::mutex> _{dev->StateLock};
    if(dev->Flags.get<DeviceRunning>())
        dev->Backend->stop();
    dev->Flags.unset<DeviceRunning>();

    return ALC_TRUE;
}
END_API_FUNC

ALC_API void ALC_APIENTRY alcCaptureStart(ALCdevice *device)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Capture)
    {
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
        return;
    }

    std::lock_guard<std::mutex> _{dev->StateLock};
    if(!dev->Connected.load(std::memory_order_acquire))
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    else if(!dev->Flags.get<DeviceRunning>())
    {
        try {
            auto backend = dev->Backend.get();
            backend->start();
            dev->Flags.set<DeviceRunning>();
        }
        catch(al::backend_exception& e) {
            dev->handleDisconnect("%s", e.what());
            alcSetError(dev.get(), ALC_INVALID_DEVICE);
        }
    }
}
END_API_FUNC

ALC_API void ALC_APIENTRY alcCaptureStop(ALCdevice *device)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Capture)
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    else
    {
        std::lock_guard<std::mutex> _{dev->StateLock};
        if(dev->Flags.get<DeviceRunning>())
            dev->Backend->stop();
        dev->Flags.unset<DeviceRunning>();
    }
}
END_API_FUNC

ALC_API void ALC_APIENTRY alcCaptureSamples(ALCdevice *device, ALCvoid *buffer, ALCsizei samples)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Capture)
    {
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
        return;
    }

    if(samples < 0 || (samples > 0 && buffer == nullptr))
    {
        alcSetError(dev.get(), ALC_INVALID_VALUE);
        return;
    }
    if(samples < 1)
        return;

    std::lock_guard<std::mutex> _{dev->StateLock};
    BackendBase *backend{dev->Backend.get()};

    const auto usamples = static_cast<ALCuint>(samples);
    if(usamples > backend->availableSamples())
    {
        alcSetError(dev.get(), ALC_INVALID_VALUE);
        return;
    }

    auto *bbuffer = static_cast<al::byte*>(buffer);
    if(ALCenum err{backend->captureSamples(bbuffer, usamples)})
        alcSetError(dev.get(), err);
}
END_API_FUNC


/************************************************
 * ALC loopback functions
 ************************************************/

/** Open a loopback device, for manual rendering. */
ALC_API ALCdevice* ALC_APIENTRY alcLoopbackOpenDeviceSOFT(const ALCchar *deviceName)
START_API_FUNC
{
    DO_INITCONFIG();

    /* Make sure the device name, if specified, is us. */
    if(deviceName && strcmp(deviceName, alcDefaultName) != 0)
    {
        alcSetError(nullptr, ALC_INVALID_VALUE);
        return nullptr;
    }

    DeviceRef device{new ALCdevice{DeviceType::Loopback}};

    device->SourcesMax = 256;
    device->AuxiliaryEffectSlotMax = 64;
    device->NumAuxSends = DEFAULT_SENDS;

    //Set output format
    device->BufferSize = 0;
    device->UpdateSize = 0;

    device->Frequency = DEFAULT_OUTPUT_RATE;
    device->FmtChans = DevFmtChannelsDefault;
    device->FmtType = DevFmtTypeDefault;

    if(auto srcsmax = ConfigValueUInt(nullptr, nullptr, "sources").value_or(0))
        device->SourcesMax = srcsmax;

    if(auto slotsmax = ConfigValueUInt(nullptr, nullptr, "slots").value_or(0))
        device->AuxiliaryEffectSlotMax = minu(slotsmax, INT_MAX);

    if(auto sendsopt = ConfigValueInt(nullptr, nullptr, "sends"))
        device->NumAuxSends = minu(DEFAULT_SENDS,
            static_cast<ALuint>(clampi(*sendsopt, 0, MAX_SENDS)));

    device->NumStereoSources = 1;
    device->NumMonoSources = device->SourcesMax - device->NumStereoSources;

    try {
        auto backend = LoopbackBackendFactory::getFactory().createBackend(device.get(),
            BackendType::Playback);
        backend->open("Loopback");
        device->Backend = std::move(backend);
    }
    catch(al::backend_exception &e) {
        WARN("Failed to open loopback device: %s\n", e.what());
        alcSetError(nullptr, e.errorCode());
        return nullptr;
    }

    {
        std::lock_guard<std::recursive_mutex> _{ListLock};
        auto iter = std::lower_bound(DeviceList.cbegin(), DeviceList.cend(), device.get());
        DeviceList.emplace(iter, device.get());
    }

    TRACE("Created loopback device %p\n", decltype(std::declval<void*>()){device.get()});
    return device.release();
}
END_API_FUNC

/**
 * Determines if the loopback device supports the given format for rendering.
 */
ALC_API ALCboolean ALC_APIENTRY alcIsRenderFormatSupportedSOFT(ALCdevice *device, ALCsizei freq, ALCenum channels, ALCenum type)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Loopback)
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    else if(freq <= 0)
        alcSetError(dev.get(), ALC_INVALID_VALUE);
    else
    {
        if(IsValidALCType(type) && IsValidALCChannels(channels) && freq >= MIN_OUTPUT_RATE
            && freq <= MAX_OUTPUT_RATE)
            return ALC_TRUE;
    }

    return ALC_FALSE;
}
END_API_FUNC

/**
 * Renders some samples into a buffer, using the format last set by the
 * attributes given to alcCreateContext.
 */
FORCE_ALIGN ALC_API void ALC_APIENTRY alcRenderSamplesSOFT(ALCdevice *device, ALCvoid *buffer, ALCsizei samples)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Loopback)
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    else if(samples < 0 || (samples > 0 && buffer == nullptr))
        alcSetError(dev.get(), ALC_INVALID_VALUE);
    else
        dev->renderSamples(buffer, static_cast<ALuint>(samples), dev->channelsFromFmt());
}
END_API_FUNC


/************************************************
 * ALC DSP pause/resume functions
 ************************************************/

/** Pause the DSP to stop audio processing. */
ALC_API void ALC_APIENTRY alcDevicePauseSOFT(ALCdevice *device)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Playback)
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    else
    {
        std::lock_guard<std::mutex> _{dev->StateLock};
        if(dev->Flags.get<DeviceRunning>())
            dev->Backend->stop();
        dev->Flags.unset<DeviceRunning>();
        dev->Flags.set<DevicePaused>();
    }
}
END_API_FUNC

/** Resume the DSP to restart audio processing. */
ALC_API void ALC_APIENTRY alcDeviceResumeSOFT(ALCdevice *device)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type != DeviceType::Playback)
    {
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
        return;
    }

    std::lock_guard<std::mutex> _{dev->StateLock};
    if(!dev->Flags.get<DevicePaused>())
        return;
    dev->Flags.unset<DevicePaused>();
    if(dev->mContexts.load()->empty())
        return;

    try {
        auto backend = dev->Backend.get();
        backend->start();
        dev->Flags.set<DeviceRunning>();
    }
    catch(al::backend_exception& e) {
        dev->handleDisconnect("%s", e.what());
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    }
}
END_API_FUNC


/************************************************
 * ALC HRTF functions
 ************************************************/

/** Gets a string parameter at the given index. */
ALC_API const ALCchar* ALC_APIENTRY alcGetStringiSOFT(ALCdevice *device, ALCenum paramName, ALCsizei index)
START_API_FUNC
{
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type == DeviceType::Capture)
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
    else switch(paramName)
    {
        case ALC_HRTF_SPECIFIER_SOFT:
            if(index >= 0 && static_cast<size_t>(index) < dev->HrtfList.size())
                return dev->HrtfList[static_cast<ALuint>(index)].c_str();
            alcSetError(dev.get(), ALC_INVALID_VALUE);
            break;

        default:
            alcSetError(dev.get(), ALC_INVALID_ENUM);
            break;
    }

    return nullptr;
}
END_API_FUNC

/** Resets the given device output, using the specified attribute list. */
ALC_API ALCboolean ALC_APIENTRY alcResetDeviceSOFT(ALCdevice *device, const ALCint *attribs)
START_API_FUNC
{
    std::unique_lock<std::recursive_mutex> listlock{ListLock};
    DeviceRef dev{VerifyDevice(device)};
    if(!dev || dev->Type == DeviceType::Capture)
    {
        listlock.unlock();
        alcSetError(dev.get(), ALC_INVALID_DEVICE);
        return ALC_FALSE;
    }
    std::lock_guard<std::mutex> _{dev->StateLock};
    listlock.unlock();

    /* Force the backend to stop mixing first since we're resetting. Also reset
     * the connected state so lost devices can attempt recover.
     */
    if(dev->Flags.get<DeviceRunning>())
        dev->Backend->stop();
    dev->Flags.unset<DeviceRunning>();
    if(!dev->Connected.load(std::memory_order_relaxed))
    {
        /* Make sure disconnection is finished before continuing on. */
        dev->waitForMix();

        for(ALCcontext *ctx : *dev->mContexts.load(std::memory_order_acquire))
        {
            /* Clear any pending voice changes and reallocate voices to get a
             * clean restart.
             */
            std::lock_guard<std::mutex> __{ctx->mSourceLock};
            auto *vchg = ctx->mCurrentVoiceChange.load(std::memory_order_acquire);
            while(auto *next = vchg->mNext.load(std::memory_order_acquire))
                vchg = next;
            ctx->mCurrentVoiceChange.store(vchg, std::memory_order_release);

            ctx->mVoiceClusters.clear();
            ctx->allocVoices(std::max<size_t>(256,
                ctx->mActiveVoiceCount.load(std::memory_order_relaxed)));
        }

        dev->Connected.store(true);
    }

    ALCenum err{UpdateDeviceParams(dev.get(), attribs)};
    if LIKELY(err == ALC_NO_ERROR) return ALC_TRUE;

    alcSetError(dev.get(), err);
    return ALC_FALSE;
}
END_API_FUNC
