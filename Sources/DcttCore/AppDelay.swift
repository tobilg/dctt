import Foundation

/// Avoid Task.sleep(for:) specialization collisions in optimized, linked apps.
/// Reproduced on this CLT toolchain; see swiftlang/swift#86204.
public enum AppDelay {
    public static func sleep(milliseconds: UInt64) async throws {
        try await Task<Never, Never>.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
