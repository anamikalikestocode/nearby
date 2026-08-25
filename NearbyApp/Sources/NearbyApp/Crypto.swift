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
    /// In-memory cached key — avoids repeated keychain prompts within a single launch.
    private static var cachedKey: Data?

    // MARK: - Our own keychain entry (never prompts the user)

    private static let ownService = "com.nearby.beaconkey"
    private static let ownAccount = "cached"

    /// Try reading the key from our own keychain entry (no user prompt).
    private static func readOwnKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// Save the key to our own keychain entry so future launches never prompt.
    private static func saveToOwnKeychain(_ key: Data) {
        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("nearby: failed to cache key in own keychain: %d", status)
        }
    }

    /// Read the BeaconStore encryption key from the login Keychain.
    ///
    /// Strategy (eliminates "Allow" vs "Always Allow" friction):
    ///   1. In-memory cache (fastest, no I/O)
    ///   2. Our own keychain entry (com.nearby.beaconkey — never prompts)
    ///   3. Apple's BeaconStore keychain (may prompt user for password)
    ///   4. On success from step 3, persist to step 2 so future launches are silent
    static func readBeaconKey() throws -> Data {
        // 1. In-memory cache
        if let key = cachedKey { return key }

        // 2. Our own keychain (persisted from a previous launch — no prompt)
        if let key = readOwnKeychain() {
            cachedKey = key
            return key
        }

        // 3. Apple's BeaconStore (may prompt)
        //    macOS 12-15: service="BeaconStore", account="BeaconStoreKey" (login keychain)
        //    macOS 26+:   service="LocalBeaconStore", account="LocalBeaconStoreKey" (system keychain)
        let keychainVariants: [(String, String)] = [
            ("BeaconStore", "BeaconStoreKey"),
            ("LocalBeaconStore", "LocalBeaconStoreKey"),
        ]
        var data: Data?
        var lastStatus: OSStatus = errSecItemNotFound

        for (service, account) in keychainVariants {
            // First try: read password data (macOS 12-15 stores key here)
            let dataQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            lastStatus = SecItemCopyMatching(dataQuery as CFDictionary, &result)
            if lastStatus == errSecSuccess, let d = result as? Data, d.count >= 16 {
                data = d
                NSLog("nearby: key from %@/%@ password data (%d bytes)", service, account, d.count)
                break
            }

            // Second try: read generic attribute (macOS 26 stores key in kSecAttrGeneric)
            let attrQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            result = nil
            lastStatus = SecItemCopyMatching(attrQuery as CFDictionary, &result)
            if lastStatus == errSecSuccess, let attrs = result as? [String: Any],
               let gena = attrs[kSecAttrGeneric as String] as? Data, gena.count >= 16 {
                data = gena
                NSLog("nearby: key from %@/%@ generic attribute (%d bytes)", service, account, gena.count)
                break
            }
        }

        guard let data = data else {
            if lastStatus == errSecItemNotFound { throw CryptoError.keyNotFound }
            throw CryptoError.keychainFailed(lastStatus)
        }

        // The keychain may store the key in different formats across macOS versions:
        //   macOS 12-15 (BeaconStore): hex string like "8bddc99f..." (64+ chars → 32 bytes)
        //   macOS 26 (LocalBeaconStore): may be raw 32 bytes, or hex, or base64
        let key: Data
        if data.count == 32 {
            // Already raw 32 bytes (AES-256 key) — use directly
            key = data
        } else if let hexString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  hexString.count >= 64,
                  let hexKey = Data(hexString: hexString) {
            // Hex-encoded string → decode to raw bytes
            key = hexKey
        } else if data.count == 64, let hexString = String(data: data, encoding: .utf8),
                  let hexKey = Data(hexString: hexString) {
            // Exactly 64 bytes of ASCII hex
            key = hexKey
        } else {
            // Unknown format — use as-is and hope for the best
            key = data
        }

        NSLog("nearby: beacon key read — raw size=%d, interpreted key size=%d bytes, first4=%@",
              data.count, key.count, key.prefix(4).map { String(format: "%02x", $0) }.joined())

        // Keep raw data for fallback decryption attempts
        rawKeychainData = data

        // 4. Persist to our own keychain so future launches never prompt
        saveToOwnKeychain(key)

        cachedKey = key
        return key
    }

    /// Clear cached key (used if decryption fails — key may have changed after iCloud password reset)
    static func clearCachedKey() {
        cachedKey = nil
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    /// The raw keychain data before interpretation — kept for fallback attempts.
    static var rawKeychainData: Data?

    /// Decrypt a .record plist file and return the parsed dictionary.
    /// If the primary key fails, tries alternate interpretations of the raw keychain data.
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

        // Try primary key first
        if let plaintext = try? decryptAESGCM(key: key, nonce: nonce, ciphertext: ciphertext, tag: tag),
           let parsed = try? PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil) as? [String: Any] {
            return parsed
        }

        // If primary key failed and we have raw keychain data, try alternate interpretations
        if let raw = rawKeychainData, raw != key {
            // Try raw data directly
            if let plaintext = try? decryptAESGCM(key: raw, nonce: nonce, ciphertext: ciphertext, tag: tag),
               let parsed = try? PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil) as? [String: Any] {
                NSLog("nearby: fallback key (raw) worked for %@", recordPath.lastPathComponent)
                return parsed
            }

            // Try hex-decoding the raw data
            if let hexStr = String(data: raw, encoding: .utf8),
               let hexKey = Data(hexString: hexStr),
               hexKey != key {
                if let plaintext = try? decryptAESGCM(key: hexKey, nonce: nonce, ciphertext: ciphertext, tag: tag),
                   let parsed = try? PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil) as? [String: Any] {
                    NSLog("nearby: fallback key (hex-decoded) worked for %@", recordPath.lastPathComponent)
                    return parsed
                }
            }
        }

        throw CryptoError.decryptionFailed
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
