/*
** lwinzones.h
** CLDR Windows-to-IANA time-zone name mapping (Windows only).
** The table lives in the generated lwinzones.c (see scripts/gen-winzones.js).
*/

#ifndef lwinzones_h
#define lwinzones_h

#if defined(LUS_PLATFORM_WINDOWS)
/* Map a Windows time-zone key (e.g. "Eastern Standard Time") to its primary
** IANA name (e.g. "America/New_York"), or NULL if unknown. */
const char *lus_windows_to_iana(const char *key);
#endif

#endif
