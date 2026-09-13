import Foundation

public enum SupplementNotificationActionTokenError: Error, Equatable, Sendable {
    case invalidFireDate
}

/// Stable identity material attached to each scheduled notification.  The
/// occurrence ID remains the domain identity; the fire-date component makes a
/// later snooze generation distinct while remaining deterministic across
/// relaunches and device timezone changes.
public enum SupplementNotificationActionToken {
    public static func make(occurrenceID: String, fireDate: Date) throws -> String {
        let milliseconds = try validatedMilliseconds(for: fireDate)
        let material = "\(occurrenceID)|\(milliseconds)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "v1-\(String(hash, radix: 16, uppercase: false))"
    }

    /// Validates the date range before converting to `Int64`. Foundation's
    /// integer conversion traps for finite values outside the representable
    /// range, so externally constructed notification intents must fail closed.
    public static func validateFireDate(_ fireDate: Date) throws {
        _ = try validatedMilliseconds(for: fireDate)
    }

    private static func validatedMilliseconds(for fireDate: Date) throws -> Int64 {
        let scaled = fireDate.timeIntervalSinceReferenceDate * 1_000
        guard scaled.isFinite else { throw SupplementNotificationActionTokenError.invalidFireDate }

        let rounded = scaled.rounded()
        // Keep one representable-Double ULP of headroom at the positive edge. `Double`
        // cannot represent Int64.max exactly and can otherwise round to 2^63,
        // which would trap on conversion despite the source being finite.
        let lowerBound = Double(Int64.min)
        let upperBound = Double(Int64.max) - 1_024
        guard rounded >= lowerBound, rounded <= upperBound else {
            throw SupplementNotificationActionTokenError.invalidFireDate
        }
        return Int64(rounded)
    }

    public static func actionID(
        action: SupplementAction,
        token: String
    ) -> String {
        "notification-\(action.rawValue)-\(token)"
    }

    public static func wireDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
