#ifndef ALHELPERS_H
#define ALHELPERS_H

#include "AL/al.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Some helper functions to get the name from the format enums. */
const char *FormatName(ALenum type);

/* Easy device init/deinit functions. InitAL returns 0 on success. */
int InitAL(char ***argv, int *argc);
void CloseAL(void);

/* Cross-platform timeget and sleep functions. */
int altime_get(void);
void al_nssleep(unsigned long nsec);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* ALHELPERS_H */
