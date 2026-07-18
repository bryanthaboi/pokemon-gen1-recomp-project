#ifndef AL_COMPAT_H
#define AL_COMPAT_H

#include <string>

struct PathNamePair { std::string path, fname; };
const PathNamePair &GetProcBinary(void);

#endif /* AL_COMPAT_H */
