#ifndef AL_BUFFER_H
#define AL_BUFFER_H

#include <atomic>

#include "AL/al.h"

#include "albyte.h"
#include "almalloc.h"
#include "atomic.h"
#include "buffer_storage.h"
#include "inprogext.h"
#include "vector.h"


/* User formats */
enum UserFmtType : unsigned char {
    UserFmtUByte = FmtUByte,
    UserFmtShort = FmtShort,
    UserFmtFloat = FmtFloat,
    UserFmtMulaw = FmtMulaw,
    UserFmtAlaw = FmtAlaw,
    UserFmtDouble = FmtDouble,

    UserFmtIMA4 = 128,
    UserFmtMSADPCM,
};
enum UserFmtChannels : unsigned char {
    UserFmtMono = FmtMono,
    UserFmtStereo = FmtStereo,
    UserFmtRear = FmtRear,
    UserFmtQuad = FmtQuad,
    UserFmtX51 = FmtX51,
    UserFmtX61 = FmtX61,
    UserFmtX71 = FmtX71,
    UserFmtBFormat2D = FmtBFormat2D,
    UserFmtBFormat3D = FmtBFormat3D,
};


struct ALbuffer {
    BufferStorage mBuffer;

    ALbitfieldSOFT Access{0u};

    UserFmtType OriginalType{};
    ALuint OriginalSize{0};
    ALuint OriginalAlign{0};

    ALuint LoopStart{0u};
    ALuint LoopEnd{0u};

    ALuint UnpackAlign{0};
    ALuint PackAlign{0};
    ALuint UnpackAmbiOrder{1};

    ALbitfieldSOFT MappedAccess{0u};
    ALsizei MappedOffset{0};
    ALsizei MappedSize{0};

    /* Number of times buffer was attached to a source (deletion can only occur when 0) */
    RefCount ref{0u};

    /* Self ID */
    ALuint id{0};

    inline ALuint bytesFromFmt() const noexcept { return mBuffer.bytesFromFmt(); }
    inline ALuint channelsFromFmt() const noexcept { return mBuffer.channelsFromFmt(); }
    inline ALuint frameSizeFromFmt() const noexcept { return mBuffer.frameSizeFromFmt(); }

    DISABLE_ALLOC()
};

#endif
