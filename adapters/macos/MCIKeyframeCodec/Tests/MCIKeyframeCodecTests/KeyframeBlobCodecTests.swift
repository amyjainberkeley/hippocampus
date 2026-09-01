import Foundation
import XCTest

@testable import MCIKeyframeCodec

final class KeyframeBlobCodecTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))
    private let plaintext = Data("post-privacy evidence".utf8)

    func testV2ConstantsAndRoundTrip() throws {
        let sealed = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)

        XCTAssertEqual(KeyframeBlobCodec.saltLength, 16)
        XCTAssertEqual(KeyframeBlobCodec.info, Data("mci-blob-v2".utf8))
        XCTAssertGreaterThan(sealed.bytes.count, KeyframeBlobCodec.saltLength + 28)
        XCTAssertEqual(sealed.digest.count, 32)
        XCTAssertEqual(sealed.lowercaseHexDigest.count, 64)
        XCTAssertEqual(
            sealed.lowercaseHexDigest,
            KeyframeBlobCodec.sha256Hex(of: sealed.bytes)
        )
        XCTAssertEqual(
            try KeyframeBlobCodec.open(blob: sealed.bytes, keyMaterial: key),
            plaintext
        )
    }

    func testRandomSaltMakesEqualPlaintextProduceDifferentBlobs() throws {
        let first = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)
        let second = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)

        XCTAssertNotEqual(first.bytes, second.bytes)
        XCTAssertNotEqual(first.lowercaseHexDigest, second.lowercaseHexDigest)
    }

    func testRejectsWrongAndShortKeys() throws {
        let sealed = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)

        XCTAssertThrowsError(
            try KeyframeBlobCodec.open(blob: sealed.bytes, keyMaterial: Data(repeating: 7, count: 32))
        )
        XCTAssertThrowsError(
            try KeyframeBlobCodec.open(blob: sealed.bytes, keyMaterial: Data(repeating: 7, count: 31))
        )
        XCTAssertThrowsError(
            try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: Data(repeating: 7, count: 33))
        )
    }

    func testRejectsPlaintextEmptyAndUndersizedBlobs() {
        for blob in [Data(), plaintext, Data(repeating: 0, count: 16)] {
            XCTAssertThrowsError(try KeyframeBlobCodec.open(blob: blob, keyMaterial: key))
        }
    }

    func testRejectsTamperedSaltNonceCiphertextAndTag() throws {
        let sealed = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)
        let offsets = [0, 16, 29, sealed.bytes.count - 1]

        for offset in offsets {
            var bytes = sealed.bytes
            bytes[offset] ^= 0xff
            XCTAssertThrowsError(try KeyframeBlobCodec.open(blob: bytes, keyMaterial: key))
        }
    }

    func testDeterministicFixturePreservesExactV2Envelope() throws {
        let salt = Data((0..<16).map { UInt8(0xa0 + $0) })
        let nonce = Data((0..<12).map { UInt8(0x10 + $0) })
        let sealed = try KeyframeBlobCodec.sealForTesting(
            plaintext: plaintext,
            keyMaterial: key,
            salt: salt,
            nonce: nonce
        )

        XCTAssertEqual(sealed.bytes.prefix(16), salt)
        XCTAssertEqual(
            sealed.lowercaseHexDigest,
            "6ed2fbabdff5e83436963171f270d800159a021f215a534f7ff3364e9cd9caaa"
        )
        XCTAssertEqual(try KeyframeBlobCodec.open(blob: sealed.bytes, keyMaterial: key), plaintext)
    }
}
