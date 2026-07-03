/*
** ltzdata.h
** Declarations for the embedded, zstd-compressed IANA tzdata blob.
** The blob itself lives in the generated ltzdata.c (see scripts/gen-tzdata.js).
*/

#ifndef ltzdata_h
#define ltzdata_h

/* IANA tzdata release string embedded in this build, e.g. "2026b". */
extern const char lus_tzdata_version[];

/* Length in bytes of the uncompressed container (used to size the decode
** buffer without trusting the compressed frame's declared content size). */
extern const unsigned long lus_tzdata_raw_len;

/* The zstd-compressed container and its length. */
extern const unsigned char lus_tzdata_z[];
extern const unsigned long lus_tzdata_z_len;

#endif
