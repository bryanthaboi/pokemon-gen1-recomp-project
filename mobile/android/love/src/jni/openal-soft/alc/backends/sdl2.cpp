/**
 * OpenAL cross platform audio library
 * Copyright (C) 2018 by authors.
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

#include "backends/sdl2.h"

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <string>

#include "AL/al.h"

#include "alcmain.h"
#include "alexcpt.h"
#include "almalloc.h"
#include "alu.h"
#include "logging.h"

#include <SDL2/SDL.h>


namespace {

#ifdef _WIN32
#define DEVNAME_PREFIX "OpenAL Soft on "
#else
#define DEVNAME_PREFIX ""
#endif

constexpr ALCchar defaultDeviceName[] = DEVNAME_PREFIX "Default Device";

struct Sdl2Backend final : public BackendBase {
    Sdl2Backend(ALCdevice *device) noexcept : BackendBase{device} { }
    ~Sdl2Backend() override;

    void audioCallback(Uint8 *stream, int len) noexcept;
    static void audioCallbackC(void *ptr, Uint8 *stream, int len) noexcept
    { static_cast<Sdl2Backend*>(ptr)->audioCallback(stream, len); }

    void open(const ALCchar *name) override;
    bool reset() override;
    void start() override;
    void stop() override;

    SDL_AudioDeviceID mDeviceID{0u};
    ALuint mFrameSize{0};

    ALuint mFrequency{0u};
    DevFmtChannels mFmtChans{};
    DevFmtType     mFmtType{};
    ALuint mUpdateSize{0u};

    DEF_NEWDEL(Sdl2Backend)
};

Sdl2Backend::~Sdl2Backend()
{
    if(mDeviceID)
        SDL_CloseAudioDevice(mDeviceID);
    mDeviceID = 0;
}

void Sdl2Backend::audioCallback(Uint8 *stream, int len) noexcept
{
    const auto ulen = static_cast<unsigned int>(len);
    assert((ulen % mFrameSize) == 0);
    mDevice->renderSamples(stream, ulen / mFrameSize, mDevice->channelsFromFmt());
}

void Sdl2Backend::open(const ALCchar *name)
{
    SDL_AudioSpec want{}, have{};

    want.freq = static_cast<int>(mDevice->Frequency);
    switch(mDevice->FmtType)
    {
    case DevFmtUByte: want.format = AUDIO_U8; break;
    case DevFmtByte: want.format = AUDIO_S8; break;
    case DevFmtUShort: want.format = AUDIO_U16SYS; break;
    case DevFmtShort: want.format = AUDIO_S16SYS; break;
    case DevFmtUInt: /* fall-through */
    case DevFmtInt: want.format = AUDIO_S32SYS; break;
    case DevFmtFloat: want.format = AUDIO_F32; break;
    }
    want.channels = (mDevice->FmtChans == DevFmtMono) ? 1 : 2;
    want.samples = static_cast<Uint16>(mDevice->UpdateSize);
    want.callback = &Sdl2Backend::audioCallbackC;
    want.userdata = this;

    /* Passing nullptr to SDL_OpenAudioDevice opens a default, which isn't
     * necessarily the first in the list.
     */
    if(!name || strcmp(name, defaultDeviceName) == 0)
        mDeviceID = SDL_OpenAudioDevice(nullptr, SDL_FALSE, &want, &have,
            SDL_AUDIO_ALLOW_ANY_CHANGE);
    else
    {
        const size_t prefix_len = strlen(DEVNAME_PREFIX);
        if(strncmp(name, DEVNAME_PREFIX, prefix_len) == 0)
            mDeviceID = SDL_OpenAudioDevice(name+prefix_len, SDL_FALSE, &want, &have,
                SDL_AUDIO_ALLOW_ANY_CHANGE);
        else
            mDeviceID = SDL_OpenAudioDevice(name, SDL_FALSE, &want, &have,
                SDL_AUDIO_ALLOW_ANY_CHANGE);
    }
    if(mDeviceID == 0)
        throw al::backend_exception{ALC_INVALID_VALUE, "%s", SDL_GetError()};

    mDevice->Frequency = static_cast<ALuint>(have.freq);

    if(have.channels == 1)
        mDevice->FmtChans = DevFmtMono;
    else if(have.channels == 2)
        mDevice->FmtChans = DevFmtStereo;
    else
        throw al::backend_exception{ALC_INVALID_VALUE, "Unhandled SDL channel count: %d",
            int{have.channels}};

    switch(have.format)
    {
    case AUDIO_U8:     mDevice->FmtType = DevFmtUByte;  break;
    case AUDIO_S8:     mDevice->FmtType = DevFmtByte;   break;
    case AUDIO_U16SYS: mDevice->FmtType = DevFmtUShort; break;
    case AUDIO_S16SYS: mDevice->FmtType = DevFmtShort;  break;
    case AUDIO_S32SYS: mDevice->FmtType = DevFmtInt;    break;
    case AUDIO_F32SYS: mDevice->FmtType = DevFmtFloat;  break;
    default:
        throw al::backend_exception{ALC_INVALID_VALUE, "Unhandled SDL format: 0x%04x",
            have.format};
    }
    mDevice->UpdateSize = have.samples;
    mDevice->BufferSize = have.samples * 2; /* SDL always (tries to) use two periods. */

    mFrameSize = mDevice->frameSizeFromFmt();
    mFrequency = mDevice->Frequency;
    mFmtChans = mDevice->FmtChans;
    mFmtType = mDevice->FmtType;
    mUpdateSize = mDevice->UpdateSize;

    mDevice->DeviceName = name ? name : defaultDeviceName;
}

bool Sdl2Backend::reset()
{
    mDevice->Frequency = mFrequency;
    mDevice->FmtChans = mFmtChans;
    mDevice->FmtType = mFmtType;
    mDevice->UpdateSize = mUpdateSize;
    mDevice->BufferSize = mUpdateSize * 2;
    setDefaultWFXChannelOrder();
    return true;
}

void Sdl2Backend::start()
{ SDL_PauseAudioDevice(mDeviceID, 0); }

void Sdl2Backend::stop()
{ SDL_PauseAudioDevice(mDeviceID, 1); }

} // namespace

BackendFactory &SDL2BackendFactory::getFactory()
{
    static SDL2BackendFactory factory{};
    return factory;
}

bool SDL2BackendFactory::init()
{ return (SDL_InitSubSystem(SDL_INIT_AUDIO) == 0); }

bool SDL2BackendFactory::querySupport(BackendType type)
{ return type == BackendType::Playback; }

std::string SDL2BackendFactory::probe(BackendType type)
{
    std::string outnames;

    if(type != BackendType::Playback)
        return outnames;

    int num_devices{SDL_GetNumAudioDevices(SDL_FALSE)};

    /* Includes null char. */
    outnames.append(defaultDeviceName, sizeof(defaultDeviceName));
    for(int i{0};i < num_devices;++i)
    {
        std::string name{DEVNAME_PREFIX};
        name += SDL_GetAudioDeviceName(i, SDL_FALSE);
        if(!name.empty())
            outnames.append(name.c_str(), name.length()+1);
    }
    return outnames;
}

BackendPtr SDL2BackendFactory::createBackend(ALCdevice *device, BackendType type)
{
    if(type == BackendType::Playback)
        return BackendPtr{new Sdl2Backend{device}};
    return nullptr;
}
