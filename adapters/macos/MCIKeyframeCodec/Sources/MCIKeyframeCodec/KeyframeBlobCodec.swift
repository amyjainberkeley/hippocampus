import CryptoKit
import Foundation
import Security

public struct KeyframeSealedBlob: Sendable, Equatable {
    public let bytes: Data
    public let digest: [UInt8]
    public let lowercaseHexDigest: String

    init(bytes: Data) {
        let digest = Array(SHA256.hash(data: bytes))
        self.bytes = bytes
        self.digest = digest
        self.lowercaseHexDigest = digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum KeyframeBlobCodecError: Error, Equatable, Sendable {
    case invalidKeyLength
    case invalidBlob
    case randomGenerationFailed
    case authenticationFailed
}

/// Stable v2 keyframe envelope shared by capture and Recall.
///
/// The byte layout is intentionally unversioned for compatibility with
/// existing evidence: `salt[16] || AES.GCM.SealedBox.combined`.
public enum KeyframeBlobCodec {
    public static let saltLength = 16
    public static let info = Data("mci-blob-v2".utf8)

    public static func seal(
        plaintext: Data,
        keyMaterial: Data
    ) throws -> KeyframeSealedBlob {
        var salt = Data(repeating: 0, count: saltLength)
        let status = salt.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, baseAddress)
        }
        guard status == errSecSuccess else {
            throw KeyframeBlobCodecError.randomGenerationFailed
        }
        return try seal(plaintext: plaintext, keyMaterial: keyMaterial, salt: salt, nonce: nil)
    }

    public static func open(
        blob: Data,
        keyMaterial: Data
    ) throws -> Data {
        guard keyMaterial.count == 32 else {
            throw KeyframeBlobCodecError.invalidKeyLength
        }
        guard blob.count > saltLength + 12 + 16 else {
            throw KeyframeBlobCodecError.invalidBlob
        }

        let salt = blob.prefix(saltLength)
        let combined = blob.dropFirst(saltLength)
        let derivedKey = deriveKey(keyMaterial: keyMaterial, salt: Data(salt))
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else {
            throw KeyframeBlobCodecError.invalidBlob
        }
        do {
            return try AES.GCM.open(sealedBox, using: derivedKey)
        } catch {
            throw KeyframeBlobCodecError.authenticationFailed
        }
    }

    public static func sha256Hex(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func sealForTesting(
        plaintext: Data,
        keyMaterial: Data,
        salt: Data,
        nonce: Data
    ) throws -> KeyframeSealedBlob {
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else {
            throw KeyframeBlobCodecError.invalidBlob
        }
        return try seal(
            plaintext: plaintext,
            keyMaterial: keyMaterial,
            salt: salt,
            nonce: gcmNonce
        )
    }

    private static func seal(
        plaintext: Data,
        keyMaterial: Data,
        salt: Data,
        nonce: AES.GCM.Nonce?
    ) throws -> KeyframeSealedBlob {
        guard keyMaterial.count == 32 else {
            throw KeyframeBlobCodecError.invalidKeyLength
        }
        guard salt.count == saltLength else {
            throw KeyframeBlobCodecError.invalidBlob
        }

        let derivedKey = deriveKey(keyMaterial: keyMaterial, salt: salt)
        let sealedBox: AES.GCM.SealedBox
        do {
            if let nonce {
                sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
            } else {
                sealedBox = try AES.GCM.seal(plaintext, using: derivedKey)
            }
        } catch {
            throw KeyframeBlobCodecError.authenticationFailed
        }
        guard let combined = sealedBox.combined else {
            throw KeyframeBlobCodecError.invalidBlob
        }

        var bytes = Data(capacity: saltLength + combined.count)
        bytes.append(salt)
        bytes.append(combined)
        return KeyframeSealedBlob(bytes: bytes)
    }

    private static func deriveKey(keyMaterial: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyMaterial),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }
}
