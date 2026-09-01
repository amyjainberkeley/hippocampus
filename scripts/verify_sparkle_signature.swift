#!/usr/bin/env swift

import CryptoKit
import Foundation

enum SignatureVerificationError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .usage(message), let .invalid(message): return message
        }
    }
}

func parseArguments() throws -> (file: URL, signature: Data, publicKey: Data) {
    var file: URL?
    var signature: Data?
    var publicKey: Data?
    var index = 1

    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        guard index + 1 < CommandLine.arguments.count else {
            throw SignatureVerificationError.usage("missing value after \(argument)")
        }
        let value = CommandLine.arguments[index + 1]
        switch argument {
        case "--file": file = URL(fileURLWithPath: value)
        case "--signature": signature = Data(base64Encoded: value)
        case "--public-key": publicKey = Data(base64Encoded: value)
        default: throw SignatureVerificationError.usage("unknown argument: \(argument)")
        }
        index += 2
    }

    guard let file, let signature, let publicKey else {
        throw SignatureVerificationError.usage(
            "usage: verify-sparkle-signature.sh --file PATH --signature BASE64 --public-key BASE64"
        )
    }
    guard signature.count == 64 else {
        throw SignatureVerificationError.invalid("Sparkle signature must decode to 64 bytes")
    }
    guard publicKey.count == 32 else {
        throw SignatureVerificationError.invalid("Sparkle public key must decode to 32 bytes")
    }
    return (file, signature, publicKey)
}

do {
    let arguments = try parseArguments()
    let archive = try Data(contentsOf: arguments.file, options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: arguments.publicKey)
    guard publicKey.isValidSignature(arguments.signature, for: archive) else {
        throw SignatureVerificationError.invalid(
            "Sparkle signature does not authenticate the staged archive"
        )
    }
    print("Sparkle archive signature verified")
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
