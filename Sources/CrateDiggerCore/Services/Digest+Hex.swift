import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hex encoding of the bytes. Shared by the CryptoKit hashers
    /// (`SHA256` / `Insecure.MD5`) so the digest→string conversion lives once.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
