import Foundation
import Security
import CryptoKit
import CCryptoShim

enum CryptoError: Error {
    case keychainFailed(OSStatus)
    case keyNotFound
    case decryptionFailed
    case invalidRecord
}

struct Crypto {
    /// Read the BeaconStore encryption key from the login Keychain.
    static func readBeaconKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "BeaconStore",
            kSecAttrAccount as String: "BeaconStoreKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw CryptoError.keyNotFound }
            throw CryptoError.keychainFailed(status)
        }
        // The keychain stores the key as hex string — convert to raw bytes
        if let hexString = String(data: data, encoding: .utf8), hexString.count >= 64 {
            return Data(hexString: hexString) ?? data
        }
        return data
    }

    /// Decrypt a .record plist file and return the parsed dictionary.
    static func decryptRecord(recordPath: URL, key: Data) throws -> [String: Any] {
        let data = try Data(contentsOf: recordPath)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [Data], plist.count >= 3 else {
            throw CryptoError.invalidRecord
        }

        let nonce = plist[0].prefix(16)
        let tag = plist[1]
        let ciphertext = plist[2]

        let plaintext = try decryptAESGCM(key: key, nonce: nonce, ciphertext: ciphertext, tag: tag)

        guard let parsed = try PropertyListSerialization.propertyList(
            from: plaintext, options: [], format: nil
        ) as? [String: Any] else {
            throw CryptoError.decryptionFailed
        }
        return parsed
    }

    /// AES-256-GCM decryption supporting any nonce size.
    /// Uses CryptoKit for 12-byte nonces, CommonCrypto (via C shim) for 16-byte.
    private static func decryptAESGCM(key: Data, nonce: Data, ciphertext: Data, tag: Data) throws -> Data {
        // Try CryptoKit first (fastest, but only supports 12-byte nonces)
        if nonce.count == 12 {
            do {
                let gcmNonce = try AES.GCM.Nonce(data: nonce)
                let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
                return Data(try AES.GCM.open(sealedBox, using: SymmetricKey(data: key)))
            } catch {
                // Fall through to CommonCrypto
            }
        }

        // CommonCrypto supports arbitrary nonce sizes (handles Apple's 16-byte nonces)
        guard !key.isEmpty, !nonce.isEmpty, !ciphertext.isEmpty, !tag.isEmpty else {
            throw CryptoError.invalidRecord
        }
        var plaintext = Data(count: ciphertext.count)
        let status = plaintext.withUnsafeMutableBytes { ptBuf in
            key.withUnsafeBytes { keyBuf in
                nonce.withUnsafeBytes { nonceBuf in
                    ciphertext.withUnsafeBytes { ctBuf in
                        tag.withUnsafeBytes { tagBuf in
                            nearby_aes_gcm_decrypt(
                                keyBuf.baseAddress!, key.count,
                                nonceBuf.baseAddress!, nonce.count,
                                ctBuf.baseAddress!, ciphertext.count,
                                tagBuf.baseAddress!, tag.count,
                                ptBuf.baseAddress!
                            )
                        }
                    }
                }
            }
        }

        guard status == 0 else {
            throw CryptoError.decryptionFailed
        }
        return plaintext
    }
}

// Helper to convert hex string to Data
extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
