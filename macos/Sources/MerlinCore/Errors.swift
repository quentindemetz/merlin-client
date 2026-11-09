import Foundation

/// A failure worth showing to the user as is.
public struct MerlinError: LocalizedError, CustomStringConvertible {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Speaker protocol errors. `.link` and `.timeout` mean the connection is the
/// problem (worth reconnecting and retrying, like the app does); `.refused`
/// is an answer from the speaker (e.g. NOT_ENOUGH_SPACE) and is not retried.
public struct SpeakerError: LocalizedError, CustomStringConvertible {
  public enum Kind: Sendable { case refused, link, timeout }
  public let kind: Kind
  public let message: String

  public init(_ kind: Kind, _ message: String) {
    self.kind = kind
    self.message = message
  }

  public static func refused(_ m: String) -> SpeakerError { SpeakerError(.refused, m) }
  public static func link(_ m: String) -> SpeakerError { SpeakerError(.link, m) }
  public static func timeout(_ m: String) -> SpeakerError { SpeakerError(.timeout, m) }

  public var isLink: Bool { kind != .refused }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// Merlin cloud errors. `offline` means no route to the servers, typically
/// because the Mac is on the speaker's (internet-less) Wi-Fi.
public struct BackendError: LocalizedError, CustomStringConvertible {
  public let message: String
  public let status: Int?
  public let offline: Bool

  public init(_ message: String, status: Int? = nil, offline: Bool = false) {
    self.message = message
    self.status = status
    self.offline = offline
  }

  public var errorDescription: String? { message }
  public var description: String { message }
}

/// A sync failure with the status code reported to Merlin (e.g. 508_FAILED_ON_SDK_TIMEOUT).
public struct SyncFailure: LocalizedError, CustomStringConvertible {
  public let code: String
  public let message: String

  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }

  public var errorDescription: String? { message }
  public var description: String { message }
}

extension Error {
  /// The message to show for any error.
  public var userMessage: String {
    if self is CancellationError { return "Cancelled" }
    return (self as? LocalizedError)?.errorDescription ?? String(describing: self)
  }
}
