/*
 * The part of the TLS layer written in C: a small interface over Mbed TLS
 * for src/lib/tls.zig, which keeps the structures of Mbed TLS out of Zig.
 * A configuration holds the settings that connections share. A connection
 * moves bytes through two callbacks that tls.zig supplies, which read and
 * write the socket without waiting and report MBEDTLS_ERR_SSL_WANT_READ or
 * MBEDTLS_ERR_SSL_WANT_WRITE when it is not ready. Every function of a
 * connection then returns that code too, and tls.zig waits for the socket
 * and calls the function again, which continues where it stopped.
 */

#if !defined(_WIN32) && !defined(_DEFAULT_SOURCE)
#define _DEFAULT_SOURCE
#endif

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "mbedtls/error.h"
#include "mbedtls/oid.h"
#include "mbedtls/pk.h"
#include "mbedtls/platform.h"
#include "mbedtls/ssl.h"
#include "mbedtls/threading.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/random.h>
#include <unistd.h>
#endif

/* ----------------------------------------------------------------------
 * Randomness and process setup */

/* Fills `out` with random bytes from the system. Returns 0 on success. */
static int system_random(unsigned char *out, size_t len)
{
#if defined(_WIN32)
    /* RtlGenRandom, exported by advapi32 as SystemFunction036. */
    extern BOOLEAN NTAPI SystemFunction036(PVOID buffer, ULONG length);
    while (len > 0) {
        ULONG n = len > 0x10000 ? 0x10000 : (ULONG) len;
        if (!SystemFunction036(out, n)) return -1;
        out += n;
        len -= n;
    }
    return 0;
#else
    while (len > 0) {
        size_t n = len > 256 ? 256 : len;
        if (getentropy(out, n) != 0) return -1;
        out += n;
        len -= n;
    }
    return 0;
#endif
}

psa_status_t mbedtls_psa_external_get_random(mbedtls_psa_external_random_context_t *context,
                                             uint8_t *output, size_t output_size, size_t *output_length)
{
    (void) context;
    if (system_random(output, output_size) != 0) {
        *output_length = 0;
        return PSA_ERROR_INSUFFICIENT_ENTROPY;
    }
    *output_length = output_size;
    return PSA_SUCCESS;
}

static int rng(void *ctx, unsigned char *out, size_t len)
{
    (void) ctx;
    return system_random(out, len) == 0 ? 0 : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

#if defined(MBEDTLS_THREADING_ALT)
static void mutex_init(mbedtls_threading_mutex_t *m)
{
    InitializeSRWLock(&m->lock);
    m->is_valid = 1;
}

static void mutex_free(mbedtls_threading_mutex_t *m)
{
    m->is_valid = 0;
}

static int mutex_lock(mbedtls_threading_mutex_t *m)
{
    if (!m->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
    AcquireSRWLockExclusive(&m->lock);
    return 0;
}

static int mutex_unlock(mbedtls_threading_mutex_t *m)
{
    if (!m->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
    ReleaseSRWLockExclusive(&m->lock);
    return 0;
}
#endif

/* Sets up Mbed TLS for the process. tls.zig calls it once, before any
 * other function. Returns 0 on success. */
int lus_tls_init(void)
{
#if defined(MBEDTLS_THREADING_ALT)
    mbedtls_threading_set_alt(mutex_init, mutex_free, mutex_lock, mutex_unlock);
#endif
    return psa_crypto_init() == PSA_SUCCESS ? 0 : -1;
}

/* Writes the text of an error code of Mbed TLS into `buf`. */
void lus_tls_strerror(int code, char *buf, size_t size)
{
    mbedtls_strerror(code, buf, size);
}

/* ----------------------------------------------------------------------
 * Certificate chains */

mbedtls_x509_crt *lus_tls_chain_new(void)
{
    mbedtls_x509_crt *c = calloc(1, sizeof *c);
    if (c) mbedtls_x509_crt_init(c);
    return c;
}

void lus_tls_chain_free(mbedtls_x509_crt *c)
{
    if (!c) return;
    mbedtls_x509_crt_free(c);
    free(c);
}

int lus_tls_chain_add_der(mbedtls_x509_crt *c, const unsigned char *der, size_t len)
{
    return mbedtls_x509_crt_parse_der(c, der, len);
}

/* Adds the certificates of PEM text. Returns 0 when all of them parsed,
 * a positive count of the certificates that did not, or a negative error
 * when none did. */
int lus_tls_chain_add_pem(mbedtls_x509_crt *c, const char *pem, size_t len)
{
    /* The PEM parser of Mbed TLS reads text that ends with a NUL byte. */
    unsigned char *buf = malloc(len + 1);
    if (!buf) return MBEDTLS_ERR_X509_ALLOC_FAILED;
    memcpy(buf, pem, len);
    buf[len] = 0;
    int r = mbedtls_x509_crt_parse(c, buf, len + 1);
    free(buf);
    return r;
}

/* The number of certificates of a chain. */
int lus_tls_chain_count(const mbedtls_x509_crt *c)
{
    int n = 0;
    for (; c && c->raw.len > 0; c = c->next) n++;
    return n;
}

/* ----------------------------------------------------------------------
 * Configurations */

#define LUS_TLS_MAX_CERTS 16
#define LUS_TLS_MAX_ALPN 16

typedef struct lus_tls_config {
    int refs;
    int server;
    mbedtls_ssl_config conf;
    /* The trusted certificates. A configuration owns its chain unless the
     * chain is the shared chain of the system certificates. */
    mbedtls_x509_crt *ca;
    int owns_ca;
    /* The certificates of this end, with their keys. A server picks one
     * by the name that the client asks for. */
    int ncerts;
    mbedtls_x509_crt *certs[LUS_TLS_MAX_CERTS];
    mbedtls_pk_context *keys[LUS_TLS_MAX_CERTS];
    const char *alpn[LUS_TLS_MAX_ALPN + 1];
    char *alpn_text;
} lus_tls_config;

/* The connection state that the SNI callback writes. */
typedef struct lus_tls {
    mbedtls_ssl_context ssl;
    lus_tls_config *cfg;
    char servername[256];
} lus_tls;

static int name_matches(const char *pattern, size_t plen, const char *name, size_t nlen)
{
    /* A wildcard stands for the whole leftmost label and nothing else. */
    if (plen > 2 && pattern[0] == '*' && pattern[1] == '.') {
        const char *dot = memchr(name, '.', nlen);
        if (!dot || dot == name) return 0;
        size_t rest = nlen - (size_t) (dot - name);
        if (rest != plen - 1) return 0;
        pattern += 1;
        plen -= 1;
        name = dot;
        nlen = rest;
    }
    if (plen != nlen) return 0;
    for (size_t i = 0; i < plen; i++) {
        char a = pattern[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return 0;
    }
    return 1;
}

static int cert_matches(const mbedtls_x509_crt *crt, const char *name, size_t len)
{
    int had_dns = 0;
    for (const mbedtls_x509_sequence *s = &crt->subject_alt_names; s && s->buf.p; s = s->next) {
        if ((s->buf.tag & MBEDTLS_ASN1_TAG_VALUE_MASK) != MBEDTLS_X509_SAN_DNS_NAME) continue;
        had_dns = 1;
        if (name_matches((const char *) s->buf.p, s->buf.len, name, len)) return 1;
    }
    if (had_dns) return 0;
    for (const mbedtls_x509_name *n = &crt->subject; n; n = n->next) {
        if (MBEDTLS_OID_CMP(MBEDTLS_OID_AT_CN, &n->oid) == 0 &&
            name_matches((const char *) n->val.p, n->val.len, name, len)) return 1;
    }
    return 0;
}

static int sni(void *p, mbedtls_ssl_context *ssl, const unsigned char *name, size_t len)
{
    lus_tls_config *cfg = p;
    lus_tls *t = (lus_tls *) ssl;
    size_t keep = len < sizeof t->servername - 1 ? len : sizeof t->servername - 1;
    memcpy(t->servername, name, keep);
    t->servername[keep] = 0;
    for (int i = 0; i < cfg->ncerts; i++) {
        if (cert_matches(cfg->certs[i], (const char *) name, len))
            return mbedtls_ssl_set_hs_own_cert(ssl, cfg->certs[i], cfg->keys[i]);
    }
    /* A name that no certificate carries gets the first certificate, and
     * the client decides whether to accept it. */
    return 0;
}

lus_tls_config *lus_tls_config_new(int server)
{
    lus_tls_config *cfg = calloc(1, sizeof *cfg);
    if (!cfg) return NULL;
    cfg->refs = 1;
    cfg->server = server;
    mbedtls_ssl_config_init(&cfg->conf);
    if (mbedtls_ssl_config_defaults(&cfg->conf, server ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        mbedtls_ssl_config_free(&cfg->conf);
        free(cfg);
        return NULL;
    }
    mbedtls_ssl_conf_rng(&cfg->conf, rng, NULL);
    mbedtls_ssl_conf_min_tls_version(&cfg->conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_authmode(&cfg->conf, server ? MBEDTLS_SSL_VERIFY_NONE : MBEDTLS_SSL_VERIFY_REQUIRED);
    if (server) mbedtls_ssl_conf_sni(&cfg->conf, sni, cfg);
    return cfg;
}

static void config_release(lus_tls_config *cfg)
{
    if (--cfg->refs > 0) return;
    mbedtls_ssl_config_free(&cfg->conf);
    if (cfg->owns_ca) lus_tls_chain_free(cfg->ca);
    for (int i = 0; i < cfg->ncerts; i++) {
        lus_tls_chain_free(cfg->certs[i]);
        mbedtls_pk_free(cfg->keys[i]);
        free(cfg->keys[i]);
    }
    free(cfg->alpn_text);
    free(cfg);
}

void lus_tls_config_free(lus_tls_config *cfg)
{
    if (cfg) config_release(cfg);
}

/* Trusts the certificates of `ca`. With `owned`, the configuration frees
 * the chain. */
void lus_tls_config_ca(lus_tls_config *cfg, mbedtls_x509_crt *ca, int owned)
{
    if (cfg->owns_ca) lus_tls_chain_free(cfg->ca);
    cfg->ca = ca;
    cfg->owns_ca = owned;
    mbedtls_ssl_conf_ca_chain(&cfg->conf, ca, NULL);
}

void lus_tls_config_verify(lus_tls_config *cfg, int verify)
{
    mbedtls_ssl_conf_authmode(&cfg->conf, verify ? MBEDTLS_SSL_VERIFY_REQUIRED : MBEDTLS_SSL_VERIFY_NONE);
}

/* Adds a certificate chain of this end and its private key, both PEM
 * text. Returns 0, or an error code. On failure, `which` says whether the
 * certificate (1) or the key (2) failed, or 3 for too many certificates. */
int lus_tls_config_own(lus_tls_config *cfg, const char *cert, size_t cert_len, const char *key, size_t key_len,
                       const char *password, size_t password_len, int *which)
{
    *which = 3;
    if (cfg->ncerts >= LUS_TLS_MAX_CERTS) return MBEDTLS_ERR_SSL_BAD_INPUT_DATA;
    mbedtls_x509_crt *crt = lus_tls_chain_new();
    mbedtls_pk_context *pk = calloc(1, sizeof *pk);
    if (!crt || !pk) {
        lus_tls_chain_free(crt);
        free(pk);
        *which = 1;
        return MBEDTLS_ERR_SSL_ALLOC_FAILED;
    }
    mbedtls_pk_init(pk);
    *which = 1;
    int r = lus_tls_chain_add_pem(crt, cert, cert_len);
    if (r == 0) {
        *which = 2;
        unsigned char *buf = malloc(key_len + 1);
        if (!buf) {
            r = MBEDTLS_ERR_PK_ALLOC_FAILED;
        } else {
            memcpy(buf, key, key_len);
            buf[key_len] = 0;
            r = mbedtls_pk_parse_key(pk, buf, key_len + 1, (const unsigned char *) password, password_len, rng, NULL);
            mbedtls_platform_zeroize(buf, key_len);
            free(buf);
        }
        if (r == 0) {
            *which = 0;
            r = mbedtls_ssl_conf_own_cert(&cfg->conf, crt, pk);
        }
    } else if (r > 0) {
        r = MBEDTLS_ERR_X509_INVALID_FORMAT;
    }
    if (r != 0) {
        lus_tls_chain_free(crt);
        mbedtls_pk_free(pk);
        free(pk);
        return r;
    }
    cfg->certs[cfg->ncerts] = crt;
    cfg->keys[cfg->ncerts] = pk;
    cfg->ncerts++;
    return 0;
}

/* Sets the protocols that ALPN offers: `text` holds `n` names, each
 * followed by a NUL byte. */
int lus_tls_config_alpn(lus_tls_config *cfg, const char *text, size_t len, int n)
{
    if (n > LUS_TLS_MAX_ALPN) return MBEDTLS_ERR_SSL_BAD_INPUT_DATA;
    char *copy = malloc(len);
    if (!copy) return MBEDTLS_ERR_SSL_ALLOC_FAILED;
    memcpy(copy, text, len);
    const char *p = copy;
    for (int i = 0; i < n; i++) {
        cfg->alpn[i] = p;
        p += strlen(p) + 1;
    }
    cfg->alpn[n] = NULL;
    free(cfg->alpn_text);
    cfg->alpn_text = copy;
    return mbedtls_ssl_conf_alpn_protocols(&cfg->conf, cfg->alpn);
}

/* ----------------------------------------------------------------------
 * Connections */

typedef int (*lus_tls_send_fn)(void *ctx, const unsigned char *buf, size_t len);
typedef int (*lus_tls_recv_fn)(void *ctx, unsigned char *buf, size_t len);

/* Starts a connection under `cfg`, which it keeps alive. A client checks
 * the certificate of the server against `servername` and sends it in SNI. */
lus_tls *lus_tls_new(lus_tls_config *cfg, const char *servername, void *io, lus_tls_send_fn send, lus_tls_recv_fn recv, int *err)
{
    lus_tls *t = calloc(1, sizeof *t);
    if (!t) {
        *err = MBEDTLS_ERR_SSL_ALLOC_FAILED;
        return NULL;
    }
    mbedtls_ssl_init(&t->ssl);
    int r = mbedtls_ssl_setup(&t->ssl, &cfg->conf);
    if (r == 0 && servername && !cfg->server) r = mbedtls_ssl_set_hostname(&t->ssl, servername);
    if (r != 0) {
        mbedtls_ssl_free(&t->ssl);
        free(t);
        *err = r;
        return NULL;
    }
    if (servername && !cfg->server) {
        size_t n = strlen(servername);
        if (n >= sizeof t->servername) n = sizeof t->servername - 1;
        memcpy(t->servername, servername, n);
    }
    mbedtls_ssl_set_bio(&t->ssl, io, (mbedtls_ssl_send_t *) send, (mbedtls_ssl_recv_t *) recv, NULL);
    t->cfg = cfg;
    cfg->refs++;
    *err = 0;
    return t;
}

void lus_tls_free(lus_tls *t)
{
    if (!t) return;
    mbedtls_ssl_free(&t->ssl);
    config_release(t->cfg);
    free(t);
}

/* Gives the connection a new context for its callbacks. */
void lus_tls_set_io(lus_tls *t, void *io, lus_tls_send_fn send, lus_tls_recv_fn recv)
{
    mbedtls_ssl_set_bio(&t->ssl, io, (mbedtls_ssl_send_t *) send, (mbedtls_ssl_recv_t *) recv, NULL);
}

int lus_tls_handshake(lus_tls *t)
{
    return mbedtls_ssl_handshake(&t->ssl);
}

int lus_tls_handshake_done(lus_tls *t)
{
    return mbedtls_ssl_is_handshake_over(&t->ssl);
}

int lus_tls_read(lus_tls *t, unsigned char *buf, size_t len)
{
    return mbedtls_ssl_read(&t->ssl, buf, len);
}

int lus_tls_write(lus_tls *t, const unsigned char *buf, size_t len)
{
    return mbedtls_ssl_write(&t->ssl, buf, len);
}

/* The bytes of plain text that the connection holds and a read returns
 * without the socket. */
size_t lus_tls_pending(lus_tls *t)
{
    return mbedtls_ssl_get_bytes_avail(&t->ssl);
}

int lus_tls_close_notify(lus_tls *t)
{
    return mbedtls_ssl_close_notify(&t->ssl);
}

/* Describes why the certificate of the peer failed verification, or
 * writes nothing when it passed. */
void lus_tls_verify_info(lus_tls *t, char *buf, size_t size)
{
    buf[0] = 0;
    uint32_t flags = mbedtls_ssl_get_verify_result(&t->ssl);
    if (flags == 0 || flags == (uint32_t) -1) return;
    mbedtls_x509_crt_verify_info(buf, size, "", flags);
    /* The text ends with a line break and puts each reason on a line of
     * its own. An error message is one line, so the reasons join with
     * commas. */
    size_t n = strlen(buf);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) buf[--n] = 0;
    for (size_t i = 0; i < n; i++) if (buf[i] == '\n') buf[i] = ',';
}

const char *lus_tls_version(lus_tls *t)
{
    return mbedtls_ssl_get_version(&t->ssl);
}

const char *lus_tls_cipher(lus_tls *t)
{
    return mbedtls_ssl_get_ciphersuite(&t->ssl);
}

const char *lus_tls_alpn(lus_tls *t)
{
    return mbedtls_ssl_get_alpn_protocol(&t->ssl);
}

const char *lus_tls_servername(lus_tls *t)
{
    return t->servername[0] ? t->servername : NULL;
}

/* ----------------------------------------------------------------------
 * Test identities */

/* Makes a P-256 key and a certificate for `cn` that the key signs, both
 * as PEM text, for the unit tests and the fuzz targets, which make their
 * certificates when they run. Returns 0, or an error code. */
int lus_tls_test_identity(const char *cn, char *cert, size_t cert_cap, char *key, size_t key_cap)
{
    mbedtls_pk_context pk;
    mbedtls_x509write_cert crt;
    mbedtls_pk_init(&pk);
    mbedtls_x509write_crt_init(&crt);
    char name[300];
    int r = mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
    if (r == 0) r = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(pk), rng, NULL);
    if (r == 0) r = mbedtls_pk_write_key_pem(&pk, (unsigned char *) key, key_cap);
    if (r == 0) {
        size_t n = strlen(cn);
        if (n > 250) n = 250;
        memcpy(name, "CN=", 3);
        memcpy(name + 3, cn, n);
        name[3 + n] = 0;
        unsigned char serial[1] = { 1 };
        mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&crt, &pk);
        mbedtls_x509write_crt_set_issuer_key(&crt, &pk);
        r = mbedtls_x509write_crt_set_subject_name(&crt, name);
        if (r == 0) r = mbedtls_x509write_crt_set_issuer_name(&crt, name);
        if (r == 0) r = mbedtls_x509write_crt_set_serial_raw(&crt, serial, 1);
        if (r == 0) r = mbedtls_x509write_crt_set_validity(&crt, "20200101000000", "20991231235959");
        if (r == 0) r = mbedtls_x509write_crt_pem(&crt, (unsigned char *) cert, cert_cap, rng, NULL);
    }
    mbedtls_x509write_crt_free(&crt);
    mbedtls_pk_free(&pk);
    return r;
}
