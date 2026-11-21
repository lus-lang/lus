//! The root public keys that every `lus` binary trusts
//! (`spec/design/modules.md`, sections 1 and 5).
//!
//! Each root key signs only a list of signing keys, so the signing keys can
//! change without a release of the runtime. The private halves stay
//! offline with the maintainers. A value of null means that the key has not
//! been generated yet. A build without the Lus release root then refuses
//! every release index, except one that a loopback `LUS_RELEASE_URL` signs
//! with the key named by `LUS_RELEASE_KEY`, which the tests use.

/// The root key of the Lus release process, base64 of 32 bytes.
pub const lus_release: ?[]const u8 = null;

/// The root key of `atmosp.here`, base64 of 32 bytes.
pub const atmosphere: ?[]const u8 = null;
