#ifndef AL_LISTENER_H
#define AL_LISTENER_H

#include <array>
#include <atomic>

#include "AL/al.h"
#include "AL/alc.h"
#include "AL/efx.h"

#include "almalloc.h"
#include "vecmat.h"

enum class DistanceModel;


struct ALlistenerProps {
    std::array<float,3> Position;
    std::array<float,3> Velocity;
    std::array<float,3> OrientAt;
    std::array<float,3> OrientUp;
    float Gain;
    float MetersPerUnit;

    std::atomic<ALlistenerProps*> next;

    DEF_NEWDEL(ALlistenerProps)
};

struct ALlistener {
    std::array<float,3> Position{{0.0f, 0.0f, 0.0f}};
    std::array<float,3> Velocity{{0.0f, 0.0f, 0.0f}};
    std::array<float,3> OrientAt{{0.0f, 0.0f, -1.0f}};
    std::array<float,3> OrientUp{{0.0f, 1.0f, 0.0f}};
    float Gain{1.0f};
    float mMetersPerUnit{AL_DEFAULT_METERS_PER_UNIT};

    std::atomic_flag PropsClean;

    struct {
        /* Pointer to the most recent property values that are awaiting an
         * update.
         */
        std::atomic<ALlistenerProps*> Update{nullptr};

        alu::Matrix Matrix;
        alu::Vector Velocity;

        float Gain;
        float MetersPerUnit;

        float DopplerFactor;
        float SpeedOfSound; /* in units per sec! */

        bool SourceDistanceModel;
        DistanceModel mDistanceModel;
    } Params;

    ALlistener() { PropsClean.test_and_set(std::memory_order_relaxed); }

    DISABLE_ALLOC()
};

void UpdateListenerProps(ALCcontext *context);

#endif
