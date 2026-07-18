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

#include "backends/solaris.h"

#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <memory.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <math.h>

#include <thread>
#include <functional>

#include "alcmain.h"
#include "alexcpt.h"
#include "alu.h"
#include "alconfig.h"
#include "compat.h"
#include "logging.h"
#include "threads.h"
#include "vector.h"

#include <sys/audioio.h>


namespace {

constexpr ALCchar solaris_device[] = "Solaris Default";

std::string solaris_driver{"/dev/audio"};


struct SolarisBackend final : public BackendBase {
    SolarisBackend(ALCdevice *device) noexcept : BackendBase{device} { }
    ~SolarisBackend() override;

    int mixerProc();

    void open(const ALCchar *name) override;
    bool reset() override;
    void start() override;
    void stop() override;

    int mFd{-1};

    al::vector<ALubyte> mBuffer;

    std::atomic<bool> mKillNow{true};
    std::thread mThread;

    DEF_NEWDEL(SolarisBackend)
};

SolarisBackend::~SolarisBackend()
{
    if(mFd != -1)
        close(mFd);
    mFd = -1;
}

int SolarisBackend::mixerProc()
{
    SetRTPriority();
    althrd_setname(MIXER_THREAD_NAME);

    const size_t frame_step{mDevice->channelsFromFmt()};
    const ALuint frame_size{mDevice->frameSizeFromFmt()};

    while(!mKillNow.load(std::memory_order_acquire) &&
          mDevice->Connected.load(std::memory_order_acquire))
    {
        pollfd pollitem{};
        pollitem.fd = mFd;
        pollitem.events = POLLOUT;

        int pret{poll(&pollitem, 1, 1000)};
        if(pret < 0)
        {
            if(errno == EINTR || errno == EAGAIN)
                continue;
            ERR("poll failed: %s\n", strerror(errno));
            mDevice->handleDisconnect("Failed to wait for playback buffer: %s", strerror(errno));
            break;
        }
        else if(pret == 0)
        {
            WARN("poll timeout\n");
            continue;
        }

        ALubyte *write_ptr{mBuffer.data()};
        size_t to_write{mBuffer.size()};
        mDevice->renderSamples(write_ptr, static_cast<ALuint>(to_write/frame_size), frame_step);
        while(to_write > 0 && !mKillNow.load(std::memory_order_acquire))
        {
            ssize_t wrote{write(mFd, write_ptr, to_write)};
            if(wrote < 0)
            {
                if(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                    continue;
                ERR("write failed: %s\n", strerror(errno));
                mDevice->handleDisconnect("Failed to write playback samples: %s", strerror(errno));
                break;
            }

            to_write -= static_cast<size_t>(wrote);
            write_ptr += wrote;
        }
    }

    return 0;
}


void SolarisBackend::open(const ALCchar *name)
{
    if(!name)
        name = solaris_device;
    else if(strcmp(name, solaris_device) != 0)
        throw al::backend_exception{ALC_INVALID_VALUE, "Device name \"%s\" not found", name};

    mFd = ::open(solaris_driver.c_str(), O_WRONLY);
    if(mFd == -1)
        throw al::backend_exception{ALC_INVALID_VALUE, "Could not open %s: %s",
            solaris_driver.c_str(), strerror(errno)};

    mDevice->DeviceName = name;
}

bool SolarisBackend::reset()
{
    audio_info_t info;
    AUDIO_INITINFO(&info);

    info.play.sample_rate = mDevice->Frequency;

    if(mDevice->FmtChans != DevFmtMono)
        mDevice->FmtChans = DevFmtStereo;
    ALuint numChannels{mDevice->channelsFromFmt()};
    info.play.channels = numChannels;

    switch(mDevice->FmtType)
    {
        case DevFmtByte:
            info.play.precision = 8;
            info.play.encoding = AUDIO_ENCODING_LINEAR;
            break;
        case DevFmtUByte:
            info.play.precision = 8;
            info.play.encoding = AUDIO_ENCODING_LINEAR8;
            break;
        case DevFmtUShort:
        case DevFmtInt:
        case DevFmtUInt:
        case DevFmtFloat:
            mDevice->FmtType = DevFmtShort;
            /* fall-through */
        case DevFmtShort:
            info.play.precision = 16;
            info.play.encoding = AUDIO_ENCODING_LINEAR;
            break;
    }

    ALuint frameSize{numChannels * mDevice->bytesFromFmt()};
    info.play.buffer_size = mDevice->BufferSize * frameSize;

    if(ioctl(mFd, AUDIO_SETINFO, &info) < 0)
    {
        ERR("ioctl failed: %s\n", strerror(errno));
        return false;
    }

    if(mDevice->channelsFromFmt() != info.play.channels)
    {
        ERR("Failed to set %s, got %u channels instead\n", DevFmtChannelsString(mDevice->FmtChans),
            info.play.channels);
        return false;
    }

    if(!((info.play.precision == 8 && info.play.encoding == AUDIO_ENCODING_LINEAR8 && mDevice->FmtType == DevFmtUByte) ||
         (info.play.precision == 8 && info.play.encoding == AUDIO_ENCODING_LINEAR && mDevice->FmtType == DevFmtByte) ||
         (info.play.precision == 16 && info.play.encoding == AUDIO_ENCODING_LINEAR && mDevice->FmtType == DevFmtShort) ||
         (info.play.precision == 32 && info.play.encoding == AUDIO_ENCODING_LINEAR && mDevice->FmtType == DevFmtInt)))
    {
        ERR("Could not set %s samples, got %d (0x%x)\n", DevFmtTypeString(mDevice->FmtType),
            info.play.precision, info.play.encoding);
        return false;
    }

    mDevice->Frequency = info.play.sample_rate;
    mDevice->BufferSize = info.play.buffer_size / frameSize;
    mDevice->UpdateSize = mDevice->BufferSize / 2;

    setDefaultChannelOrder();

    mBuffer.resize(mDevice->UpdateSize * mDevice->frameSizeFromFmt());
    std::fill(mBuffer.begin(), mBuffer.end(), 0);

    return true;
}

void SolarisBackend::start()
{
    try {
        mKillNow.store(false, std::memory_order_release);
        mThread = std::thread{std::mem_fn(&SolarisBackend::mixerProc), this};
    }
    catch(std::exception& e) {
        throw al::backend_exception{ALC_INVALID_DEVICE, "Failed to start mixing thread: %s",
            e.what()};
    }
}

void SolarisBackend::stop()
{
    if(mKillNow.exchange(true, std::memory_order_acq_rel) || !mThread.joinable())
        return;
    mThread.join();

    if(ioctl(mFd, AUDIO_DRAIN) < 0)
        ERR("Error draining device: %s\n", strerror(errno));
}

} // namespace

BackendFactory &SolarisBackendFactory::getFactory()
{
    static SolarisBackendFactory factory{};
    return factory;
}

bool SolarisBackendFactory::init()
{
    if(auto devopt = ConfigValueStr(nullptr, "solaris", "device"))
        solaris_driver = std::move(*devopt);
    return true;
}

bool SolarisBackendFactory::querySupport(BackendType type)
{ return type == BackendType::Playback; }

std::string SolarisBackendFactory::probe(BackendType type)
{
    std::string outnames;
    switch(type)
    {
    case BackendType::Playback:
    {
        struct stat buf;
        if(stat(solaris_driver.c_str(), &buf) == 0)
            outnames.append(solaris_device, sizeof(solaris_device));
    }
    break;

    case BackendType::Capture:
        break;
    }
    return outnames;
}

BackendPtr SolarisBackendFactory::createBackend(ALCdevice *device, BackendType type)
{
    if(type == BackendType::Playback)
        return BackendPtr{new SolarisBackend{device}};
    return nullptr;
}
