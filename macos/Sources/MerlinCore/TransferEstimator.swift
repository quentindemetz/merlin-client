import Foundation

/// Time left for the uploads: each file costs a fixed overhead (lookup,
/// header, the speaker's acknowledgement) plus its size over the link's
/// throughput. Both are fitted by least squares on the files done so far,
/// pulled towards values measured on a real speaker, so a run of tiny cover
/// images doesn't make the ETA swing, and the first estimate is sensible.
public struct TransferEstimator: Sendable {
  /// Measured on firmware 2.1.16 over 640 files: 0.74 s + 0.82 MB/s.
  public static let priorFixed = 0.74
  public static let priorSecondsPerMB = 1 / 0.82
  /// How many files' worth of evidence the prior is.
  static let priorWeight = 5.0

  private var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0

  public init() {}

  public private(set) var samples = 0

  /// One file done: its size and the time it took.
  public mutating func record(bytes: Int, seconds: Double) {
    let x = Double(bytes) / 1e6
    n += 1; sx += x; sy += seconds; sxx += x * x; sxy += x * seconds
    samples += 1
  }

  /// (seconds per file, seconds per MB)
  public var model: (fixed: Double, perMB: Double) {
    // Minimises Σ(y − a − b·x)² + w(a − a₀)² + w(b − b₀)²  (x in MB).
    let w = Self.priorWeight, a0 = Self.priorFixed, b0 = Self.priorSecondsPerMB
    let m11 = n + w, m12 = sx, m22 = sxx + w
    let r1 = sy + w * a0, r2 = sxy + w * b0
    let det = m11 * m22 - m12 * m12
    let a = (r1 * m22 - m12 * r2) / det
    let b = (m11 * r2 - m12 * r1) / det
    return (max(a, 0), max(b, 0))
  }

  public func secondsLeft(files: Int, bytes: Int) -> Double {
    let (a, b) = model
    return Double(max(files, 0)) * a + Double(max(bytes, 0)) / 1e6 * b
  }
}
