/**
 * OpenAL cross platform audio library
 * Copyright (C) 2011 by authors.
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

#include <algorithm>
#include <cerrno>
#include <cstdarg>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

#include "alcmain.h"
#include "almalloc.h"
#include "alfstream.h"
#include "alspan.h"
#include "alstring.h"
#include "compat.h"
#include "logging.h"
#include "strutils.h"
#include "vector.h"


#ifdef _WIN32

#include <shlobj.h>

const PathNamePair &GetProcBinary()
{
    static PathNamePair ret;
    if(!ret.fname.empty() || !ret.path.empty())
        return ret;

    auto fullpath = al::vector<WCHAR>(256);
    DWORD len;
    while((len=GetModuleFileNameW(nullptr, fullpath.data(), static_cast<DWORD>(fullpath.size()))) == fullpath.size())
        fullpath.resize(fullpath.size() << 1);
    if(len == 0)
    {
        ERR("Failed to get process name: error %lu\n", GetLastError());
        return ret;
    }

    fullpath.resize(len);
    if(fullpath.back() != 0)
        fullpath.push_back(0);

    auto sep = std::find(fullpath.rbegin()+1, fullpath.rend(), '\\');
    sep = std::find(fullpath.rbegin()+1, sep, '/');
    if(sep != fullpath.rend())
    {
        *sep = 0;
        ret.fname = wstr_to_utf8(&*sep + 1);
        ret.path = wstr_to_utf8(fullpath.data());
    }
    else
        ret.fname = wstr_to_utf8(fullpath.data());

    TRACE("Got binary: %s, %s\n", ret.path.c_str(), ret.fname.c_str());
    return ret;
}


void al_print(LogLevel level, FILE *logfile, const char *fmt, ...)
{
    al::vector<char> dynmsg;
    char stcmsg[256];
    char *str{stcmsg};

    va_list args, args2;
    va_start(args, fmt);
    va_copy(args2, args);
    int msglen{std::vsnprintf(str, sizeof(stcmsg), fmt, args)};
    if UNLIKELY(msglen >= 0 && static_cast<size_t>(msglen) >= sizeof(stcmsg))
    {
        dynmsg.resize(static_cast<size_t>(msglen) + 1u);
        str = dynmsg.data();
        msglen = std::vsnprintf(str, dynmsg.size(), fmt, args2);
    }
    va_end(args2);
    va_end(args);

    std::wstring wstr{utf8_to_wstr(str)};
    if(gLogLevel >= level)
    {
        fputws(wstr.c_str(), logfile);
        fflush(logfile);
    }
    OutputDebugStringW(wstr.c_str());
}


namespace {

void DirectorySearch(const char *path, const char *ext, al::vector<std::string> *const results)
{
    std::string pathstr{path};
    pathstr += "\\*";
    pathstr += ext;
    TRACE("Searching %s\n", pathstr.c_str());

    std::wstring wpath{utf8_to_wstr(pathstr.c_str())};
    WIN32_FIND_DATAW fdata;
    HANDLE hdl{FindFirstFileW(wpath.c_str(), &fdata)};
    if(hdl == INVALID_HANDLE_VALUE) return;

    const auto base = results->size();

    do {
        results->emplace_back();
        std::string &str = results->back();
        str = path;
        str += '\\';
        str += wstr_to_utf8(fdata.cFileName);
    } while(FindNextFileW(hdl, &fdata));
    FindClose(hdl);

    const al::span<std::string> newlist{results->data()+base, results->size()-base};
    std::sort(newlist.begin(), newlist.end());
    for(const auto &name : newlist)
        TRACE(" got %s\n", name.c_str());
}

} // namespace

al::vector<std::string> SearchDataFiles(const char *ext, const char *subdir)
{
    auto is_slash = [](int c) noexcept -> int { return (c == '\\' || c == '/'); };

    static std::mutex search_lock;
    std::lock_guard<std::mutex> _{search_lock};

    /* If the path is absolute, use it directly. */
    al::vector<std::string> results;
    if(isalpha(subdir[0]) && subdir[1] == ':' && is_slash(subdir[2]))
    {
        std::string path{subdir};
        std::replace(path.begin(), path.end(), '/', '\\');
        DirectorySearch(path.c_str(), ext, &results);
        return results;
    }
    if(subdir[0] == '\\' && subdir[1] == '\\' && subdir[2] == '?' && subdir[3] == '\\')
    {
        DirectorySearch(subdir, ext, &results);
        return results;
    }

    std::string path;

    /* Search the app-local directory. */
    if(auto localpath = al::getenv(L"ALSOFT_LOCAL_PATH"))
    {
        path = wstr_to_utf8(localpath->c_str());
        if(is_slash(path.back()))
            path.pop_back();
    }
    else if(WCHAR *cwdbuf{_wgetcwd(nullptr, 0)})
    {
        path = wstr_to_utf8(cwdbuf);
        if(is_slash(path.back()))
            path.pop_back();
        free(cwdbuf);
    }
    else
        path = ".";
    std::replace(path.begin(), path.end(), '/', '\\');
    DirectorySearch(path.c_str(), ext, &results);

    /* Search the local and global data dirs. */
    static const int ids[2]{ CSIDL_APPDATA, CSIDL_COMMON_APPDATA };
    for(int id : ids)
    {
        WCHAR buffer[MAX_PATH];
        if(SHGetSpecialFolderPathW(nullptr, buffer, id, FALSE) == FALSE)
            continue;

        path = wstr_to_utf8(buffer);
        if(!is_slash(path.back()))
            path += '\\';
        path += subdir;
        std::replace(path.begin(), path.end(), '/', '\\');

        DirectorySearch(path.c_str(), ext, &results);
    }

    return results;
}

void SetRTPriority(void)
{
    if(RTPrioLevel > 0)
    {
        if(!SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL))
            ERR("Failed to set priority level for thread\n");
    }
}

#else

#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>
#ifdef __FreeBSD__
#include <sys/sysctl.h>
#endif
#ifdef __HAIKU__
#include <FindDirectory.h>
#endif
#ifdef __ANDROID__
#include <android/log.h>
#endif
#ifdef HAVE_PROC_PIDPATH
#include <libproc.h>
#endif
#if defined(HAVE_PTHREAD_SETSCHEDPARAM) && !defined(__OpenBSD__)
#include <pthread.h>
#include <sched.h>
#endif

const PathNamePair &GetProcBinary()
{
    static PathNamePair ret;
    if(!ret.fname.empty() || !ret.path.empty())
        return ret;

    al::vector<char> pathname;
#ifdef __FreeBSD__
    size_t pathlen;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    if(sysctl(mib, 4, nullptr, &pathlen, nullptr, 0) == -1)
        WARN("Failed to sysctl kern.proc.pathname: %s\n", strerror(errno));
    else
    {
        pathname.resize(pathlen + 1);
        sysctl(mib, 4, pathname.data(), &pathlen, nullptr, 0);
        pathname.resize(pathlen);
    }
#endif
#ifdef HAVE_PROC_PIDPATH
    if(pathname.empty())
    {
        char procpath[PROC_PIDPATHINFO_MAXSIZE]{};
        const pid_t pid{getpid()};
        if(proc_pidpath(pid, procpath, sizeof(procpath)) < 1)
            ERR("proc_pidpath(%d, ...) failed: %s\n", pid, strerror(errno));
        else
            pathname.insert(pathname.end(), procpath, procpath+strlen(procpath));
    }
#endif
#ifdef __HAIKU__
    if(pathname.empty())
    {
        char procpath[PATH_MAX];
        if(find_path(B_APP_IMAGE_SYMBOL, B_FIND_PATH_IMAGE_PATH, NULL, procpath, sizeof(procpath)) == B_OK)
            pathname.insert(pathname.end(), procpath, procpath+strlen(procpath));
    }
#endif
    if(pathname.empty())
    {
        static const char SelfLinkNames[][32]{
            "/proc/self/exe",
            "/proc/self/file",
            "/proc/curproc/exe",
            "/proc/curproc/file"
        };

        pathname.resize(256);

        const char *selfname{};
        ssize_t len{};
        for(const char *name : SelfLinkNames)
        {
            selfname = name;
            len = readlink(selfname, pathname.data(), pathname.size());
            if(len >= 0 || errno != ENOENT) break;
        }

        while(len > 0 && static_cast<size_t>(len) == pathname.size())
        {
            pathname.resize(pathname.size() << 1);
            len = readlink(selfname, pathname.data(), pathname.size());
        }
        if(len <= 0)
        {
            WARN("Failed to readlink %s: %s\n", selfname, strerror(errno));
            return ret;
        }

        pathname.resize(static_cast<size_t>(len));
    }
    while(!pathname.empty() && pathname.back() == 0)
        pathname.pop_back();

    auto sep = std::find(pathname.crbegin(), pathname.crend(), '/');
    if(sep != pathname.crend())
    {
        ret.path = std::string(pathname.cbegin(), sep.base()-1);
        ret.fname = std::string(sep.base(), pathname.cend());
    }
    else
        ret.fname = std::string(pathname.cbegin(), pathname.cend());

    TRACE("Got binary: %s, %s\n", ret.path.c_str(), ret.fname.c_str());
    return ret;
}


void al_print(LogLevel level, FILE *logfile, const char *fmt, ...)
{
    al::vector<char> dynmsg;
    char stcmsg[256];
    char *str{stcmsg};

    va_list args, args2;
    va_start(args, fmt);
    va_copy(args2, args);
    int msglen{std::vsnprintf(str, sizeof(stcmsg), fmt, args)};
    if UNLIKELY(msglen >= 0 && static_cast<size_t>(msglen) >= sizeof(stcmsg))
    {
        dynmsg.resize(static_cast<size_t>(msglen) + 1u);
        str = dynmsg.data();
        msglen = std::vsnprintf(str, dynmsg.size(), fmt, args2);
    }
    va_end(args2);
    va_end(args);

    if(gLogLevel >= level)
    {
        fputs(str, logfile);
        fflush(logfile);
    }
#ifdef __ANDROID__
    auto android_severity = [](LogLevel l) noexcept
    {
        switch(l)
        {
        case LogLevel::Trace: return ANDROID_LOG_DEBUG;
        case LogLevel::Warning: return ANDROID_LOG_WARN;
        case LogLevel::Error: return ANDROID_LOG_ERROR;
        /* Should not happen. */
        case LogLevel::Disable:
            break;
        }
        return ANDROID_LOG_ERROR;
    };
    __android_log_print(android_severity(level), "openal", "%s", str);
#endif
}


namespace {

void DirectorySearch(const char *path, const char *ext, al::vector<std::string> *const results)
{
    TRACE("Searching %s for *%s\n", path, ext);
    DIR *dir{opendir(path)};
    if(!dir) return;

    const auto base = results->size();
    const size_t extlen{strlen(ext)};

    while(struct dirent *dirent{readdir(dir)})
    {
        if(strcmp(dirent->d_name, ".") == 0 || strcmp(dirent->d_name, "..") == 0)
            continue;

        const size_t len{strlen(dirent->d_name)};
        if(len <= extlen) continue;
        if(al::strcasecmp(dirent->d_name+len-extlen, ext) != 0)
            continue;

        results->emplace_back();
        std::string &str = results->back();
        str = path;
        if(str.back() != '/')
            str.push_back('/');
        str += dirent->d_name;
    }
    closedir(dir);

    const al::span<std::string> newlist{results->data()+base, results->size()-base};
    std::sort(newlist.begin(), newlist.end());
    for(const auto &name : newlist)
        TRACE(" got %s\n", name.c_str());
}

} // namespace

al::vector<std::string> SearchDataFiles(const char *ext, const char *subdir)
{
    static std::mutex search_lock;
    std::lock_guard<std::mutex> _{search_lock};

    al::vector<std::string> results;
    if(subdir[0] == '/')
    {
        DirectorySearch(subdir, ext, &results);
        return results;
    }

    /* Search the app-local directory. */
    if(auto localpath = al::getenv("ALSOFT_LOCAL_PATH"))
        DirectorySearch(localpath->c_str(), ext, &results);
    else
    {
        al::vector<char> cwdbuf(256);
        while(!getcwd(cwdbuf.data(), cwdbuf.size()))
        {
            if(errno != ERANGE)
            {
                cwdbuf.clear();
                break;
            }
            cwdbuf.resize(cwdbuf.size() << 1);
        }
        if(cwdbuf.empty())
            DirectorySearch(".", ext, &results);
        else
        {
            DirectorySearch(cwdbuf.data(), ext, &results);
            cwdbuf.clear();
        }
    }

    // Search local data dir
    if(auto datapath = al::getenv("XDG_DATA_HOME"))
    {
        std::string &path = *datapath;
        if(path.back() != '/')
            path += '/';
        path += subdir;
        DirectorySearch(path.c_str(), ext, &results);
    }
    else if(auto homepath = al::getenv("HOME"))
    {
        std::string &path = *homepath;
        if(path.back() == '/')
            path.pop_back();
        path += "/.local/share/";
        path += subdir;
        DirectorySearch(path.c_str(), ext, &results);
    }

    // Search global data dirs
    std::string datadirs{al::getenv("XDG_DATA_DIRS").value_or("/usr/local/share/:/usr/share/")};

    size_t curpos{0u};
    while(curpos < datadirs.size())
    {
        size_t nextpos{datadirs.find(':', curpos)};

        std::string path{(nextpos != std::string::npos) ?
            datadirs.substr(curpos, nextpos++ - curpos) : datadirs.substr(curpos)};
        curpos = nextpos;

        if(path.empty()) continue;
        if(path.back() != '/')
            path += '/';
        path += subdir;

        DirectorySearch(path.c_str(), ext, &results);
    }

    return results;
}

void SetRTPriority()
{
#if defined(HAVE_PTHREAD_SETSCHEDPARAM) && !defined(__OpenBSD__)
    if(RTPrioLevel > 0)
    {
        struct sched_param param{};
        /* Use the minimum real-time priority possible for now (on Linux this
         * should be 1 for SCHED_RR).
         */
        param.sched_priority = sched_get_priority_min(SCHED_RR);
        int err;
#ifdef SCHED_RESET_ON_FORK
        err = pthread_setschedparam(pthread_self(), SCHED_RR|SCHED_RESET_ON_FORK, &param);
        if(err == EINVAL)
#endif
            err = pthread_setschedparam(pthread_self(), SCHED_RR, &param);
        if(err != 0)
            ERR("Failed to set real-time priority for thread: %s (%d)\n", std::strerror(err), err);
    }
#else
    /* Real-time priority not available */
    if(RTPrioLevel > 0)
        ERR("Cannot set priority level for thread\n");
#endif
}

#endif
