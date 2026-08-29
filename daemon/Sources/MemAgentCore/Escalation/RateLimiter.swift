import Foundation

/// Caps autonomous escalations (min spacing + hourly budget) and trips a
/// circuit breaker after consecutive failures so a broken `claude` install
/// can't burn cycles or money.
public struct RateLimiter {
    public static let failuresToTrip = 3
    public static let breakerCooldown = 3600.0

    private(set) public var history: [Double] = []
    private(set) public var consecutiveFailures = 0
    private(set) public var disabledUntil: Double?

    public init() {}

    public mutating func allow(now: Double, minIntervalSeconds: Int, maxPerHour: Int) -> Bool {
        if let until = disabledUntil {
            if now < until { return false }
            disabledUntil = nil
            consecutiveFailures = 0
        }
        history.removeAll { now - $0 > 3600 }
        if let last = history.last, now - last < Double(minIntervalSeconds) { return false }
        if history.count >= maxPerHour { return false }
        return true
    }

    public mutating func record(now: Double) {
        history.append(now)
    }

    public mutating func recordFailure(now: Double) {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failuresToTrip {
            disabledUntil = now + Self.breakerCooldown
        }
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    public func health(now: Double) -> String {
        if let until = disabledUntil, now < until {
            return "circuit breaker open for \(Int(until - now))s after \(consecutiveFailures) failures"
        }
        return "ok"
    }
}
