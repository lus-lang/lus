/* The mutex of Mbed TLS on Windows, which has no pthreads. shim.c
 * installs the functions that use it. */
#ifndef LUS_THREADING_ALT_H
#define LUS_THREADING_ALT_H

#include <windows.h>

typedef struct mbedtls_threading_mutex_t {
    SRWLOCK lock;
    char is_valid;
} mbedtls_threading_mutex_t;

#endif
