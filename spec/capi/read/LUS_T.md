---
name: "LUS_T*"
header: lus.h
kind: constant
since: "2.0.0"
stability: stable
origin: lus
signature: |
  #define LUS_TNONE (-1)
  #define LUS_TNIL 0
  #define LUS_TBOOLEAN 1
  #define LUS_TLIGHT 2
  #define LUS_TNUMBER 3
  #define LUS_TSTRING 4
  #define LUS_TTABLE 5
  #define LUS_TFUNCTION 6
  #define LUS_TUSERDATA 7
  #define LUS_TTHREAD 8
  #define LUS_TVECTOR 9
  #define LUS_TENUM 10
  #define LUS_TQUERY 11
---

The type codes that `lus_type`, `lus_rawget`, and `lus_rawgeti` return.

- `LUS_TNONE` marks an index that names no value.
- `LUS_TLIGHT` is a light value, a raw host pointer pushed with `lus_pushlight`.
- `LUS_TNUMBER` covers integers, floats, bigints, and decimals alike.
- `LUS_TFUNCTION` covers functions written in Lus and in C.
- `LUS_TUSERDATA` is a block made by `lus_newuserdata`.
- `LUS_TTHREAD` is a coroutine.
- `LUS_TVECTOR` is a byte buffer.
- `LUS_TENUM` covers both an enum and its values.
- `LUS_TQUERY` is a query.
