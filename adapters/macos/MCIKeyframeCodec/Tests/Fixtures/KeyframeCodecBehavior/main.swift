import Foundation
import MCIKeyframeCodec

@main
struct KeyframeCodecBehavior {
    static func main() throws {
        let key = Data((0..<32).map(UInt8.init))
        let plaintext = Data("post-privacy evidence".utf8)
        let sealed = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)

        precondition(KeyframeBlobCodec.saltLength == 16)
        precondition(KeyframeBlobCodec.info == Data("mci-blob-v2".utf8))
        precondition(sealed.bytes.prefix(16).count == 16)
        precondition(sealed.digest.count == 32)
        precondition(sealed.lowercaseHexDigest.count == 64)
        precondition(sealed.lowercaseHexDigest == KeyframeBlobCodec.sha256Hex(of: sealed.bytes))
        let opened = try KeyframeBlobCodec.open(blob: sealed.bytes, keyMaterial: key)
        precondition(opened == plaintext)

        let second = try KeyframeBlobCodec.seal(plaintext: plaintext, keyMaterial: key)
        precondition(second.bytes != sealed.bytes, "per-blob salt must be random")

        do {
            _ = try KeyframeBlobCodec.open(
                blob: sealed.bytes,
                keyMaterial: Data(repeating: 0xff, count: 32)
            )
            preconditionFailure("wrong key authenticated")
        } catch {}

        var tampered = sealed.bytes
        tampered[tampered.count - 1] ^= 0xff
        do {
            _ = try KeyframeBlobCodec.open(blob: tampered, keyMaterial: key)
            preconditionFailure("tampered tag authenticated")
        } catch {}

        for malformed in [Data(), plaintext, Data(repeating: 0, count: 16)] {
            do {
                _ = try KeyframeBlobCodec.open(blob: malformed, keyMaterial: key)
                preconditionFailure("malformed blob authenticated")
            } catch {}
        }
    }
}
