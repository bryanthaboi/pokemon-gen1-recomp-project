#ifndef AL_ENDIANTEST_H
#define AL_ENDIANTEST_H

#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__)
#define IS_LITTLE_ENDIAN (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
#else
static const union {
    unsigned int u;
    unsigned char b[sizeof(unsigned int)];
} EndianTest = { 1 };
#define IS_LITTLE_ENDIAN (EndianTest.b[0] == 1)
#endif

#endif /* AL_ENDIANTEST_H */
