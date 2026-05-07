#ifndef CCRYPTO_SHIM_H
#define CCRYPTO_SHIM_H

#include <stddef.h>

/// AES-256-GCM decrypt with arbitrary nonce size (supports Apple's 16-byte nonces).
/// Returns 0 on success, non-zero on failure.
int nearby_aes_gcm_decrypt(const void *key, size_t keyLen,
                           const void *nonce, size_t nonceLen,
                           const void *ciphertext, size_t ctLen,
                           const void *tag, size_t tagLen,
                           void *plaintext);

#endif
