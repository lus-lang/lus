/*
 * The configuration of the vendored Mbed TLS, applied after its default
 * configuration (include/mbedtls/mbedtls_config.h). The runtime uses TLS
 * 1.2 and 1.3 over its own sockets, as a client and as a server, with
 * forward secret key exchanges only. Randomness comes from the system
 * through mbedtls_psa_external_get_random in shim.c, and Mbed TLS opens
 * no file and no socket of its own.
 */

/* No file, socket, or clock access of its own. */
#undef MBEDTLS_FS_IO
#undef MBEDTLS_NET_C
#undef MBEDTLS_TIMING_C
#undef MBEDTLS_PSA_ITS_FILE_C
#undef MBEDTLS_PSA_CRYPTO_STORAGE_C

/* Randomness from the system, through shim.c. */
#undef MBEDTLS_ENTROPY_C
#undef MBEDTLS_CTR_DRBG_C
#define MBEDTLS_NO_PLATFORM_ENTROPY
#define MBEDTLS_PSA_CRYPTO_EXTERNAL_RNG

/* Workers run TLS connections on several threads, and the PSA key store
 * is shared by the process. */
#define MBEDTLS_THREADING_C
#if defined(_WIN32)
#define MBEDTLS_THREADING_ALT
#else
#define MBEDTLS_THREADING_PTHREAD
#endif

/* Stream TLS only. */
#undef MBEDTLS_SSL_PROTO_DTLS
#undef MBEDTLS_SSL_DTLS_ANTI_REPLAY
#undef MBEDTLS_SSL_DTLS_HELLO_VERIFY
#undef MBEDTLS_SSL_DTLS_CLIENT_PORT_REUSE
#undef MBEDTLS_SSL_DTLS_CONNECTION_ID
#undef MBEDTLS_SSL_DTLS_SRTP
#undef MBEDTLS_SSL_COOKIE_C
#undef MBEDTLS_SSL_CACHE_C
#undef MBEDTLS_SSL_TICKET_C
#undef MBEDTLS_SSL_SESSION_TICKETS
#undef MBEDTLS_SSL_EARLY_DATA
#undef MBEDTLS_SSL_RENEGOTIATION
#undef MBEDTLS_SSL_CONTEXT_SERIALIZATION

/* Forward secret key exchanges with certificates. */
#undef MBEDTLS_KEY_EXCHANGE_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_DHE_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECDHE_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_RSA_PSK_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_RSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_DHE_RSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECDH_ECDSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECDH_RSA_ENABLED
#undef MBEDTLS_KEY_EXCHANGE_ECJPAKE_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_ENABLED
#undef MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_PSK_EPHEMERAL_ENABLED
#undef MBEDTLS_DHM_C
#undef MBEDTLS_ECJPAKE_C

/* Algorithms that no TLS peer of today needs. */
#undef MBEDTLS_DES_C
#undef MBEDTLS_ARIA_C
#undef MBEDTLS_CAMELLIA_C
#undef MBEDTLS_CCM_C
#undef MBEDTLS_CMAC_C
#undef MBEDTLS_NIST_KW_C
#undef MBEDTLS_RIPEMD160_C
#undef MBEDTLS_SHA3_C
#undef MBEDTLS_LMS_C
#undef MBEDTLS_PKCS7_C
#undef MBEDTLS_PKCS12_C
#undef MBEDTLS_PADLOCK_C
#undef MBEDTLS_GENPRIME
#undef MBEDTLS_ECP_DP_SECP192R1_ENABLED
#undef MBEDTLS_ECP_DP_SECP224R1_ENABLED
#undef MBEDTLS_ECP_DP_SECP192K1_ENABLED
#undef MBEDTLS_ECP_DP_SECP224K1_ENABLED
#undef MBEDTLS_ECP_DP_SECP256K1_ENABLED
#undef MBEDTLS_ECP_DP_BP256R1_ENABLED
#undef MBEDTLS_ECP_DP_BP384R1_ENABLED
#undef MBEDTLS_ECP_DP_BP512R1_ENABLED

/* X.509 certificates and keys, without revocation lists and signing
 * requests. Certificate writing stays for the unit tests, which make
 * their certificates when they run. */
#undef MBEDTLS_X509_CRL_PARSE_C
#undef MBEDTLS_X509_CSR_PARSE_C
#undef MBEDTLS_X509_CSR_WRITE_C

#undef MBEDTLS_DEBUG_C
#undef MBEDTLS_SELF_TEST
#undef MBEDTLS_VERSION_FEATURES
