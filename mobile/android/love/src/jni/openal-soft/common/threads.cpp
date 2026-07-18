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

#include "opthelpers.h"
#include "threads.h"

#include <system_error>


#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <limits>

void althrd_setname(const char *name)
{
#if defined(_MSC_VER)
#define MS_VC_EXCEPTION 0x406D1388
#pragma pack(push,8)
    struct {
        DWORD dwType;     // Must be 0x1000.
        LPCSTR szName;    // Pointer to name (in user addr space).
        DWORD dwThreadID; // Thread ID (-1=caller thread).
        DWORD dwFlags;    // Reserved for future use, must be zero.
    } info;
#pragma pack(pop)
    info.dwType = 0x1000;
    info.szName = name;
    info.dwThreadID = ~DWORD{0};
    info.dwFlags = 0;

    __try {
        RaiseException(MS_VC_EXCEPTION, 0, sizeof(info)/sizeof(ULONG_PTR), (ULONG_PTR*)&info);
    }
    __except(EXCEPTION_CONTINUE_EXECUTION) {
    }
#undef MS_VC_EXCEPTION
#else
    (void)name;
#endif
}

namespace al {

semaphore::semaphore(unsigned int initial)
{
    if(initial > static_cast<unsigned int>(std::numeric_limits<int>::max()))
        throw std::system_error(std::make_error_code(std::errc::value_too_large));
    mSem = CreateSemaphore(nullptr, initial, std::numeric_limits<int>::max(), nullptr);
    if(mSem == nullptr)
        throw std::system_error(std::make_error_code(std::errc::resource_unavailable_try_again));
}

semaphore::~semaphore()
{ CloseHandle(mSem); }

void semaphore::post()
{
    if UNLIKELY(!ReleaseSemaphore(static_cast<HANDLE>(mSem), 1, nullptr))
        throw std::system_error(std::make_error_code(std::errc::value_too_large));
}

void semaphore::wait() noexcept
{ WaitForSingleObject(static_cast<HANDLE>(mSem), INFINITE); }

bool semaphore::try_wait() noexcept
{ return WaitForSingleObject(static_cast<HANDLE>(mSem), 0) == WAIT_OBJECT_0; }

} // namespace al

#else

#if defined(HAVE_PTHREAD_SETNAME_NP) || defined(HAVE_PTHREAD_SET_NAME_NP)
#include <pthread.h>
#ifdef HAVE_PTHREAD_NP_H
#include <pthread_np.h>
#endif

void althrd_setname(const char *name)
{
#if defined(HAVE_PTHREAD_SET_NAME_NP)
    pthread_set_name_np(pthread_self(), name);
#elif defined(PTHREAD_SETNAME_NP_ONE_PARAM)
    pthread_setname_np(name);
#elif defined(PTHREAD_SETNAME_NP_THREE_PARAMS)
    pthread_setname_np(pthread_self(), "%s", (void*)name);
#else
    pthread_setname_np(pthread_self(), name);
#endif
}

#else

void althrd_setname(const char*) { }
#endif

#ifdef __APPLE__

namespace al {

semaphore::semaphore(unsigned int initial)
{
    mSem = dispatch_semaphore_create(initial);
    if(!mSem)
        throw std::system_error(std::make_error_code(std::errc::resource_unavailable_try_again));
}

semaphore::~semaphore()
{ dispatch_release(mSem); }

void semaphore::post()
{ dispatch_semaphore_signal(mSem); }

void semaphore::wait() noexcept
{ dispatch_semaphore_wait(mSem, DISPATCH_TIME_FOREVER); }

bool semaphore::try_wait() noexcept
{ return dispatch_semaphore_wait(mSem, DISPATCH_TIME_NOW) == 0; }

} // namespace al

#else /* !__APPLE__ */

#include <cerrno>

namespace al {

semaphore::semaphore(unsigned int initial)
{
    if(sem_init(&mSem, 0, initial) != 0)
        throw std::system_error(std::make_error_code(std::errc::resource_unavailable_try_again));
}

semaphore::~semaphore()
{ sem_destroy(&mSem); }

void semaphore::post()
{
    if(sem_post(&mSem) != 0)
        throw std::system_error(std::make_error_code(std::errc::value_too_large));
}

void semaphore::wait() noexcept
{
    while(sem_wait(&mSem) == -1 && errno == EINTR) {
    }
}

bool semaphore::try_wait() noexcept
{ return sem_trywait(&mSem) == 0; }

} // namespace al

#endif /* __APPLE__ */

#endif /* _WIN32 */
