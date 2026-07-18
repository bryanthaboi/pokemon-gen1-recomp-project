
#include "config.h"

#include "cpu_caps.h"

#ifdef HAVE_INTRIN_H
#include <intrin.h>
#endif
#ifdef HAVE_CPUID_H
#include <cpuid.h>
#endif

#include <cctype>
#include <string>

#include "alfstream.h"
#include "logging.h"


int CPUCapFlags{0};

namespace {

#if defined(HAVE_GCC_GET_CPUID) \
    && (defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64))
using reg_type = unsigned int;
inline void get_cpuid(unsigned int f, reg_type *regs)
{ __get_cpuid(f, &regs[0], &regs[1], &regs[2], &regs[3]); }
#define CAN_GET_CPUID
#elif defined(HAVE_CPUID_INTRINSIC) \
    && (defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64))
using reg_type = int;
inline void get_cpuid(unsigned int f, reg_type *regs)
{ (__cpuid)(regs, f); }
#define CAN_GET_CPUID
#endif

} // namespace


void FillCPUCaps(int capfilter)
{
    int caps{0};

/* FIXME: We really should get this for all available CPUs in case different
 * CPUs have different caps (is that possible on one machine?).
 */
#ifdef CAN_GET_CPUID
    union {
        reg_type regs[4];
        char str[sizeof(reg_type[4])];
    } cpuinf[3]{};

    get_cpuid(0, cpuinf[0].regs);
    if(cpuinf[0].regs[0] == 0)
        ERR("Failed to get CPUID\n");
    else
    {
        const reg_type maxfunc{cpuinf[0].regs[0]};

        get_cpuid(0x80000000, cpuinf[0].regs);
        const reg_type maxextfunc{cpuinf[0].regs[0]};

        TRACE("Detected max CPUID function: 0x%x (ext. 0x%x)\n", maxfunc, maxextfunc);

        TRACE("Vendor ID: \"%.4s%.4s%.4s\"\n", cpuinf[0].str+4, cpuinf[0].str+12, cpuinf[0].str+8);
        if(maxextfunc >= 0x80000004)
        {
            get_cpuid(0x80000002, cpuinf[0].regs);
            get_cpuid(0x80000003, cpuinf[1].regs);
            get_cpuid(0x80000004, cpuinf[2].regs);
            TRACE("Name: \"%.16s%.16s%.16s\"\n", cpuinf[0].str, cpuinf[1].str, cpuinf[2].str);
        }

        if(maxfunc >= 1)
        {
            get_cpuid(1, cpuinf[0].regs);
            if((cpuinf[0].regs[3]&(1<<25)))
                caps |= CPU_CAP_SSE;
            if((caps&CPU_CAP_SSE) && (cpuinf[0].regs[3]&(1<<26)))
                caps |= CPU_CAP_SSE2;
            if((caps&CPU_CAP_SSE2) && (cpuinf[0].regs[2]&(1<<0)))
                caps |= CPU_CAP_SSE3;
            if((caps&CPU_CAP_SSE3) && (cpuinf[0].regs[2]&(1<<19)))
                caps |= CPU_CAP_SSE4_1;
        }
    }
#else
    /* Assume support for whatever's supported if we can't check for it */
#if defined(HAVE_SSE4_1)
#warning "Assuming SSE 4.1 run-time support!"
    caps |= CPU_CAP_SSE | CPU_CAP_SSE2 | CPU_CAP_SSE3 | CPU_CAP_SSE4_1;
#elif defined(HAVE_SSE3)
#warning "Assuming SSE 3 run-time support!"
    caps |= CPU_CAP_SSE | CPU_CAP_SSE2 | CPU_CAP_SSE3;
#elif defined(HAVE_SSE2)
#warning "Assuming SSE 2 run-time support!"
    caps |= CPU_CAP_SSE | CPU_CAP_SSE2;
#elif defined(HAVE_SSE)
#warning "Assuming SSE run-time support!"
    caps |= CPU_CAP_SSE;
#endif
#endif

#ifdef HAVE_NEON
#ifdef __ARM_NEON
    caps |= CPU_CAP_NEON;
#else
    al::ifstream file{"/proc/cpuinfo"};
    if(!file.is_open())
        ERR("Failed to open /proc/cpuinfo, cannot check for NEON support\n");
    else
    {
        std::string features;

        auto getline = [](std::istream &f, std::string &output) -> bool
        {
            while(f.good() && f.peek() == '\n')
                f.ignore();
            return std::getline(f, output) && !output.empty();
        };
        while(getline(file, features))
        {
            if(features.compare(0, 10, "Features\t:", 10) == 0)
                break;
        }
        file.close();

        size_t extpos{9};
        while((extpos=features.find("neon", extpos+1)) != std::string::npos)
        {
            if(std::isspace(features[extpos-1])
                && (extpos+4 == features.length() || std::isspace(features[extpos+4])))
            {
                caps |= CPU_CAP_NEON;
                break;
            }
        }
        if(!(caps&CPU_CAP_NEON))
        {
            extpos = 9;
            while((extpos=features.find("asimd", extpos+1)) != std::string::npos)
            {
                if(std::isspace(features[extpos-1])
                    && (extpos+5 == features.length() || std::isspace(features[extpos+5])))
                {
                    caps |= CPU_CAP_NEON;
                    break;
                }
            }
        }
    }
#endif
#endif

    TRACE("Extensions:%s%s%s%s%s%s\n",
        ((capfilter&CPU_CAP_SSE)    ? ((caps&CPU_CAP_SSE)    ? " +SSE"    : " -SSE")    : ""),
        ((capfilter&CPU_CAP_SSE2)   ? ((caps&CPU_CAP_SSE2)   ? " +SSE2"   : " -SSE2")   : ""),
        ((capfilter&CPU_CAP_SSE3)   ? ((caps&CPU_CAP_SSE3)   ? " +SSE3"   : " -SSE3")   : ""),
        ((capfilter&CPU_CAP_SSE4_1) ? ((caps&CPU_CAP_SSE4_1) ? " +SSE4.1" : " -SSE4.1") : ""),
        ((capfilter&CPU_CAP_NEON)   ? ((caps&CPU_CAP_NEON)   ? " +NEON"   : " -NEON")   : ""),
        ((!capfilter) ? " -none-" : "")
    );
    CPUCapFlags = caps & capfilter;
}
