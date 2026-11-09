import Foundation

/// API responses are used as loosely typed dictionaries, like the Ruby hashes
/// they replace: the catalog has many optional, shape-shifting fields.
public typealias JSONObject = [String: Any]

public enum JSON {
  public static func parse(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  public static func parse(_ text: String) throws -> Any {
    try parse(Data(text.utf8))
  }

  public static func data(_ value: Any, pretty: Bool = false) throws -> Data {
    var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
    if pretty { options.insert(.prettyPrinted); options.insert(.sortedKeys) }
    return try JSONSerialization.data(withJSONObject: value, options: options)
  }

  public static func string(_ value: Any, pretty: Bool = false) throws -> String {
    String(decoding: try data(value, pretty: pretty), as: UTF8.self)
  }

  /// An id as a string, whether the API sent it as a number or a string.
  public static func id(_ value: Any?) -> String? {
    switch value {
    case let s as String: return s
    case let n as NSNumber where !isBool(n): return n.stringValue
    default: return nil
    }
  }

  static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

  /// Ruby truthiness: anything but null / false / missing.
  public static func truthy(_ value: Any?) -> Bool {
    switch value {
    case nil, is NSNull: return false
    case let n as NSNumber where isBool(n): return n.boolValue
    default: return true
    }
  }
}

extension Dictionary where Key == String, Value == Any {
  /// A string (numbers are converted), nil when missing or null.
  public func str(_ key: String) -> String? {
    switch self[key] {
    case let s as String: return s
    case let n as NSNumber where !JSON.isBool(n): return n.stringValue
    default: return nil
    }
  }

  /// A non-blank string, else nil.
  public func text(_ key: String) -> String? {
    guard let s = str(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
  }

  /// Like Ruby's `to_i`: numbers, numeric strings, else 0.
  public func int(_ key: String) -> Int {
    switch self[key] {
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s.prefix(while: { $0.isNumber || $0 == "-" })) ?? 0
    default: return 0
    }
  }

  public func flag(_ key: String) -> Bool { JSON.truthy(self[key]) }
  public func id(_ key: String) -> String? { JSON.id(self[key]) }
  public func obj(_ key: String) -> JSONObject? { self[key] as? JSONObject }
  public func objs(_ key: String) -> [JSONObject] { (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
  public func isArray(_ key: String) -> Bool { self[key] is [Any] }
}

// MARK: - Order-preserving JSON

/// JSON that keeps object keys in their original order. Used for the speaker
/// playlist, which is edited (local files are inserted) and sent back to an
/// embedded parser: its layout should stay exactly as Merlin's servers made it.
public indirect enum OrderedJSON: Equatable {
  case object([(String, OrderedJSON)])
  case array([OrderedJSON])
  case string(String)
  case number(String) // the literal, re-emitted verbatim
  case bool(Bool)
  case null

  public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool { a.serialized == b.serialized }

  public subscript(key: String) -> OrderedJSON? {
    guard case .object(let pairs) = self else { return nil }
    return pairs.first { $0.0 == key }?.1
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    if case .number(let n) = self { return n }
    return nil
  }

  public var arrayValue: [OrderedJSON]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public func has(_ key: String) -> Bool { self[key] != nil }

  /// Sets (or appends) a key.
  public mutating func set(_ key: String, _ value: OrderedJSON) {
    guard case .object(var pairs) = self else { return }
    if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
    self = .object(pairs)
  }

  public static func from(_ s: String) -> OrderedJSON { .string(s) }
  public static func from(_ i: Int) -> OrderedJSON { .number(String(i)) }

  // MARK: Serialization (compact, like Ruby's JSON.generate: UTF-8 kept, "/" unescaped)

  public var serialized: String {
    var out = ""
    write(to: &out)
    return out
  }

  private func write(to out: inout String) {
    switch self {
    case .object(let pairs):
      out += "{"
      for (i, (k, v)) in pairs.enumerated() {
        if i > 0 { out += "," }
        Self.writeString(k, to: &out)
        out += ":"
        v.write(to: &out)
      }
      out += "}"
    case .array(let items):
      out += "["
      for (i, v) in items.enumerated() {
        if i > 0 { out += "," }
        v.write(to: &out)
      }
      out += "]"
    case .string(let s): Self.writeString(s, to: &out)
    case .number(let n): out += n
    case .bool(let b): out += b ? "true" : "false"
    case .null: out += "null"
    }
  }

  private static func writeString(_ s: String, to out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
      }
    }
    out += "\""
  }

  // MARK: Parsing

  public static func parse(_ text: String) throws -> OrderedJSON {
    var p = Parser(Array(text.utf8))
    let value = try p.value()
    p.skipSpace()
    guard p.i == p.b.count else { throw MerlinError("invalid JSON: trailing characters at \(p.i)") }
    return value
  }

  private struct Parser {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }

    func fail(_ what: String) -> MerlinError { MerlinError("invalid JSON: \(what) at offset \(i)") }

    mutating func skipSpace() {
      while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
    }

    mutating func value() throws -> OrderedJSON {
      skipSpace()
      guard i < b.count else { throw fail("unexpected end") }
      switch b[i] {
      case UInt8(ascii: "{"): return try object()
      case UInt8(ascii: "["): return try array()
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"): try literal("true"); return .bool(true)
      case UInt8(ascii: "f"): try literal("false"); return .bool(false)
      case UInt8(ascii: "n"): try literal("null"); return .null
      default: return try number()
      }
    }

    mutating func literal(_ word: String) throws {
      let w = Array(word.utf8)
      guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw fail("bad literal") }
      i += w.count
    }

    mutating func number() throws -> OrderedJSON {
      let start = i
      while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
      guard i > start else { throw fail("unexpected character") }
      return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    mutating func object() throws -> OrderedJSON {
      i += 1
      var pairs: [(String, OrderedJSON)] = []
      skipSpace()
      if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
      while true {
        skipSpace()
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
        let key = try string()
        skipSpace()
        guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
        i += 1
        pairs.append((key, try value()))
        skipSpace()
        guard i < b.count else { throw fail("unterminated object") }
        if b[i] == UInt8(ascii: ",") { i += 1; continue }
        if b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        throw fail("expected ',' or '}'")
      }
    }

    mutating func array() throws -> OrderedJSON {
      i += 1
      var items: [OrderedJSON] = []
      skipSpace()
      if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
      while true {
        items.append(try value())
        skipSpace()
        guard i < b.count else { throw fail("unterminated array") }
        if b[i] == UInt8(ascii: ",") { i += 1; continue }
        if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        throw fail("expected ',' or ']'")
      }
    }

    mutating func string() throws -> String {
      i += 1
      var bytes: [UInt8] = []
      while i < b.count {
        let c = b[i]
        i += 1
        if c == UInt8(ascii: "\"") { return String(decoding: bytes, as: UTF8.self) }
        if c != UInt8(ascii: "\\") { bytes.append(c); continue }
        guard i < b.count else { break }
        let e = b[i]
        i += 1
        switch e {
        case UInt8(ascii: "n"): bytes.append(0x0A)
        case UInt8(ascii: "r"): bytes.append(0x0D)
        case UInt8(ascii: "t"): bytes.append(0x09)
        case UInt8(ascii: "b"): bytes.append(0x08)
        case UInt8(ascii: "f"): bytes.append(0x0C)
        case UInt8(ascii: "u"):
          var scalar = try hex4()
          if (0xD800..<0xDC00).contains(scalar), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
            i += 2
            let low = try hex4()
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
          }
          bytes += Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8)
        default: bytes.append(e) // \" \\ \/
        }
      }
      throw fail("unterminated string")
    }

    mutating func hex4() throws -> UInt32 {
      guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
        throw fail("bad \\u escape")
      }
      i += 4
      return v
    }
  }
}
