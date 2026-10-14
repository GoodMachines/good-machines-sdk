import CryptoKit
import Foundation

/// Header-safe keys for an action's `operationId`.
///
/// `operationId` is opaque and contains `:` (for example `"<uuid>:1"`), so
/// keep deduplicating by it in the app's own store, but don't send it where
/// an `Idempotency-Key` is expected. These keys are 64 lowercase hex
/// characters, the same on every retry, and match the server SDK's
/// `idempotencyKeyFor`.
public enum AgentOperation {
    /// The key for running the operation: hex SHA-256 of `operationId`.
    public static func idempotencyKey(for operationId: String) -> String {
        hex(SHA256.hash(data: Data(operationId.utf8)))
    }

    /// The key for undoing it: hex SHA-256 of `"undo\0" + operationId`, so a
    /// reversal never reuses the original call's key.
    public static func undoIdempotencyKey(for operationId: String) -> String {
        hex(SHA256.hash(data: Data(("undo\u{0}" + operationId).utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
