
#include "config.h"

#include "buffer_storage.h"

#include <cstdint>


ALuint BytesFromFmt(FmtType type) noexcept
{
    switch(type)
    {
    case FmtUByte: return sizeof(uint8_t);
    case FmtShort: return sizeof(int16_t);
    case FmtFloat: return sizeof(float);
    case FmtDouble: return sizeof(double);
    case FmtMulaw: return sizeof(uint8_t);
    case FmtAlaw: return sizeof(uint8_t);
    }
    return 0;
}
ALuint ChannelsFromFmt(FmtChannels chans, ALuint ambiorder) noexcept
{
    switch(chans)
    {
    case FmtMono: return 1;
    case FmtStereo: return 2;
    case FmtRear: return 2;
    case FmtQuad: return 4;
    case FmtX51: return 6;
    case FmtX61: return 7;
    case FmtX71: return 8;
    case FmtBFormat2D: return (ambiorder*2) + 1;
    case FmtBFormat3D: return (ambiorder+1) * (ambiorder+1);
    }
    return 0;
}
