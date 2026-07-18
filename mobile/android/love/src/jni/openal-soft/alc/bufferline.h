#ifndef ALC_BUFFERLINE_H
#define ALC_BUFFERLINE_H

#include <array>

/* Size for temporary storage of buffer data, in floats. Larger values need
 * more memory, while smaller values may need more iterations. The value needs
 * to be a sensible size, however, as it constrains the max stepping value used
 * for mixing, as well as the maximum number of samples per mixing iteration.
 */
#define BUFFERSIZE 1024

using FloatBufferLine = std::array<float,BUFFERSIZE>;

#endif /* ALC_BUFFERLINE_H */
