import Foundation

/// Cooperative cancellation for the blocking sync code (the Ruby version used
/// Thread#raise(Interrupt)). Every wait checks it, so aborting takes effect
/// within a fraction of a second; it surfaces as a `CancellationError`.
public final class CancelToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public var isCancelled: Bool { lock.withLock { cancelled } }

  public func cancel() { lock.withLock { cancelled = true } }

  public func check() throws {
    if isCancelled { throw CancellationError() }
  }

  /// Sleeps, waking early (and throwing) when cancelled.
  public func sleep(_ seconds: Double) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
      try check()
      let left = deadline.timeIntervalSinceNow
      if left <= 0 { return }
      Thread.sleep(forTimeInterval: min(left, 0.1))
    }
  }
}

extension Optional where Wrapped == CancelToken {
  func check() throws { try self?.check() }

  func sleep(_ seconds: Double) throws {
    if let token = self { try token.sleep(seconds) } else { Thread.sleep(forTimeInterval: seconds) }
  }
}

/// Monotonic clock in seconds.
func monotonic() -> Double {
  Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
