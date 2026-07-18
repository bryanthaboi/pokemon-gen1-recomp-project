#ifndef ALC_BUFFER_FORMATS_H
#define ALC_BUFFER_FORMATS_H

#include "AL/al.h"
#include "AL/alext.h"

#include "albyte.h"
#include "inprogext.h"
#include "vector.h"


/* Storable formats */
enum FmtType : unsigned char {
    FmtUByte,
    FmtShort,
    FmtFloat,
    FmtDouble,
    FmtMulaw,
    FmtAlaw,
};
enum FmtChannels : unsigned char {
    FmtMono,
    FmtStereo,
    FmtRear,
    FmtQuad,
    FmtX51, /* (WFX order) */
    FmtX61, /* (WFX order) */
    FmtX71, /* (WFX order) */
    FmtBFormat2D,
    FmtBFormat3D,
};

enum class AmbiLayout : unsigned char {
    FuMa = AL_FUMA_SOFT,
    ACN = AL_ACN_SOFT,
};
enum class AmbiScaling : unsigned char {
    FuMa = AL_FUMA_SOFT,
    SN3D = AL_SN3D_SOFT,
    N3D = AL_N3D_SOFT,
};

ALuint BytesFromFmt(FmtType type) noexcept;
ALuint ChannelsFromFmt(FmtChannels chans, ALuint ambiorder) noexcept;
inline ALuint FrameSizeFromFmt(FmtChannels chans, FmtType type, ALuint ambiorder) noexcept
{ return ChannelsFromFmt(chans, ambiorder) * BytesFromFmt(type); }


struct BufferStorage {
    al::vector<al::byte,16> mData;

    LPALBUFFERCALLBACKTYPESOFT mCallback{nullptr};
    void *mUserData{nullptr};

    ALuint mSampleRate{0u};
    FmtChannels mChannels{};
    FmtType mType{};
    ALuint mSampleLen{0u};

    AmbiLayout mAmbiLayout{AmbiLayout::FuMa};
    AmbiScaling mAmbiScaling{AmbiScaling::FuMa};
    ALuint mAmbiOrder{0u};

    inline ALuint bytesFromFmt() const noexcept { return BytesFromFmt(mType); }
    inline ALuint channelsFromFmt() const noexcept
    { return ChannelsFromFmt(mChannels, mAmbiOrder); }
    inline ALuint frameSizeFromFmt() const noexcept { return channelsFromFmt() * bytesFromFmt(); }

    inline bool isBFormat() const noexcept
    { return mChannels == FmtBFormat2D || mChannels == FmtBFormat3D; }
};

#endif /* ALC_BUFFER_FORMATS_H */
