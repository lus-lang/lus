/*
** $Id: larchivelib.c $
** Compression/decompression library (gzip, deflate, zstd, brotli, lz4)
** See Copyright Notice in lua.h
*/

#define larchivelib_c
#define LUA_LIB

#include "lprefix.h"

#include <limits.h>
#include <string.h>

#include "lua.h"

#include "lauxlib.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "lvector.h"

#include <zlib.h>
#include <zstd.h>
#include <brotli/encode.h>
#include <brotli/decode.h>
#include <lz4frame.h>
#include <lz4.h>


/* ===================================================================
** Shared helpers
** =================================================================== */


/*
** Extract raw data from a string or vector argument.
** Sets *is_vec to 1 if the argument is a vector, 0 if string.
*/
static void archive_getinput(lua_State *L, int idx, const char **data,
                             size_t *len, int *is_vec) {
  if (lua_isstring(L, idx)) {
    *data = lua_tolstring(L, idx, len);
    *is_vec = 0;
  }
  else if (lua_isvector(L, idx)) {
    StkId o = L->ci->func.p + idx;
    Vector *v = vecvalue(s2v(o));
    *data = v->data;
    *len = v->len;
    *is_vec = 1;
  }
  else {
    luaL_typeerror(L, idx, "string or vector");
  }
}


/*
** Push the accumulated buffer content ('len' pending uncommitted bytes)
** with the same type as the input. Vector results copy straight from the
** buffer's storage into a new vector and then close the buffer's box:
** the old path interned the whole output as a temporary Lua string
** first, costing an extra full-size copy in peak memory (significant for
** large decompressed outputs).
*/
static void archive_pushbufferresult(lua_State *L, luaL_Buffer *buf, size_t len,
                                     int is_vec) {
  if (is_vec) {
    luaL_addsize(buf, len);
    size_t total = luaL_bufflen(buf);
    int spilled = (luaL_buffaddr(buf) != buf->init.b);
    Vector *v = luaV_newvec(L, total, 1);
    if (total > 0) /* no allocation between the vector's creation and here */
      memcpy(v->data, luaL_buffaddr(buf), total);
    setvecvalue(L, s2v(L->top.p), v);
    L->top.p++;
    if (spilled) /* buffer spilled to a to-be-closed box on the stack */
      lua_closeslot(L, lua_absindex(L, -2));
    lua_remove(L, -2); /* remove the closed box (nil) or the placeholder */
  }
  else {
    luaL_pushresultsize(buf, len);
  }
}


/*
** Cap on decompressed output, to bound "decompression bombs" (a few KB of
** input can expand to many GB, exhausting memory). Defaults to
** ARCHIVE_DEFAULT_MAXOUT and is overridable per call via an optional trailing
** max-bytes argument (<= 0 selects the default).
*/
#define ARCHIVE_DEFAULT_MAXOUT ((size_t)512 * 1024 * 1024)

static size_t archive_maxout(lua_State *L, int idx) {
  lua_Integer m = luaL_optinteger(L, idx, 0);
  return (m > 0) ? (size_t)m : ARCHIVE_DEFAULT_MAXOUT;
}

static int archive_toobig(lua_State *L, size_t maxout) {
  return luaL_error(L, "decompressed size exceeds limit (%I bytes)",
                    (LUAI_UACINT)maxout);
}


/* ===================================================================
** Gzip (via zlib, windowBits = 15+16 for gzip wrapper)
** =================================================================== */

static int archive_gzip_compress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);
  int level = (int)luaL_optinteger(L, 2, 6);
  luaL_argcheck(L, level >= 0 && level <= 9, 2,
                "compression level must be 0-9");
  if (input_len > UINT_MAX)
    return luaL_error(L, "gzip compress: input too large");

  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  int ret =
      deflateInit2(&strm, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
  if (ret != Z_OK)
    return luaL_error(L, "gzip compress init failed (%d)", ret);

  size_t bound = deflateBound(&strm, (uLong)input_len);
  if (bound > UINT_MAX) {
    deflateEnd(&strm);
    return luaL_error(L, "gzip compress: input too large");
  }
  luaL_Buffer buf;
  char *out = luaL_buffinitsize(L, &buf, bound);

  strm.next_in = (Bytef *)input;
  strm.avail_in = (uInt)input_len;
  strm.next_out = (Bytef *)out;
  strm.avail_out = (uInt)bound;

  ret = deflate(&strm, Z_FINISH);
  size_t out_len = strm.total_out;
  deflateEnd(&strm);

  if (ret != Z_STREAM_END)
    return luaL_error(L, "gzip compress failed (%d)", ret);

  archive_pushbufferresult(L, &buf, out_len, is_vec);
  return 1;
}


static int archive_gzip_decompress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);

  size_t maxout = archive_maxout(L, 2);
  if (input_len > UINT_MAX)
    return luaL_error(L, "gzip decompress: input too large");

  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  /* windowBits 15+32 = auto-detect gzip/zlib */
  int ret = inflateInit2(&strm, 15 + 32);
  if (ret != Z_OK)
    return luaL_error(L, "gzip decompress init failed (%d)", ret);

  luaL_Buffer buf;
  luaL_buffinit(L, &buf);

  strm.next_in = (Bytef *)input;
  strm.avail_in = (uInt)input_len;

  do {
    /* guard the multiply: input_len * 4 can wrap on 32-bit size_t */
    size_t chunk = (input_len > 0 && input_len <= MAX_SIZET / 4)
                       ? input_len * 4
                       : (input_len > 0 ? MAX_SIZET : 256);
    if (chunk < 256)
      chunk = 256;
    if (chunk > UINT_MAX)
      chunk = UINT_MAX;
    char *out = luaL_prepbuffsize(&buf, chunk);
    size_t before_in = strm.total_in;
    strm.next_out = (Bytef *)out;
    strm.avail_out = (uInt)chunk;
    ret = inflate(&strm, Z_NO_FLUSH);
    if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) {
      inflateEnd(&strm);
      return luaL_error(L, "gzip decompress failed (%d)", ret);
    }
    size_t produced = chunk - strm.avail_out;
    if ((ret == Z_BUF_ERROR && produced == 0) ||
        (produced == 0 && strm.total_in == before_in && ret != Z_STREAM_END)) {
      inflateEnd(&strm);
      return luaL_error(L, "gzip decompress: incomplete data");
    }
    luaL_addsize(&buf, produced);
    if (luaL_bufflen(&buf) > maxout) {
      inflateEnd(&strm);
      return archive_toobig(L, maxout);
    }
  } while (ret != Z_STREAM_END);

  inflateEnd(&strm);

  archive_pushbufferresult(L, &buf, 0, is_vec);
  return 1;
}


/* ===================================================================
** Deflate (via zlib, raw deflate with windowBits = -15)
** =================================================================== */

static int archive_deflate_compress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);
  int level = (int)luaL_optinteger(L, 2, 6);
  luaL_argcheck(L, level >= 0 && level <= 9, 2,
                "compression level must be 0-9");
  if (input_len > UINT_MAX)
    return luaL_error(L, "deflate compress: input too large");

  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  int ret = deflateInit2(&strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
  if (ret != Z_OK)
    return luaL_error(L, "deflate compress init failed (%d)", ret);

  size_t bound = deflateBound(&strm, (uLong)input_len);
  if (bound > UINT_MAX) {
    deflateEnd(&strm);
    return luaL_error(L, "deflate compress: input too large");
  }
  luaL_Buffer buf;
  char *out = luaL_buffinitsize(L, &buf, bound);

  strm.next_in = (Bytef *)input;
  strm.avail_in = (uInt)input_len;
  strm.next_out = (Bytef *)out;
  strm.avail_out = (uInt)bound;

  ret = deflate(&strm, Z_FINISH);
  size_t out_len = strm.total_out;
  deflateEnd(&strm);

  if (ret != Z_STREAM_END)
    return luaL_error(L, "deflate compress failed (%d)", ret);

  archive_pushbufferresult(L, &buf, out_len, is_vec);
  return 1;
}


static int archive_deflate_decompress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);

  size_t maxout = archive_maxout(L, 2);
  if (input_len > UINT_MAX)
    return luaL_error(L, "deflate decompress: input too large");

  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  int ret = inflateInit2(&strm, -15);
  if (ret != Z_OK)
    return luaL_error(L, "deflate decompress init failed (%d)", ret);

  luaL_Buffer buf;
  luaL_buffinit(L, &buf);

  strm.next_in = (Bytef *)input;
  strm.avail_in = (uInt)input_len;

  do {
    /* guard the multiply: input_len * 4 can wrap on 32-bit size_t */
    size_t chunk = (input_len > 0 && input_len <= MAX_SIZET / 4)
                       ? input_len * 4
                       : (input_len > 0 ? MAX_SIZET : 256);
    if (chunk < 256)
      chunk = 256;
    if (chunk > UINT_MAX)
      chunk = UINT_MAX;
    char *out = luaL_prepbuffsize(&buf, chunk);
    size_t before_in = strm.total_in;
    strm.next_out = (Bytef *)out;
    strm.avail_out = (uInt)chunk;
    ret = inflate(&strm, Z_NO_FLUSH);
    if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) {
      inflateEnd(&strm);
      return luaL_error(L, "deflate decompress failed (%d)", ret);
    }
    size_t produced = chunk - strm.avail_out;
    if ((ret == Z_BUF_ERROR && produced == 0) ||
        (produced == 0 && strm.total_in == before_in && ret != Z_STREAM_END)) {
      inflateEnd(&strm);
      return luaL_error(L, "deflate decompress: incomplete data");
    }
    luaL_addsize(&buf, produced);
    if (luaL_bufflen(&buf) > maxout) {
      inflateEnd(&strm);
      return archive_toobig(L, maxout);
    }
  } while (ret != Z_STREAM_END);

  inflateEnd(&strm);

  archive_pushbufferresult(L, &buf, 0, is_vec);
  return 1;
}


/* ===================================================================
** Zstandard
** =================================================================== */

static int archive_zstd_compress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);
  int level = (int)luaL_optinteger(L, 2, 3);
  luaL_argcheck(L, level >= ZSTD_minCLevel() && level <= ZSTD_maxCLevel(), 2,
                "compression level out of range");

  size_t bound = ZSTD_compressBound(input_len);
  luaL_Buffer buf;
  char *out = luaL_buffinitsize(L, &buf, bound);

  size_t result = ZSTD_compress(out, bound, input, input_len, level);
  if (ZSTD_isError(result))
    return luaL_error(L, "zstd compress failed: %s", ZSTD_getErrorName(result));

  archive_pushbufferresult(L, &buf, result, is_vec);
  return 1;
}


static int archive_zstd_decompress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);

  size_t maxout = archive_maxout(L, 2);
  unsigned long long frame_size = ZSTD_getFrameContentSize(input, input_len);

  if (frame_size == ZSTD_CONTENTSIZE_ERROR)
    return luaL_error(L, "zstd decompress: not valid zstd data");

  if (frame_size != ZSTD_CONTENTSIZE_UNKNOWN) {
    /* Known size: single-shot decompress. Validate the (attacker-controlled)
    ** declared size against the cap BEFORE allocating it. */
    luaL_Buffer buf;
    char *out;
    if (frame_size > (unsigned long long)maxout)
      return archive_toobig(L, maxout);
    out = luaL_buffinitsize(L, &buf, (size_t)frame_size);
    size_t result = ZSTD_decompress(out, (size_t)frame_size, input, input_len);
    if (ZSTD_isError(result))
      return luaL_error(L, "zstd decompress failed: %s",
                        ZSTD_getErrorName(result));

    archive_pushbufferresult(L, &buf, result, is_vec);
  }
  else {
    /* Unknown size: streaming decompress */
    ZSTD_DCtx *dctx = ZSTD_createDCtx();
    if (!dctx)
      return luaL_error(L, "zstd decompress: failed to create context");

    luaL_Buffer buf;
    luaL_buffinit(L, &buf);

    ZSTD_inBuffer zin = {input, input_len, 0};
    size_t ret = 0;
    while (zin.pos < zin.size) {
      size_t chunk = ZSTD_DStreamOutSize();
      char *out = luaL_prepbuffsize(&buf, chunk);
      ZSTD_outBuffer zout = {out, chunk, 0};
      size_t before_in = zin.pos;
      ret = ZSTD_decompressStream(dctx, &zout, &zin);
      if (ZSTD_isError(ret)) {
        ZSTD_freeDCtx(dctx);
        return luaL_error(L, "zstd decompress failed: %s",
                          ZSTD_getErrorName(ret));
      }
      if (zout.pos == 0 && zin.pos == before_in && ret != 0) {
        ZSTD_freeDCtx(dctx);
        return luaL_error(L, "zstd decompress: incomplete data");
      }
      luaL_addsize(&buf, zout.pos);
      if (luaL_bufflen(&buf) > maxout) {
        ZSTD_freeDCtx(dctx);
        return archive_toobig(L, maxout);
      }
    }
    ZSTD_freeDCtx(dctx);
    if (ret != 0)
      return luaL_error(L, "zstd decompress: incomplete data");

    archive_pushbufferresult(L, &buf, 0, is_vec);
  }
  return 1;
}


/* ===================================================================
** Brotli
** =================================================================== */

static int archive_brotli_compress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);
  int quality = (int)luaL_optinteger(L, 2, BROTLI_DEFAULT_QUALITY);
  int lgwin = (int)luaL_optinteger(L, 3, BROTLI_DEFAULT_WINDOW);
  luaL_argcheck(L,
                quality >= BROTLI_MIN_QUALITY && quality <= BROTLI_MAX_QUALITY,
                2, "quality must be 0-11");
  luaL_argcheck(
      L, lgwin >= BROTLI_MIN_WINDOW_BITS && lgwin <= BROTLI_MAX_WINDOW_BITS, 3,
      "lgwin must be 10-24");

  size_t out_len = BrotliEncoderMaxCompressedSize(input_len);
  if (out_len == 0)
    out_len = input_len + 256; /* fallback for empty input */
  luaL_Buffer buf;
  char *out = luaL_buffinitsize(L, &buf, out_len);

  BROTLI_BOOL ok =
      BrotliEncoderCompress(quality, lgwin, BROTLI_MODE_GENERIC, input_len,
                            (const uint8_t *)input, &out_len, (uint8_t *)out);

  if (!ok)
    return luaL_error(L, "brotli compress failed");

  archive_pushbufferresult(L, &buf, out_len, is_vec);
  return 1;
}


static int archive_brotli_decompress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);

  size_t maxout = archive_maxout(L, 2);

  /* Start with input_len*4 or minimum 256 (guarding the multiply,
     which can wrap on 32-bit size_t) */
  size_t out_cap = (input_len > 0 && input_len <= MAX_SIZET / 4)
                       ? input_len * 4
                       : (input_len > 0 ? MAX_SIZET : 256);
  if (out_cap < 256)
    out_cap = 256;

  BrotliDecoderState *state = BrotliDecoderCreateInstance(NULL, NULL, NULL);
  if (!state)
    return luaL_error(L, "brotli decompress: failed to create decoder");

  luaL_Buffer buf;
  luaL_buffinit(L, &buf);

  const uint8_t *next_in = (const uint8_t *)input;
  size_t avail_in = input_len;
  BrotliDecoderResult result;

  do {
    char *out = luaL_prepbuffsize(&buf, out_cap);
    uint8_t *next_out = (uint8_t *)out;
    size_t avail_out = out_cap;
    result = BrotliDecoderDecompressStream(state, &avail_in, &next_in,
                                           &avail_out, &next_out, NULL);
    luaL_addsize(&buf, out_cap - avail_out);
    if (result == BROTLI_DECODER_RESULT_ERROR) {
      BrotliDecoderDestroyInstance(state);
      return luaL_error(L, "brotli decompress failed");
    }
    if (luaL_bufflen(&buf) > maxout) {
      BrotliDecoderDestroyInstance(state);
      return archive_toobig(L, maxout);
    }
  } while (result == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT);

  BrotliDecoderDestroyInstance(state);

  if (result != BROTLI_DECODER_RESULT_SUCCESS)
    return luaL_error(L, "brotli decompress: incomplete data");

  archive_pushbufferresult(L, &buf, 0, is_vec);
  return 1;
}


/* ===================================================================
** LZ4
** =================================================================== */

static int archive_lz4_compress(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);
  int level = (int)luaL_optinteger(L, 2, 1);
  luaL_argcheck(L, level >= 1 && level <= 12, 2,
                "compression level must be 1-12");

  LZ4F_preferences_t prefs;
  memset(&prefs, 0, sizeof(prefs));
  prefs.compressionLevel = level;

  size_t bound = LZ4F_compressFrameBound(input_len, &prefs);
  luaL_Buffer buf;
  char *out = luaL_buffinitsize(L, &buf, bound);

  size_t result = LZ4F_compressFrame(out, bound, input, input_len, &prefs);
  if (LZ4F_isError(result))
    return luaL_error(L, "lz4 compress failed: %s", LZ4F_getErrorName(result));

  archive_pushbufferresult(L, &buf, result, is_vec);
  return 1;
}


static int archive_lz4_decompress_impl(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);

  size_t maxout = archive_maxout(L, 2);
  LZ4F_dctx *dctx;
  LZ4F_errorCode_t err = LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION);
  if (LZ4F_isError(err))
    return luaL_error(L, "lz4 decompress: failed to create context");

  luaL_Buffer buf;
  luaL_buffinit(L, &buf);

  const char *src = input;
  size_t src_remaining = input_len;
  size_t ret = 1;

  while (src_remaining > 0) {
    /* guard the multiply: input_len * 4 can wrap on 32-bit size_t */
    size_t chunk = (input_len > 0 && input_len <= MAX_SIZET / 4)
                       ? input_len * 4
                       : (input_len > 0 ? MAX_SIZET : 256);
    if (chunk < 256)
      chunk = 256;
    char *out = luaL_prepbuffsize(&buf, chunk);
    size_t dst_size = chunk;
    size_t src_size = src_remaining;
    ret = LZ4F_decompress(dctx, out, &dst_size, src, &src_size, NULL);
    if (LZ4F_isError(ret)) {
      LZ4F_freeDecompressionContext(dctx);
      return luaL_error(L, "lz4 decompress failed: %s", LZ4F_getErrorName(ret));
    }
    if (dst_size == 0 && src_size == 0 && ret != 0) {
      LZ4F_freeDecompressionContext(dctx);
      return luaL_error(L, "lz4 decompress: incomplete data");
    }
    luaL_addsize(&buf, dst_size);
    if (luaL_bufflen(&buf) > maxout) {
      LZ4F_freeDecompressionContext(dctx);
      return archive_toobig(L, maxout);
    }
    src += src_size;
    src_remaining -= src_size;
    if (ret == 0)
      break; /* frame fully decoded */
  }

  LZ4F_freeDecompressionContext(dctx);
  if (ret != 0)
    return luaL_error(L, "lz4 decompress: incomplete data");

  archive_pushbufferresult(L, &buf, 0, is_vec);
  return 1;
}


static int archive_lz4_decompress(lua_State *L) {
  return archive_lz4_decompress_impl(L);
}


/*
** Legacy LZ4 frame layout, used by archive_lz4_decompress_hc. A legacy
** frame is the 4-byte little-endian magic 0x184C2102 followed by one or
** more blocks. Each block is a 4-byte little-endian compressed size and
** that many bytes of a raw LZ4 block. Every legacy block decodes to at
** most LZ4_LEGACY_BLOCKSIZE bytes, so a fixed output window of that size
** is a safe capacity for LZ4_decompress_safe on each block. A size field
** that carries a modern or skippable frame magic marks the end of the
** legacy content, since no legacy block ever decodes to that many bytes.
*/
#define LZ4_LEGACY_MAGIC 0x184C2102u
#define LZ4_MODERN_MAGIC 0x184D2204u
#define LZ4_SKIPPABLE_MIN 0x184D2A50u
#define LZ4_SKIPPABLE_MAX 0x184D2A5Fu
#define LZ4_LEGACY_BLOCKSIZE (8 * 1024 * 1024)

static unsigned archive_read_le32(const unsigned char *p) {
  return (unsigned)p[0] | ((unsigned)p[1] << 8) | ((unsigned)p[2] << 16) |
         ((unsigned)p[3] << 24);
}


static int archive_lz4_decompress_hc(lua_State *L) {
  const char *input;
  size_t input_len;
  int is_vec;
  archive_getinput(L, 1, &input, &input_len, &is_vec);
  size_t maxout = archive_maxout(L, 2);

  const unsigned char *p = (const unsigned char *)input;
  if (input_len < 4 || archive_read_le32(p) != LZ4_LEGACY_MAGIC)
    return luaL_error(L, "lz4 decompress_hc: not a legacy LZ4 frame");

  luaL_Buffer buf;
  luaL_buffinit(L, &buf);

  p += 4;
  size_t remaining = input_len - 4;
  while (remaining >= 4) {
    unsigned block_size = archive_read_le32(p);
    p += 4;
    remaining -= 4;
    if (block_size == LZ4_MODERN_MAGIC ||
        (block_size >= LZ4_SKIPPABLE_MIN && block_size <= LZ4_SKIPPABLE_MAX))
      break; /* a following frame begins here, legacy content ends */
    if (block_size > remaining)
      return luaL_error(L, "lz4 decompress_hc: truncated block");
    if (block_size > (unsigned)INT_MAX)
      return luaL_error(L, "lz4 decompress_hc: block too large");
    char *out = luaL_prepbuffsize(&buf, LZ4_LEGACY_BLOCKSIZE);
    int dsz = LZ4_decompress_safe((const char *)p, out, (int)block_size,
                                  LZ4_LEGACY_BLOCKSIZE);
    if (dsz < 0)
      return luaL_error(L, "lz4 decompress_hc: corrupt block");
    luaL_addsize(&buf, (size_t)dsz);
    if (luaL_bufflen(&buf) > maxout)
      return archive_toobig(L, maxout);
    p += block_size;
    remaining -= block_size;
  }

  archive_pushbufferresult(L, &buf, 0, is_vec);
  return 1;
}


/* ===================================================================
** Registration
** =================================================================== */

/*
** Helper: create a nested table path on the table at the given index.
** E.g., create_subtable(L, idx, "archive", "gzip") creates
** tbl.archive.gzip = {} if they don't exist.
** Leaves the deepest table on top of the stack.
*/
static void push_nested(lua_State *L, int idx, const char *k1, const char *k2) {
  idx = lua_absindex(L, idx);
  /* tbl[k1] */
  if (lua_getfield(L, idx, k1) != LUA_TTABLE) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_setfield(L, idx, k1);
  }
  /* tbl[k1][k2] */
  int archive_idx = lua_gettop(L);
  if (lua_getfield(L, archive_idx, k2) != LUA_TTABLE) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_setfield(L, archive_idx, k2);
  }
  /* Remove the intermediate "archive" table, keep only the deepest */
  lua_remove(L, archive_idx);
}


static void register_fn(lua_State *L, const char *name, lua_CFunction fn) {
  lua_pushcfunction(L, fn);
  lua_setfield(L, -2, name);
}


void lus_archive_register(lua_State *L) {
  int vec_idx = lua_gettop(L); /* vector table is at top */

  /* vector.archive.gzip */
  push_nested(L, vec_idx, "archive", "gzip");
  register_fn(L, "compress", archive_gzip_compress);
  register_fn(L, "decompress", archive_gzip_decompress);
  lua_pop(L, 1);

  /* vector.archive.deflate */
  push_nested(L, vec_idx, "archive", "deflate");
  register_fn(L, "compress", archive_deflate_compress);
  register_fn(L, "decompress", archive_deflate_decompress);
  lua_pop(L, 1);

  /* vector.archive.zstd */
  push_nested(L, vec_idx, "archive", "zstd");
  register_fn(L, "compress", archive_zstd_compress);
  register_fn(L, "decompress", archive_zstd_decompress);
  lua_pop(L, 1);

  /* vector.archive.brotli */
  push_nested(L, vec_idx, "archive", "brotli");
  register_fn(L, "compress", archive_brotli_compress);
  register_fn(L, "decompress", archive_brotli_decompress);
  lua_pop(L, 1);

  /* vector.archive.lz4 */
  push_nested(L, vec_idx, "archive", "lz4");
  register_fn(L, "compress", archive_lz4_compress);
  register_fn(L, "decompress", archive_lz4_decompress);
  register_fn(L, "decompress_hc", archive_lz4_decompress_hc);
  lua_pop(L, 1);
}
