#include "ccrypto_shim.h"
#include <CommonCrypto/CommonCryptor.h>

// CCCryptorGCMOneshotDecrypt is available macOS 13+
// The Swift CommonCrypto overlay doesn't expose it, but the C header does.
extern CCCryptorStatus CCCryptorGCMOneshotDecrypt(CCAlgorithm alg,
                                                   const void *key, size_t keyLength,
                                                   const void *iv, size_t ivLength,
                                                   const void *aData, size_t aDataLength,
                                                   const void *dataIn, size_t dataInLength,
                                                   void *dataOut,
                                                   const void *tag, size_t tagLength);

int nearby_aes_gcm_decrypt(const void *key, size_t keyLen,
                           const void *nonce, size_t nonceLen,
                           const void *ciphertext, size_t ctLen,
                           const void *tag, size_t tagLen,
                           void *plaintext) {
    CCCryptorStatus status = CCCryptorGCMOneshotDecrypt(
        kCCAlgorithmAES,
        key, keyLen,
        nonce, nonceLen,
        NULL, 0,
        ciphertext, ctLen,
        plaintext,
        tag, tagLen
    );
    return (int)status;
}
