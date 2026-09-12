#!/usr/bin/env swift

import CryptoKit
import Foundation

enum VerificationError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .usage(message), let .invalid(message): return message
        }
    }
}

func parseArguments() throws -> (privateKey: URL, infoPlist: URL) {
    var privateKey: URL?
    var infoPlist: URL?
    var index = 1
    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        guard index + 1 < CommandLine.arguments.count else {
            throw VerificationError.usage("missing value after \(argument)")
        }
        switch argument {
        case "--private-key": privateKey = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        case "--info-plist": infoPlist = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        default: throw VerificationError.usage("unknown argument: \(argument)")
        }
        index += 2
    }
    guard let privateKey, let infoPlist else {
        throw VerificationError.usage("usage: verify-sparkle-keypair.sh --private-key PATH --info-plist PATH")
    }
    return (privateKey, infoPlist)
}

func decodedSecret(at url: URL) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let permissions = attributes[.posixPermissions] as? NSNumber,
       permissions.intValue & 0o077 != 0 {
        throw VerificationError.invalid("private key permissions must be 0600")
    }
    let encoded = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let secret = Data(base64Encoded: encoded) else {
        throw VerificationError.invalid("private key is not valid base64")
    }
    guard secret.count == 32 || secret.count == 96 else {
        throw VerificationError.invalid("private key must decode to Sparkle's 32-byte seed or 96-byte legacy format")
    }
    return secret
}

func derivedPublicKey(from secret: Data) throws -> Data {
    if secret.count == 96 {
        return secret.suffix(32)
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        .publicKey.rawRepresentation
}

func expectedPublicKey(in url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dictionary = object as? [String: Any],
          let encoded = dictionary["SUPublicEDKey"] as? String,
          let key = Data(base64Encoded: encoded),
          key.count == 32 else {
        throw VerificationError.invalid("Info.plist SUPublicEDKey must be base64-encoded 32-byte Ed25519 public key")
    }
    return key
}

do {
    let arguments = try parseArguments()
    let actual = try derivedPublicKey(from: decodedSecret(at: arguments.privateKey))
    let expected = try expectedPublicKey(in: arguments.infoPlist)
    guard actual == expected else {
        throw VerificationError.invalid("Sparkle private key does not match Info.plist SUPublicEDKey")
    }
    let fingerprint = SHA256.hash(data: actual).prefix(8)
        .map { String(format: "%02x", $0) }.joined()
    print("Sparkle key pair verified (public-key SHA-256 prefix \(fingerprint))")
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
